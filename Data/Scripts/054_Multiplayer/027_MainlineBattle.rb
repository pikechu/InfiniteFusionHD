unless ENV["KIF_SERVER_ENGINE"] == "1"
  module KIFMultiplayer
    class MainlineBattleUI
      def initialize(client)
        @client, @sdk, @ui = client, MainlineClient.new(client), UI.new(client)
      end
      def check(value, message = "服务器对战状态无效。")
        raise Error, message unless value
      end
      def text(value); KIFMultiplayer.display_text(value); end
      def validate_prompt(prompt)
        check(prompt.is_a?(Hash) && prompt["sequence"].is_a?(Integer) && prompt["sequence"].between?(0, 999))
        state = prompt["state"]
        check(state.is_a?(Hash) && %w[command switch safari].include?(state["kind"]))
        check(state["battlers"].is_a?(Array) && state["battlers"].length <= 6)
        state["battlers"].each do |battler|
          Snapshot.registry(:Species, battler["species"])
          check(Snapshot.number(battler["hp"], 0, 65535) && Snapshot.number(battler["totalhp"], 1, 65535) && battler["hp"] <= battler["totalhp"])
        end
        check(state["moves"].is_a?(Array) && state["moves"].length <= 4 && state["switches"].is_a?(Array) && state["switches"].length <= 6 && state["balls"].is_a?(Array) && state["balls"].length <= 8)
        state["moves"].each { |move| Snapshot.registry(:Move, move["id"]); check(Snapshot.number(move["index"], 0, 3) && Snapshot.number(move["pp"], 0, 1000));check(move['targets'].is_a?(Array) && move['targets'].length.between?(1,6) && move['targets'].all? { |value| Snapshot.number(value,-1,5) }) }
        state["switches"].each { |entry| check(Snapshot.number(entry["party_index"], 0, 5)) }
        state["balls"].each { |entry| Snapshot.registry(:Item, entry["id"]); check(Snapshot.number(entry["quantity"], 1, 99)) }
        check(state["medicine"].is_a?(Array) && state["medicine"].length<=8)
        state["medicine"].each { |entry| Snapshot.registry(:Item,entry["id"]);check(Snapshot.number(entry["quantity"],1,99)) }
        state
      end
      def choose_switch(state)
        values = state["switches"]
        raise Error, "没有可换入的精灵。" if values.empty?
        labels = values.map do |entry|
          party = (state["party"] || []).find { |value| value["party_index"] == entry["party_index"] }
          party ? "#{text(party['name'])} Lv.#{party['level']} · HP #{party['hp']}/#{party['totalhp']}" : "精灵 #{entry['party_index'] + 1}"
        end
        selected = @ui.choose("选择换入精灵", labels + ["返回"])
        selected >= 0 && selected < values.length ? {"action" => "switch", "party_index" => values[selected]["party_index"]} : nil
      end
      def choose_command(state)
        if state['kind']=='safari'
          selected=@ui.choose("沙湖 · 剩余 #{state['ball_count']} 个球",['沙湖球','投饵','投石','离开战斗'])
          return selected.between?(0,3) ? {'action'=>%w[safari_ball bait rock surrender][selected]} : nil
        end
        return choose_switch(state) if state["kind"] == "switch"
        moves = state["moves"]
        labels = moves.map { |move| "#{text(GameData::Move.get(move['id']).name)} · PP #{move['pp']}" }
        labels << "挣扎" if moves.empty?
        move_count = labels.length
        labels += ["换人", "精灵球", "治疗道具", "撤退／认输"]
        heading = state["battlers"].map { |b| "#{text(GameData::Species.get(b['species']).name)} Lv.#{b['level']} · HP #{b['hp']}/#{b['totalhp']}" }.join("\n")
        events = (state["events"] || []).last(3).map { |line| text(line) }.join("\n")
        selected = @ui.choose("服务器对战\n#{heading}\n#{events}", labels)
        return nil if selected < 0 || selected >= labels.length
        if selected<move_count
          return {'action'=>'forced'} if moves.empty?
          move=moves[selected];targets=move['targets'];target=targets.first
          if targets.length>1
            choice=@ui.choose('选择招式目标',targets.map { |id| battler=state['battlers'].find { |entry| entry['index']==id };battler ? "#{text(GameData::Species.get(battler['species']).name)} · HP #{battler['hp']}/#{battler['totalhp']}" : '自动目标' }+['返回'])
            return nil if choice<0 || choice>=targets.length
            target=targets[choice]
          end
          return {'action'=>'move','move_index'=>move['index'],'target'=>target}
        end
        return choose_switch(state) if selected == move_count
        if selected == move_count + 1
          balls = state["balls"]
          raise Error, "本场没有可用的联机精灵球。" if balls.empty?
          choice = @ui.choose("选择精灵球", balls.map { |entry| "#{text(GameData::Item.get(entry['id']).name)} ×#{entry['quantity']}" } + ["返回"])
          return choice >= 0 && choice < balls.length ? {"action" => "catch", "item_id" => balls[choice]["id"]} : nil
        end
        if selected == move_count+2
          medicine=state["medicine"] || []
          raise Error,"本场没有可用治疗道具。" if medicine.empty?
          choice=@ui.choose("选择道具",medicine.map { |entry| "#{text(GameData::Item.get(entry['id']).name)} ×#{entry['quantity']}" }+["返回"])
          return nil if choice<0 || choice>=medicine.length
          party=state["party"] || []
          target=@ui.choose("选择精灵",party.map { |entry| "#{text(entry['name'])} · HP #{entry['hp']}/#{entry['totalhp']}" }+["返回"])
          return target>=0 && target<party.length ? {"action"=>"item","item_id"=>medicine[choice]["id"],"party_index"=>party[target]["party_index"]} : nil
        end
        pbConfirmMessage("结束当前战斗？已使用资源按服务器结果结算。") ? {"action" => "surrender"} : nil
      end
      def run(job_id)
        previous_battle = $game_temp.in_battle
        $game_temp.in_battle = true
        @client.recover_pending
        result = KIFMultiplayer.with_trading_scene do
          loop do
            job = @sdk.job(job_id)
            if %w[completed failed].include?(job["status"])
              @sdk.save_intent(nil) if @sdk.intent && @sdk.intent["job_id"] == job_id
              raise Error, "服务器对战未完成，原状态与资源已保留。" if job["status"] == "failed"
              outcome = job["result"]
              Mainline.last_battle_result=outcome if Mainline.respond_to?(:last_battle_result=)
              check(outcome.is_a?(Hash) && Snapshot.number(outcome["decision"], 1, 5))
              pbMessage((outcome["events"] || []).last(5).map { |line| text(line) }.join("\n")) unless (outcome["events"] || []).empty?
              pbMessage("服务器已保存战斗结果。捕获 #{(outcome['captured_asset_ids'] || []).length} 只，联机币变化 #{outcome['money_delta']}。")
              break outcome["decision"]
            end
            prompt = job["prompt"]
            if prompt && job["submitted_sequence"] != prompt["sequence"]
              state = validate_prompt(prompt)
              command = choose_command(state)
              if command
                @client.request("POST", "/v1/mainline/jobs/#{job_id}/commands", {"sequence" => prompt["sequence"], "command" => command})
              end
            else
              until_time = KIFMultiplayer.monotonic + 0.25
              @client.pump while KIFMultiplayer.monotonic < until_time
            end
          end
        end
        result
      ensure
        $game_temp.in_battle = previous_battle
        Mainline.refresh if defined?(Mainline) && Mainline.active?
      end
    end

    module Mainline
      class << self
        def battle(params)
          raise Error, "当前不是托管主线角色。" unless active?
          character = sdk.character(character_id)
          inventory = TradingClient.new(client).inventory
          medicine=%w[POTION SUPERPOTION HYPERPOTION MAXPOTION FULLRESTORE ANTIDOTE PARLYZHEAL BURNHEAL ICEHEAL AWAKENING FULLHEAL REVIVE MAXREVIVE]
          belt = inventory["items"].select { |entry| entry["available"] > 0 && (GameData::Item.get(entry["item_id"]).is_poke_ball? || medicine.include?(entry["item_id"])) }.first(8).each_with_object({}) { |entry, hash| hash[entry["item_id"]] = [entry["available"], 30].min }
          body = {"operation" => "battle", "asset_ids" => character["party"].map { |asset| asset["id"] }, "params" => params.merge("belt" => belt), "compatibility" => client.compatibility}
          value = sdk.submit("/v1/mainline/characters/#{character_id}/jobs", body)
          MainlineBattleUI.new(client).run(value["job"]["id"])
        end
      end
    end

    module MainlineWildHook
      def pbWildBattleCore(*args)
        return super unless KIFMultiplayer::Mainline.active? && !KIFMultiplayer::Mainline.projecting?
        params = {"kind" => "wild", "map_id" => $game_map.map_id}
        if pbMapInterpreterRunning?
          source = args.first.is_a?(Array) ? args.first : args
          pokemon = source.first
          params["kind"] = "scripted"
          params["species"] = pokemon.is_a?(Pokemon) ? pokemon.species.to_s : pokemon.to_s
          params["level"] = pokemon.is_a?(Pokemon) ? pokemon.level : source[1]
        end
        decision = KIFMultiplayer::Mainline.battle(params)
        outcome = $PokemonTemp.battleRules["outcomeVar"] || 1
        pbSet(outcome, decision || 0)
        $PokemonTemp.clearBattleRules
        decision || 0
      rescue KIFMultiplayer::Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message))
        $PokemonTemp.clearBattleRules
        0
      end
      def pbTrainerBattleCore(*args)
        return super unless KIFMultiplayer::Mainline.active? && !KIFMultiplayer::Mainline.projecting?
        descriptor = args.first.is_a?(Array) ? args.first : args
        raise KIFMultiplayer::Error, "这类合作训练师事件需要单独适配。" unless descriptor[0] && descriptor[1]
        params = {"kind" => "trainer", "map_id" => $game_map.map_id, "trainer_type" => descriptor[0].to_s, "trainer_name" => descriptor[1].to_s, "trainer_version" => descriptor[2].is_a?(Integer) ? descriptor[2] : 0}
        decision = KIFMultiplayer::Mainline.battle(params)
        outcome = $PokemonTemp.battleRules["outcomeVar"] || 1
        pbSet(outcome, decision || 0)
        $PokemonTemp.clearBattleRules
        decision || 0
      rescue KIFMultiplayer::Error=>error
        pbMessage(KIFMultiplayer.display_text(error.message))
        $PokemonTemp.clearBattleRules
        0
      end
    end
  end
  Object.prepend(KIFMultiplayer::MainlineWildHook)
end
