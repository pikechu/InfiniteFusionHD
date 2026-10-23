# Fixed installed adapters for original Safari mechanics and contest scoring.
module KIFServerModes
  def self.partner(request,party)
    params=request['params'];wanted=params['partner']
    map=load_data('Data/Map%03d.rxdata' % params['map_id'])
    load File.expand_path('native_story.rb',__dir__)
    declared=map.events.values.any? do |event|
      event.pages.any? do |page|
        resolver=KIFServerStory::Resolver.new(party);resolver.commands(page.list)
        resolver.partners.include?(wanted)
      end
    end
    raise 'This story partner is not declared on the installed map' unless declared
    type=KIFServerEngine.registered(:TrainerType,wanted['trainer_type'])
    key=[type,wanted['trainer_name'],wanted['trainer_version']]
    raise 'Story partner is not installed' unless GameData::Trainer::DATA.key?(key)
    trainer=pbLoadTrainer(*key)
    raise 'Story partner exceeds verified level cap' if trainer.party.any? { |pokemon| pokemon.level>params['level_cap'] }
    {'pokemon'=>party.map { |pokemon| KIFServerEngine.export(pokemon) },'story'=>{'partner'=>wanted}}
  end
  def self.encounter_data(map_id)
    GameData::Encounter.get(map_id,0)
  end
  def self.safari_maps
    GameData::Encounter::DATA.values.map(&:map).uniq.select do |id|
      metadata=GameData::MapMetadata.try_get(id)
      (metadata && metadata.safari_map) || is_hardcoded_safari_map(id)
    end
  end
  def self.bug_entries(map_id)
    data=encounter_data(map_id)
    return [] unless data
    entries=data.types[:BugContest] || data.types.find { |kind,_| kind.to_s.start_with?('Land','Cave') }&.last || []
    entries.select do |entry|
      id=KIFServerEngine.registered(:Species,entry[1].to_s)
      GameData::Species.get(id).types.include?(:BUG)
    end
  end
  def self.contest_maps
    GameData::Encounter::DATA.values.map(&:map).uniq.select { |map_id| !bug_entries(map_id).empty? }
  end
  def self.entry(request,party)
    params=request['params'];map_id=params.fetch('map_id')
    kind=request['operation']=='safari_enter' ? 'safari' : 'contest'
    maps=kind=='safari' ? safari_maps : contest_maps
    if kind=='safari' && !maps.include?(map_id)
      map=load_data('Data/Map%03d.rxdata' % map_id)
      allowed=map.events.values.any? { |event| event.pages.any? { |page| page.list.any? { |command| [355,655].include?(command.code) && command.parameters[0].to_s =~ /pbSafariState\.pbStart\s*\(/ } } }
      raise 'This map does not contain a Safari reception' unless allowed
    else
      raise 'This map has no certified contest encounters' unless maps.include?(map_id)
    end
    duration=kind=='contest' ? [BugContestState::TimerSeconds,60].max : 1800
    {'pokemon'=>party.map { |pokemon| KIFServerEngine.export(pokemon) },'story'=>{'kind'=>kind,'map_id'=>map_id,'allowed_maps'=>maps,'entry_fee'=>kind=='safari' ? 500 : 0,'duration'=>duration}}
  end
  def self.contest_encounter(map_id,cap)
    entries=bug_entries(map_id).select { |entry| entry[2]<=cap }
    raise 'No contest encounter below verified level cap' if entries.empty?
    ticket=rand(entries.sum { |entry| entry[0] });selected=entries.last
    entries.each { |entry| ticket-=entry[0];if ticket<0;selected=entry;break;end }
    max=[selected[3] || selected[2],cap].min
    pbGenerateWildPokemon(selected[1],rand(selected[2]..max))
  end
  def self.judge(request,party)
    params=request['params'];candidates=[params['candidate'],params['pending_candidate']].compact
    chosen=candidates.max_by { |full| pbBugContestScore(KIFServerEngine.import(full)) }
    scores=[]
    if chosen
      pokemon=KIFServerEngine.import(chosen)
      scores<<[-1,pokemon.species.to_s,pbBugContestScore(pokemon)]
    end
    5.times do |index|
      opponent=contest_encounter(params['map_id'],100)
      opponent.hp=rand(1..[opponent.totalhp-1,1].max)
      scores<<[index,opponent.species.to_s,pbBugContestScore(opponent)]
    end
    scores.sort_by! { |entry| -entry[2] }
    place=scores.index { |entry| entry[0]==-1 } || 5
    prize=[:SUNSTONE,:EVERSTONE,:GOLDBERRY][place]
    prize=:ORANBERRY if prize==:GOLDBERRY && !GameData::Item::DATA.key?(prize)
    prize=nil if prize && !GameData::Item::DATA.key?(prize)
    {'pokemon'=>party.map { |pokemon| KIFServerEngine.export(pokemon) },'story'=>{'candidate'=>chosen,'place'=>[place,3].min,'places'=>scores.first(3),'score'=>chosen ? pbBugContestScore(KIFServerEngine.import(chosen)) : 0,'prize'=>prize && prize.to_s}}
  end

  class SafariScene < KIFServerBattle::Scene
    def initialize(request)
      super();@request=request
    end
    def pbSafariStart;end
    def pbThrowBait;end
    def pbThrowRock;end
    def pbSafariCommandMenu(_index)
      pokemon=@battle.party2[0]
      state={'kind'=>'safari','active_index'=>0,'moves'=>[],'switches'=>[],'balls'=>[{'id'=>'SAFARIBALL','quantity'=>@battle.ballCount}],'medicine'=>[],'party'=>[],'battlers'=>[{'index'=>1,'species'=>pokemon.species.to_s,'level'=>pokemon.level,'hp'=>pokemon.hp,'totalhp'=>pokemon.totalhp,'status'=>pokemon.status.to_s}],'events'=>@battle.events.last(20),'ball_count'=>@battle.ballCount}
      action=KIFServerBattle.prompt(@request,state)
      {'safari_ball'=>0,'bait'=>1,'rock'=>2,'surrender'=>3}.fetch(action['action']) { raise 'Illegal Safari action' }
    end
  end
  class Safari < PokeBattle_SafariZone
    attr_reader :captured,:events
    def initialize(*args)
      super;@captured=[];@events=[]
    end
    def pbRecordAndStoreCaughtPokemon;@captured.concat(@caughtPokemon);@caughtPokemon.clear;end
    def pbDisplay(message,&block)
      @events<<message.to_s.gsub(/[\x00-\x1f]/,' ')[0,400];@events.shift while @events.length>100
      @scene.pbDisplayMessage(message,&block)
    end
    def pbDisplayPaused(message,&block);pbDisplay(message,&block);end
    def pbDisplayBrief(message);pbDisplay(message);end
  end
  def self.safari(request,party,foes)
    scene=SafariScene.new(request);battle=Safari.new(scene,$Trainer,foes)
    battle.ballCount=request['params'].fetch('story_ball_count')
    decision=battle.pbStartBattle
    {'pokemon'=>party.map { |pokemon| KIFServerEngine.export(pokemon) },'captured'=>battle.captured.map { |pokemon| KIFServerEngine.export(pokemon) },'decision'=>decision,'money_delta'=>0,'bag_final'=>{},'story_ball_remaining'=>battle.ballCount,'events'=>battle.events.last(30)}
  end
end
