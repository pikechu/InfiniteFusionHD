# Authoritative solo combat. The public client chooses legal indexes; the
# installed engine owns opponents, randomness, damage, captures and experience.
module KIFServerBattle
  MEDICINE=%i[POTION SUPERPOTION HYPERPOTION MAXPOTION FULLRESTORE ANTIDOTE PARLYZHEAL BURNHEAL ICEHEAL AWAKENING FULLHEAL REVIVE MAXREVIVE].freeze
  class Scene < PokeBattle_DebugSceneNoLogging
    def pbBeginEndOfRoundPhase(*args); end
    def pbShowAbilitySplash(*args); end
    def pbHideAbilitySplash(*args); end
    def pbReplaceAbilitySplash(*args); end
    def pbShowPartyLineup(*args); end
    def pbSwapBattlerSprites(*args); end
    def pbShowHelp(*args); end
    def pbHideHelp(*args); end
    def pbUpdate(*args); Graphics.update; end
    def pbRefreshOne(*args); end
    def pbHitAndHPLossAnimation(*args); end
    def pbThrow(*args); end
    def pbThrowSuccess; end
    def pbThrowAndDeflect(*args); end
    def pbHideCaptureBall(*args); end
    def pbShowPokedex(*args); end
    def pbChangePokemon(*args); end
    def pbDisplay(*args); end
  end

  class Engine < KIFMultiplayerAIBattle
    attr_reader :captured, :events
    def initialize(scene, party, foes, player, opponent, controller, reward_enabled)
      super(scene, party, foes, player, opponent, controller)
      @internalBattle, @expGain, @moneyGain = true, true, reward_enabled
      @canRun, @canLose, @showAnims, @switchStyle = true, true, false, false
      @captured, @events = [], []
    end
    def pbGainExp; PokeBattle_Battle.instance_method(:pbGainExp).bind(self).call; end
    def pbGainMoney; PokeBattle_Battle.instance_method(:pbGainMoney).bind(self).call; end
    def pbLoseMoney; PokeBattle_Battle.instance_method(:pbLoseMoney).bind(self).call; end
    def pbRecordAndStoreCaughtPokemon
      @captured.concat(@caughtPokemon)
      @caughtPokemon.clear
    end
    def pbDisplay(message)
      @events << message.to_s.gsub(/[\x00-\x1f]/, " ")[0, 400]
      @events.shift while @events.length > 100
      @scene.pbDisplayMessage(message)
    end
    def pbDisplayPaused(message); pbDisplay(message); end
    def pbEndOfBattle; PokeBattle_Battle.instance_method(:pbEndOfBattle).bind(self).call; end
    def public_state(index)
      state = input_state(index)
      state["battlers"] = @battlers.compact.map do |battler|
        {"index" => battler.index, "hp" => battler.hp, "totalhp" => battler.totalhp, "species" => battler.displaySpecies.to_s, "level" => battler.level, "status" => battler.status.to_s}
      end
      state["party"] = pbParty(0).each_with_index.map { |pokemon, slot| {"party_index" => slot, "species" => pokemon.species.to_s, "name" => pokemon.name, "level" => pokemon.level, "hp" => pokemon.hp, "totalhp" => pokemon.totalhp} }
      state["balls"] = wildBattle? ? KIFServerBattle.belt.keys.select { |id| GameData::Item.get(id).is_poke_ball? && $PokemonBag.pbQuantity(id) > 0 }.map { |id| {"id" => id.to_s, "quantity" => $PokemonBag.pbQuantity(id)} } : []
      state["medicine"] = KIFServerBattle.belt.keys.select { |id| KIFServerBattle::MEDICINE.include?(id) && $PokemonBag.pbQuantity(id)>0 }.map { |id| {"id"=>id.to_s,"quantity"=>$PokemonBag.pbQuantity(id)} }
      state["events"] = @events.last(20)
      state
    end
    def pbCommandPhase
      @scene.pbBeginCommandPhase
      @battlers.each_with_index { |battler, index| pbClearChoice(index) if battler && pbCanShowCommands?(index) }
      if pbCanShowCommands?(0)
        action = @gym_controller.call(public_state(0))
        case action && action["action"]
        when "move"
          index = action["move_index"]
          raise "Illegal native battle move" unless index.is_a?(Integer) && (0..3).include?(index) && pbCanChooseMove?(0, index, false) && pbRegisterMove(0, index, false)
          pbRegisterTarget(0, -1)
        when "switch"
          raise "Illegal native battle switch" unless action["party_index"].is_a?(Integer) && pbRegisterSwitch(0, action["party_index"])
        when "catch"
          id = action["item_id"]
          raise "Illegal native capture item" unless wildBattle? && id.is_a?(String) && KIFServerBattle.belt.key?(id.to_sym) && GameData::Item.get(id).is_poke_ball? && $PokemonBag.pbQuantity(id) > 0
          pbRegisterItem(0, id.to_sym, 1)
        when "item"
          id,slot=action["item_id"],action["party_index"]
          raise "Illegal native medicine" unless id.is_a?(String) && KIFServerBattle::MEDICINE.include?(id.to_sym) && KIFServerBattle.belt.key?(id.to_sym) && $PokemonBag.pbQuantity(id)>0 && slot.is_a?(Integer) && slot.between?(0,pbParty(0).length-1)
          pbRegisterItem(0,id.to_sym,slot)
        when "forced" then pbAutoChooseMove(0, false)
        when "surrender" then @decision = 3; return
        else raise "Unknown native battle command"
        end
      end
      @battleAI.pbDefaultChooseEnemyCommand(1) if pbCanShowCommands?(1)
      @decision = 3 if (@turnCount || 0) >= 500
    end
    def pbSwitchInBetween(index, lax = false, can_cancel = false)
      return super unless index.even?
      state = public_state(index).merge("kind" => "switch")
      action = @gym_controller.call(state)
      party = action && action["party_index"]
      raise "Illegal native replacement" unless action && action["action"] == "switch" && party.is_a?(Integer) && (lax ? pbCanSwitchLax?(index, party) : pbCanSwitch?(index, party))
      party
    end
  end

  class << self
    attr_reader :belt
    def prompt(request, state)
      sequence = @sequence
      @sequence += 1
      payload = {"job_id" => request["job_id"], "nonce" => request["nonce"], "sequence" => sequence, "state" => state, "deadline" => Time.now.to_f + 60}
      KIFServerEngine.write("prompt.json", payload)
      file = File.join(KIFServerEngine.directory, "command-%04d.json" % sequence)
      deadline = Time.now.to_f + 60
      loop do
        if File.file?(file)
          value = KIFServerEngine.verified(KIFMultiplayer::WireJSON.parse(File.binread(file)))
          raise "Native command belongs to another prompt" unless value["job_id"] == request["job_id"] && value["nonce"] == request["nonce"] && value["sequence"] == sequence
          return value["command"]
        end
        if Time.now.to_f >= deadline
          return {"action" => "switch", "party_index" => state["switches"].first["party_index"]} if state["kind"] == "switch" && !state["switches"].empty?
          return {"action" => "surrender"}
        end
        Graphics.update
        Input.update
      end
    end
    def opponent(request)
      params = request["params"]
      cap = params.fetch("level_cap")
      case params.fetch("kind")
      when "wild"
        map_id = params.fetch("map_id")
        data = GameData::Encounter.get(map_id, 0)
        raise "This map has no certified encounters" unless data && !data.types.empty?
        type = params["encounter_type"]
        type = type.to_sym if type.is_a?(String)
        type = data.types.keys.find { |key| key.to_s.start_with?("Land", "Cave", "Water") } unless type && data.types.key?(type)
        raise "Encounter type unavailable" unless type && data.types[type] && !data.types[type].empty?
        raise "Encounter map exceeds current level cap" if data.types[type].map { |entry| entry[2] }.min > cap
        encounter = PokemonEncounters.new
        encounter.setup(map_id)
        species, level = encounter.choose_wild_pokemon(type)
        raise "Encounter exceeds current level cap" if level > cap
        pokemon = pbGenerateWildPokemon(species, level)
        pokemon.form = 0
        pokemon.instance_variable_set(:@kuraycustomfile, nil)
        [[pokemon], nil]
      when "scripted"
        map_id = KIFServerEngine.bounded(params.fetch("map_id"), 1, 999999)
        species = KIFServerEngine.registered(:Species, params.fetch("species"))
        level = KIFServerEngine.bounded(params.fetch("level"), 1, cap)
        map = load_data("Data/Map%03d.rxdata" % map_id)
        approved = map.events.values.any? do |event|
          event.pages.any? do |page|
            source = page.list.select { |command| command.code == 355 || command.code == 655 }.map { |command| command.parameters[0].to_s }.join("\n")
            source.scan(/pbWildBattle\s*\(\s*:([A-Za-z0-9_]+)\s*,\s*(\d+)/).any? { |id, value| id == species.to_s && value.to_i == level }
          end
        end
        raise "Scripted encounter is not declared by the installed map" unless approved
        pokemon = pbGenerateWildPokemon(species, level)
        pokemon.form = 0
        [[pokemon], nil]
      when "trainer"
        type = KIFServerEngine.registered(:TrainerType, params.fetch("trainer_type"))
        key = [type, params.fetch("trainer_name"), params.fetch("trainer_version", 0)]
        raise "Trainer is not installed" unless GameData::Trainer::DATA.key?(key)
        trainer = pbLoadTrainer(*key)
        raise "Trainer level cap exceeded" if trainer.party.any? { |pokemon| pokemon.level > cap }
        [trainer.party, trainer]
      when "boss"
        index = KIFServerEngine.bounded(params.fetch("boss_index"), 0, 7)
        catalog = KIFMultiplayer::WireJSON.parse(File.binread("server/multiplayer/catalog-rental-v1.json"))
        pokemon = KIFMultiplayer::Snapshot.import(catalog["pokemon"][index], 12 + index * 10)
        trainer = NPCTrainer.new("联机徽章挑战 #{index + 1}", $Trainer.trainer_type)
        trainer.party = [pokemon]
        [[pokemon], trainer]
      else
        raise "Unknown certified encounter kind"
      end
    end
    def run(request, party)
      @sequence = 0
      params = request.fetch("params")
      @belt = params.fetch("belt", {}).each_with_object({}) do |(id, count), values|
        symbol = KIFServerEngine.registered(:Item, id)
        values[symbol] = KIFServerEngine.bounded(count, 1, 99)
      end
      $Trainer.name = request["owner"]["name"]
      $Trainer.id = request["owner"]["id"]
      $Trainer.party = party
      $Trainer.badges = Array.new(8) { |index| index < params.fetch("badge_count", 0) } if $Trainer.respond_to?(:badges=)
      $Trainer.instance_variable_set(:@money, params.fetch("wallet", 0))
      $PokemonBag = PokemonBag.new
      @belt.each { |id, count| $PokemonBag.pbStoreItem(id, count) }
      foes, trainer = opponent(request)
      before_money = $Trainer.money
      controller = proc { |state| prompt(request, state) }
      battle = Engine.new(Scene.new, party, foes, $Trainer, trainer, controller, params.fetch("reward_enabled", true))
      decision = battle.pbStartBattle
      {"pokemon" => party.map { |pokemon| KIFServerEngine.export(pokemon) }, "captured" => battle.captured.map { |pokemon| KIFServerEngine.export(pokemon) }, "decision" => decision, "money_delta" => $Trainer.money - before_money, "bag_final" => @belt.keys.each_with_object({}) { |id, values| values[id.to_s] = $PokemonBag.pbQuantity(id) }, "events" => battle.events.last(30)}
    end
  end
end
