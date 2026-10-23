unless ENV['KIF_SERVER_ENGINE']=='1'
  module KIFMultiplayer
    module Mainline
      class << self
        attr_accessor :last_battle_result
        def story_context
          interpreter=pbMapInterpreter
          raise Error,'当前没有地图事件解释器。' unless interpreter
          id=interpreter.instance_variable_get(:@event_id)
          event=$game_map.events[id]
          raise Error,'当前剧情事件没有已安装的地图声明。' unless event
          definition=event.instance_variable_get(:@event)
          page=definition.pages.index(event.instance_variable_get(:@page)) || 0
          index=interpreter.instance_variable_get(:@index)
          list=interpreter.instance_variable_get(:@list)
          index-=1 if interpreter.instance_variable_get(:@child_interpreter) && list[index-1] && list[index-1].code==117
          key=[$game_map.map_id,id,page,index]
          @story_occurrences={} if @story_last_key!=key
          occurrence=(@story_occurrences[key] || 0)
          @story_occurrences[key]=occurrence+1;@story_last_key=key
          {'event_id'=>id,'page'=>page,'command_index'=>index,'occurrence'=>occurrence}
        end
        def story_session
          sdk.character(character_id)['story']
        end
        def enter_story(kind,selected=0)
          character=sdk.character(character_id)
          params={'map_id'=>$game_map.map_id,'selected_index'=>selected}
          result=KIFMultiplayer.with_trading_scene(true) { sdk.operate(character_id,kind=='safari' ? 'safari_enter' : 'contest_enter',character['party'].map { |asset| asset['id'] },params) }
          refresh
          result['result']['story']
        end
        def finish_story
          character=sdk.character(character_id);session=character['story']
          raise Error,'没有进行中的剧情活动。' unless session
          if session['kind']=='contest'
            result=KIFMultiplayer.with_trading_scene(true) { sdk.operate(character_id,'contest_finish',character['party'].map { |asset| asset['id'] },{'session_id'=>session['id']}) }
            session=result['result']['story']
            state=pbBugContestState
            state.instance_variable_set(:@places,session['places'].map { |entry| Snapshot.registry(:Species,entry[1]);[entry[0],entry[1].to_sym,entry[2]] })
            state.instance_variable_set(:@lastContest,Time.now.to_i)
            state.instance_variable_set(:@ended,true)
          else
            session=client.request('POST',"/v1/mainline/story/#{session['id']}/leave")['story']
          end
          refresh
          session
        end
        def apply_story(character)
          session=character['story']
          safari=pbSafariState;contest=pbBugContestState
          with_projection do
            partner=character['partner']
            if partner && $PokemonGlobal.instance_variable_get(:@kif_partner_signature)!=partner
              type=partner['trainer_type'].to_sym
              raise Error,'同行伙伴资料不匹配。' unless GameData::Trainer::DATA.key?([type,partner['trainer_name'],partner['trainer_version']])
              ally=pbLoadTrainer(type,partner['trainer_name'],partner['trainer_version'])
              $PokemonGlobal.partner=[type,partner['trainer_name'],ally.id,ally.party]
              $PokemonGlobal.instance_variable_set(:@kif_partner_signature,partner)
            elsif !partner
              $PokemonGlobal.partner=nil
              $PokemonGlobal.instance_variable_set(:@kif_partner_signature,nil)
            end
            [safari,contest].each do |state|
              state.instance_variable_set(:@inProgress,false)
              state.ballcount=0
            end
            if session
              state=session['kind']=='safari' ? safari : contest
              fresh=state.instance_variable_get(:@kif_story_id)!=session['id']
              state.instance_variable_set(:@kif_story_id,session['id'])
              state.instance_variable_set(:@inProgress,true)
              state.ballcount=session['remaining'];state.decision=0
              if fresh
                state.instance_variable_set(:@start,[$game_map.map_id,$game_player.x,$game_player.y,$game_player.direction])
                state.steps=Settings::SAFARI_STEPS if state.is_a?(SafariState)
                state.instance_variable_set(:@timer,Graphics.frame_count) if state.is_a?(BugContestState)
              end
            end
          end
        end
        def finish_field_battle(decision)
          outcome=$PokemonTemp.battleRules['outcomeVar'] || 1
          pbSet(outcome,decision || 0);$PokemonTemp.clearBattleRules
          session=last_battle_result && last_battle_result['story']
          if session && session['kind']=='contest' && session['pending_candidate']
            candidate=session['pending_candidate']
            replace=pbConfirmMessage("捕获 #{KIFMultiplayer.display_text(candidate['species'])} Lv.#{candidate['level']}。替换本次比赛保留的精灵？")
            client.request('POST',"/v1/mainline/story/#{session['id']}/candidate",{'replace'=>replace})
          end
          decision || 0
        end
      end
    end
    module MainlineStoryProjection
      def apply(character,inventory)
        projected=character
        if character['story'] && character['story']['kind']=='contest'
          projected=character.merge('party'=>character['party'].select { |asset| asset['id']==character['story']['selected_asset_id'] })
        end
        applied=super(projected,inventory)
        apply_story(character) if applied
      end
    end
    Mainline.singleton_class.prepend(MainlineStoryProjection)
    class MainlineUI
      def story_activities(character)
        raise Error,'请先进入这个托管角色。' unless Mainline.active? && Mainline.character_id==character['id']
        loop do
          character=@sdk.character(character['id']);session=character['story']
          heading=session ? "#{session['kind']=='safari' ? '沙湖' : '捕虫比赛'} · 剩余球 #{session['remaining']}" : '当前没有活动'
          selected=choose(heading,['进入沙湖（500联机币／30球）','参加捕虫比赛（24小时一次／20球）','查看保留候选','结束／评判活动','结束同行','返回'])
          return if selected<0 || selected>=5
          if selected<2
            kind=selected==0 ? 'safari' : 'contest'
            party_index=0
            if kind=='contest'
              party_index=choose('选择参赛精灵',character['party'].map { |asset| label(asset) }+['返回'])
              next if party_index<0 || party_index>=character['party'].length
            end
            Mainline.enter_story(kind,party_index)
            pbMessage('活动已开始，捕获与配额由服务器保存。')
          elsif selected==2
            candidate=session && session['candidate']
            pbMessage(candidate ? "#{text(candidate['species'])} Lv.#{candidate['level']}\nIV #{text(WireJSON.dump(candidate['iv']))}" : '尚未保留参赛候选。')
          elsif selected==3
            value=Mainline.finish_story
            pbMessage(value['kind']=='contest' ? "评判完成：名次 #{value['place']+1}，候选已进入联机 PC。" : '沙湖活动已结束。')
          else
            pbDeregisterPartner
          end
        end
      end
    end

    module MainlineStoryBattles
      def pbRegisterPartner(type,name,version=0)
        return super unless Mainline.active? && !Mainline.projecting?
        character=Mainline.sdk.character(Mainline.character_id)
        params={'map_id'=>$game_map.map_id,'partner'=>{'trainer_type'=>type.to_s,'trainer_name'=>name,'trainer_version'=>version}}
        KIFMultiplayer.with_trading_scene(true) { Mainline.sdk.operate(Mainline.character_id,'partner_register',character['party'].map { |asset| asset['id'] },params) }
        result=super
        Mainline.refresh;result
      end
      def pbDeregisterPartner
        return super unless Mainline.active? && !Mainline.projecting?
        Mainline.client.request('POST',"/v1/mainline/characters/#{Mainline.character_id}/partner/leave")
        result=super
        Mainline.refresh;result
      end
      def pbWildBattleCore(*args)
        return super unless Mainline.active? && !Mainline.projecting? && pbMapInterpreterRunning?
        Mainline.finish_field_battle(Mainline.battle({'kind'=>'story','map_id'=>$game_map.map_id,'story'=>Mainline.story_context}))
      rescue Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message));0
      end
      def pbTrainerBattleCore(*args)
        return super unless Mainline.active? && !Mainline.projecting?
        if args.all? { |entry| entry.is_a?(Array) }
          trainers=args.map { |entry| {'trainer_type'=>entry[0].to_s,'trainer_name'=>entry[1].to_s,'trainer_version'=>entry[2].is_a?(Integer) ? entry[2] : 0} }
          params={'kind'=>'trainer','map_id'=>$game_map.map_id,'trainers'=>trainers}
        else
          params={'kind'=>'story','map_id'=>$game_map.map_id,'story'=>Mainline.story_context}
        end
        Mainline.finish_field_battle(Mainline.battle(params))
      rescue Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message));0
      end
      def pbSafariBattle(*args)
        return super unless Mainline.active? && !Mainline.projecting?
        session=Mainline.story_session
        raise Error,'请先从沙湖入口开始活动。' unless session && session['kind']=='safari'
        decision=Mainline.finish_field_battle(Mainline.battle({'kind'=>'safari','map_id'=>$game_map.map_id,'session_id'=>session['id']}))
        if pbSafariState.ballcount<=0
          Mainline.finish_story;pbSafariState.decision=1;pbSafariState.pbGoToStart
        end
        decision
      rescue Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message));0
      end
      def pbBugContestBattle(*args)
        return super unless Mainline.active? && !Mainline.projecting?
        session=Mainline.story_session
        raise Error,'请先报名捕虫比赛。' unless session && session['kind']=='contest'
        decision=Mainline.finish_field_battle(Mainline.battle({'kind'=>'contest','map_id'=>$game_map.map_id,'session_id'=>session['id']}))
        pbBugContestState.pbStartJudging if pbBugContestState.ballcount<=0 || [2,5].include?(decision)
        ![2,5].include?(decision)
      rescue Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message));false
      end
      def pbRoamingPokemonBattle(*args)
        return super unless Mainline.active? && !Mainline.projecting?
        index=$PokemonTemp.roamerIndex
        decision=Mainline.finish_field_battle(Mainline.battle({'kind'=>'roamer','map_id'=>$game_map.map_id,'roamer_index'=>index}))
        if [1,4].include?(decision)
          $PokemonGlobal.roamPokemon[index]=true;$PokemonGlobal.roamPokemonCaught[index]=decision==4
        end
        $PokemonGlobal.roamEncounter=nil;$PokemonGlobal.roamedAlready=true
        ![2,5].include?(decision)
      rescue Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message));false
      end
    end
    module MainlineSafariState
      def pbStart(count)
        return super unless Mainline.active? && !Mainline.projecting?
        Mainline.enter_story('safari')
      end
      def pbEnd
        if Mainline.active? && !Mainline.projecting? && @inProgress && @kif_story_id
          Mainline.client.request('POST',"/v1/mainline/story/#{@kif_story_id}/leave")
        end
        super
      end
    end
    module MainlineContestState
      def pbStart(count)
        return super unless Mainline.active? && !Mainline.projecting?
        Mainline.enter_story('contest',@chosenPokemon || 0)
      end
      def pbStartJudging
        return super unless Mainline.active? && !Mainline.projecting?
        Mainline.finish_story;@decision=1
      end
      def pbEnd(interrupted=false)
        return super unless Mainline.active? && !Mainline.projecting?
        Mainline.finish_story if @inProgress
        @inProgress=false;@ended=!interrupted
      end
    end
  end
  Object.prepend(KIFMultiplayer::MainlineStoryBattles)
  SafariState.prepend(KIFMultiplayer::MainlineSafariState) if defined?(SafariState)
  BugContestState.prepend(KIFMultiplayer::MainlineContestState) if defined?(BugContestState)
end
