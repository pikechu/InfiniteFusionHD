module KIFMultiplayer
  class OriginalVisualPokemon < PublicVisualPokemon
    def original_appearance=(value); @original_appearance = value || {}; end
    {shinyValue?: "hue", shinyR?: "red", shinyG?: "green", shinyB?: "blue", shinyKRS?: "krs", shinyimprovpif?: "pif_shiny"}.each do |method, field|
      define_method(method) { @original_appearance && @original_appearance.key?(field) ? @original_appearance[field] : super() }
    end
    def shinyOmega?
      return super unless @original_appearance
      @original_appearance.slice("pif_shiny", "body_shiny", "head_shiny").merge("dexNum" => species_data.id_number)
    end
    def sprite_scale; @original_appearance ? @original_appearance.fetch("scale",1) : super; end
  end
  class OriginalVisualMove < Pokemon::Move
    def initialize(entry)
      super(entry.fetch("id").to_sym)
      @visual_total_pp = entry.fetch("total_pp")
      self.pp = entry.fetch("pp")
    end
    def total_pp; @visual_total_pp || super; end
  end
  class OriginalVisualSession
    attr_accessor :presenter
    attr_reader :client, :model, :battle_id
    def initialize(model)
      @model, @client = model, model.client
      @battle_id = "original_#{model.character['id']}"
      @decision = 0
    end
    def battle; {"mode" => "original", "result" => {}}; end
    def terminal?; !@model.original["view"]["battle"]; end
    def heartbeat(*); @model.heartbeat; end
    def result_decision; @decision; end
    def decision=(value); @decision = value; end
    def message(text); pbMessage(KIFMultiplayer.display_text(text)); end
  end
  class OriginalBattlePresenter < GuestBattlePresenter
    def self.with(session)
      super(session) { yield(session.presenter) }
    end
    def render_index(index); index; end
    def party_index(entry); entry["party_index"]; end
    def pokemon_from(entry)
      raise Error, "原版战斗精灵摘要无效。" unless entry["species"].is_a?(String) && entry["level"].is_a?(Integer) && entry["hp"].is_a?(Integer) && entry["totalhp"].is_a?(Integer) && entry["hp"].between?(0, entry["totalhp"])
      pokemon = OriginalVisualPokemon.new(entry["species"].to_sym, entry["level"], nil, false, false)
      pokemon.original_appearance = entry["appearance"]
      pokemon.form = entry["form"] || 0
      pokemon.name = KIFMultiplayer.battle_text(entry["name"])
      pokemon.gender, pokemon.shiny = entry["gender"] || 2, entry["shiny"] == true
      pokemon.exp = entry["exp"] if entry["exp"]
      pokemon.moves = entry["moves"].map { |move| OriginalVisualMove.new(move) } if entry["moves"]
      pokemon.ability = entry["ability"].to_sym if entry["ability"]
      pokemon.ability2 = entry["ability2"].to_sym if entry["ability2"]
      pokemon.item = entry["item"].to_sym if entry["item"]
      pokemon.freeze_visual_capacity(entry)
      pokemon.instance_variable_set(:@status, GameData::Status.get(entry["status"].to_sym).id)
      pokemon
    end
    def visual_entry(monster, slot, party_index)
      monster.merge("slot" => slot, "party_index" => party_index, "totalhp" => monster["max_hp"])
    end
    def visuals(state)
      state["battlers"].map do |entry|
        party = entry["index"].even? ? state["party"] : state["enemies"]
        monster = party.fetch(entry["party_index"])
        visual_entry(monster, entry["index"], entry["party_index"]).merge("hp" => entry["hp"], "status" => entry["status"])
      end
    end
    def build_original(state)
      $game_switches[SWITCH_DOUBLE_ABILITIES] = state["double_abilities"] == true
      trainer_view = @session.model.original["view"].fetch("trainer")
      {"character_ID" => "character_id", "clothes" => "clothes", "hat" => "hat", "hair" => "hair", "skin_tone" => "skin",
       "clothes_color" => "clothes_color", "hat_color" => "hat_color", "hair_color" => "hair_color"}.each do |field, key|
        $Trainer.instance_variable_set("@#{field}", trainer_view[key])
      end
      own = state["party"].map { |monster| pokemon_from(visual_entry(monster, 0, 0)) }
      enemy = state["enemies"].map { |monster| pokemon_from(visual_entry(monster, 1, 0)) }
      starts = state.fetch("party_starts", [0])
      players = state.fetch("players", []).each_with_index.map do |info, index|
        trainer = index == 0 ? $Trainer : NPCTrainer.new(info["name"], info["type"].to_sym)
        trainer.name = info["name"]
        trainer.party = own[starts[index]...(starts[index+1] || own.length)]
        trainer
      end
      players = [$Trainer] if players.empty?
      players.first.party = own if starts.length == 1
      enemy_starts = state.fetch("enemy_starts", [0])
      opponents = state["opponents"].each_with_index.map do |info, index|
        trainer = NPCTrainer.new(info["name"], info["type"].to_sym)
        trainer.party = enemy[enemy_starts[index]...(enemy_starts[index+1] || enemy.length)]
        trainer
      end
      opponent = opponents.empty? ? nil : opponents.length == 1 ? opponents.first : opponents
      @scaffold = VisualBattleScaffold.new(@scene, own, enemy, players.length == 1 ? players.first : players, opponent)
      @scaffold.party1starts, @scaffold.party2starts = starts, enemy_starts
      @scaffold.internalBattle, @scaffold.expGain, @scaffold.moneyGain = false, false, false
      @scaffold.backdrop, @scaffold.backdropBase = state["backdrop"] || "field", state["backdrop_base"]
      @scaffold.time = state["time"] || 0
      @scaffold.showAnims = $PokemonSystem.battlescene == 0
      @scaffold.setBattleMode(state.fetch("sides", [1,1]).join("v"))
      visuals(state).each do |entry|
        pokemon = (entry["slot"].even? ? own : enemy).fetch(entry["party_index"])
        @scaffold.pbCreateBattler(entry["slot"], pokemon, entry["party_index"])
        @wire[entry["slot"]] = entry
      end
      apply_field(state)
      @scene.pbStartBattle(@scaffold)
      [1,0].each do |side|
        next if side == 1 && opponents.empty?
        entries = visuals(state).select { |entry| entry["slot"] % 2 == side }
        @scene.pbSendOutBattlers(entries.map { |entry| [entry["slot"], @scaffold.battlers[entry["slot"]].pokemon] }, true)
      end
      @ready = true
    end
    def accept_original(response)
      $PokemonBag = PokemonBag.new
      @session.model.character["inventory"].each do |item|
        raise Error, "原版背包显示容量不兼容。" unless $PokemonBag.pbStoreItem(item["item"].to_sym, item["quantity"])
      end
      $Trainer.money = @session.model.character["wallet"]["balance"]
      state = @session.model.original["view"]["battle"]
      build_original(state) if state && !@ready
      (response["events"] || []).each do |event|
        case event["kind"]
        when "battle_end"
          @session.decision = event["decision"]
        when "message"
          message(event["text"]) if active?
        when "move_animation"
          play({"kind" => "move", "move_id" => event["move"], "user" => event["user"], "targets" => event["targets"], "hit" => event["hit"]}) if active?
        when "hp"
          next unless active? && @wire[event["battler"]]
          play({"kind" => "hp", "slot" => event["battler"], "from" => event["before"], "to" => event["after"], "totalhp" => @wire[event["battler"]]["totalhp"]})
        when "faint"
          play({"kind" => "faint", "slot" => event["battler"]}) if active?
        when "throw"
          @scene.pbThrow(event["ball"].to_sym, event["shakes"], event["critical"], event["target"], event["show_player"]) if active?
        when "throw_deflect"
          @scene.pbThrowAndDeflect(event["ball"].to_sym, event["target"]) if active?
        when "exp_bar"
          if active? && @scaffold.battlers[event["battler"]]
            @scene.pbEXPBar(@scaffold.battlers[event["battler"]], event["minimum"], event["maximum"], event["before"], event["after"])
          end
        when "level_up"
          if active? && @wire[event["battler"]]
            old = @wire[event["battler"]]
            pokemon = install(visual_entry(event["monster"], old["slot"], old["party_index"]))
            @scene.pbLevelUp(pokemon, @scaffold.battlers[old["slot"]], *event["old_stats"])
          end
        end
      end
      if state && active?
        visuals(state).each do |entry|
          old = @wire[entry["slot"]]
          pokemon = install(entry)
          if old && old["party_index"] != entry["party_index"]
            @scene.pbSendOutBattlers([[entry["slot"], pokemon]], false)
          else
            @scene.pbChangePokemon(entry["slot"], pokemon)
          end
          battler = @scaffold.battlers[entry["slot"]]
          source = state["battlers"].find { |value| value["index"] == entry["slot"] }
          source["stages"].each { |key, value| battler.stages[key.to_sym] = value } if source["stages"]
        end
        apply_field(state)
        @scene.pbRefresh
      end
    end
    def prompt_value(prompt, ui)
      index = prompt.fetch("battler", 0)
      case prompt["kind"]
      when "command" then @scene.pbCommandMenu(index, true)
      when "move"
        value = nil
        @scene.pbFightMenu(index, prompt["mega"]) { |selected| value = selected; true }
        value
      when "switch"
        value = nil
        @scene.pbPartyScreen(index, prompt["cancel"]) { |selected, _| value = selected; true }
        value
      when "item"
        value = nil
        @scene.pbItemMenu(index, prompt["first"]) do |item, _use, target, move, _|
          value = {"item" => item.to_s, "target" => target, "move" => move || -1}
          true
        end
        value
      when "target"
        target = GameData::Target.get(prompt["target_type"].to_sym)
        @scene.pbChooseTarget(index, target)
      else ui.prompt_value(prompt)
      end
    end
  end

  class OriginalSafariPresenter < OriginalBattlePresenter
    def accept_original(response)
      state = @session.model.original["view"]["battle"]
      if state && !@ready
        enemies = state["enemies"].map { |monster| pokemon_from(visual_entry(monster,1,0)) }
        @scaffold = PokeBattle_SafariZone.new(@scene,$Trainer,enemies)
        @scaffold.ballCount = state["balls"]
        @scaffold.backdrop, @scaffold.backdropBase, @scaffold.time = state["backdrop"], state["backdrop_base"], state["time"]
        @scaffold.showAnims = $PokemonSystem.battlescene == 0
        @scene.pbStartBattle(@scaffold)
        @scene.pbSafariStart
        @ready = true
      end
      @scaffold.ballCount = state["balls"] if state && @scaffold
      (response["events"] || []).each do |event|
        case event["kind"]
        when "battle_end" then @session.decision = event["decision"]
        when "message" then message(event["text"])
        when "safari_bait" then @scene.pbThrowBait
        when "safari_rock" then @scene.pbThrowRock
        when "throw" then @scene.pbThrow(event["ball"].to_sym,event["shakes"],event["critical"],event["target"],event["show_player"])
        end
      end
      @scene.pbRefresh if active?
    end
    def prompt_value(prompt, ui)
      prompt["kind"] == "safari_command" ? @scene.pbSafariCommandMenu(0) : ui.prompt_value(prompt)
    end
  end
end
