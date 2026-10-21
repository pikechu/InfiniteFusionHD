# Native observer rendering. The scaffold never executes commands, move effects,
# damage, AI or rewards; all gameplay values come from authenticated snapshots.
module KIFMultiplayer
  module BattleVisuals
    MAX_EVENTS = 128
    PUBLIC_KEYS = %w[slot species level name hp totalhp status party_index form gender shiny appearance]

    def self.public_pokemon(engine, battler, pokemon = nil)
      pokemon ||= battler.displayPokemon
      appearance = {}
      Snapshot::APPEARANCE_KEYS.each do |key|
        value = pokemon.instance_variable_get("@#{key}")
        value = value.to_s if value.is_a?(Symbol)
        appearance[key] = value.is_a?(Array) ? value.dup : value
      end
      Snapshot.validate_appearance(appearance)
      offset = engine.respond_to?(:online_offset) ? engine.online_offset(battler.index) : 0
      {"slot" => battler.index, "species" => pokemon.species.to_s, "level" => battler.level,
       "name" => KIFMultiplayer.battle_text(battler.name)[0, 32], "hp" => battler.hp,
       "totalhp" => battler.totalhp, "status" => battler.status.to_s,
       "party_index" => battler.pokemonIndex - offset, "form" => pokemon.form,
       "gender" => pokemon.gender, "shiny" => pokemon.shiny? == true, "appearance" => appearance}
    end

    def self.record(engine, event)
      events = engine.instance_variable_get(:@online_visual_events) || []
      engine.instance_variable_set(:@online_visual_events, events)
      if events.length >= MAX_EVENTS
        engine.instance_variable_set(:@online_visual_complete, false)
      else
        events << event
      end
    rescue StandardError
      engine.instance_variable_set(:@online_visual_complete, false)
    end

    def self.attach(engine)
      scene = engine.scene
      return if scene.instance_variable_get(:@kif_visual_authority)
      scene.instance_variable_set(:@kif_visual_authority, true)
      [:pbHPChanged, :pbHitAndHPLossAnimation, :pbChangePokemon, :pbRecall, :pbFaintBattler].each do |method|
        next unless scene.respond_to?(method)
        original = scene.method(method)
        scene.define_singleton_method(method) do |*args|
          begin
            case method
            when :pbHPChanged
              battler, previous = args
              KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "hp", "slot" => battler.index,
                "from" => previous, "to" => battler.hp, "totalhp" => battler.totalhp})
            when :pbHitAndHPLossAnimation
              (args[0] || []).each do |target|
                battler, previous = target
                KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "hp", "slot" => battler.index,
                  "from" => previous, "to" => battler.hp, "totalhp" => battler.totalhp})
              end
            when :pbChangePokemon
              index, pokemon = args
              index = index.index if index.respond_to?(:index)
              battler = engine.battlers[index]
              KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "replace",
                "pokemon" => KIFMultiplayer::BattleVisuals.public_pokemon(engine, battler, pokemon)})
            when :pbRecall
              KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "recall", "slot" => args[0]})
            when :pbFaintBattler
              KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "faint", "slot" => args[0].index})
            end
          rescue StandardError
            engine.instance_variable_set(:@online_visual_complete, false)
          end
          original.call(*args)
        end
      end
    end

    def self.snapshot(engine)
      sequence = (engine.instance_variable_get(:@online_visual_sequence) || 0) + 1
      engine.instance_variable_set(:@online_visual_sequence, sequence)
      {"version" => 1, "seq" => sequence,
       "complete" => engine.instance_variable_get(:@online_visual_complete) != false,
       "events" => WireJSON.parse(WireJSON.dump(engine.instance_variable_get(:@online_visual_events) || [])),
       "battlers" => engine.battlers.compact.map { |battler| public_pokemon(engine, battler) }}
    end

    def self.clear(engine)
      engine.instance_variable_set(:@online_visual_events, [])
      engine.instance_variable_set(:@online_visual_complete, true)
    end

    def self.merge_state(engine, state)
      state.merge("visuals" => snapshot(engine))
    rescue StandardError => error
      # Presentation is optional. A malformed local cosmetic parameter must
      # never invalidate an otherwise legal authority command or settlement.
      engine.instance_variable_set(:@online_visual_complete, false)
      KIFMultiplayer.battle_event("authority_visual_unavailable", {"reason" => error.message.to_s[0, 200]})
      state
    end

    module AuthorityHooks
      def initialize(*args)
        super
        KIFMultiplayer::BattleVisuals.clear(self)
        KIFMultiplayer::BattleVisuals.attach(self)
      end
      def online_state(*args)
        KIFMultiplayer::BattleVisuals.merge_state(self, super)
      end
      def online_boundary(*args)
        result = super
        KIFMultiplayer::BattleVisuals.clear(self)
        result
      end
      def pbAnimation(move, user, targets, hit = 0)
        begin
          id = move.respond_to?(:id) ? move.id.to_s : move.to_s
          KIFMultiplayer::Snapshot.registry(:Move, id)
          slots = [targets].flatten.compact.map { |target| target.index }.uniq
          KIFMultiplayer::BattleVisuals.record(self, {"kind" => "move", "move_id" => id,
            "user" => user.index, "targets" => slots, "hit" => hit})
        rescue StandardError
          instance_variable_set(:@online_visual_complete, false)
        end
        super
      end
    end
    module CooperativeState
      def online_state(*args)
        KIFMultiplayer::BattleVisuals.merge_state(self, super)
      end
    end

    def self.check(condition, message)
      raise BattleError, "Invalid public visual timeline: #{message}" unless condition
    end
    def self.validate_pokemon(value)
      check(value.is_a?(Hash) && value.keys.sort == PUBLIC_KEYS.sort, "Pokemon fields")
      check(Snapshot.number(value["slot"], 0, 3) && Snapshot.number(value["party_index"], 0, 2), "slot")
      Snapshot.registry(:Species, value["species"])
      check(Snapshot.number(value["level"], 1, 100) && Snapshot.number(value["form"], 0, 999), "form/level")
      check(value["name"].is_a?(String) && value["name"].length <= 32 && value["name"] !~ /[\x00-\x1f]/, "name")
      check(Snapshot.number(value["totalhp"], 1, 100000) && Snapshot.number(value["hp"], 0, value["totalhp"]), "HP")
      check(Snapshot.number(value["gender"], 0, 2) && [true, false].include?(value["shiny"]), "gender/shiny")
      if value["status"].is_a?(String)
        Snapshot.registry(:Status, value["status"])
      else
        check(Snapshot.number(value["status"], 0, 100) && GameData::Status.exists?(value["status"]), "status")
      end
      Snapshot.validate_appearance(value["appearance"])
      value
    end
    def self.validate(value, state)
      check(value.is_a?(Hash) && value.keys.sort == %w[battlers complete events seq version].sort && value["version"] == 1, "header")
      check(Snapshot.number(value["seq"], 1, 100000) && [true, false].include?(value["complete"]), "sequence")
      slots = (state["battlers"] || []).map { |battler| battler["index"] }
      check(value["battlers"].is_a?(Array) && value["battlers"].length <= 4, "battlers")
      visual_slots = value["battlers"].map { |pokemon| validate_pokemon(pokemon)["slot"] }
      check(visual_slots.sort == slots.sort && visual_slots.uniq == visual_slots, "public slots disagree")
      check(value["events"].is_a?(Array) && value["events"].length <= MAX_EVENTS, "event count")
      value["events"].each do |event|
        check(event.is_a?(Hash), "event object")
        case event["kind"]
        when "move"
          check(event.keys.sort == %w[hit kind move_id targets user].sort && slots.include?(event["user"]), "move fields")
          Snapshot.registry(:Move, event["move_id"])
          check(event["targets"].is_a?(Array) && event["targets"].length <= 4 && event["targets"].uniq == event["targets"] && (event["targets"] - slots).empty? && Snapshot.number(event["hit"], 0, 20), "move targets")
        when "hp"
          check(event.keys.sort == %w[from kind slot to totalhp].sort && slots.include?(event["slot"]), "HP fields")
          check(Snapshot.number(event["totalhp"], 1, 100000) && Snapshot.number(event["from"], 0, event["totalhp"]) && Snapshot.number(event["to"], 0, event["totalhp"]), "HP range")
        when "replace"
          check(event.keys.sort == %w[kind pokemon] && slots.include?(validate_pokemon(event["pokemon"])["slot"]), "replacement")
        when "recall", "faint"
          check(event.keys.sort == %w[kind slot] && slots.include?(event["slot"]), "battler event")
        else
          raise BattleError, "Unsupported public visual event"
        end
      end
      value
    end
  end

  class VisualBattleScaffold < PokeBattle_Battle
    def pbStartBattle; raise BattleError, "Observer scaffold cannot execute combat"; end
    def pbBattleLoop; raise BattleError, "Observer scaffold cannot execute combat"; end
    def pbCommandPhase; raise BattleError, "Observer scaffold cannot execute commands"; end
    def pbAttackPhase; raise BattleError, "Observer scaffold cannot execute damage"; end
    def pbEndOfRoundPhase; raise BattleError, "Observer scaffold cannot execute effects"; end
    def pbGainExp; end
    def pbGainMoney; end
  end

  class PublicVisualPokemon < Pokemon
    def freeze_visual_capacity(entry)
      @visual_authoritative = true
      @level, @totalhp, @hp = entry["level"], entry["totalhp"], entry["hp"]
    end
    # This fork recalculates stats in Pokemon#level. Public display objects have
    # no private IV/EV/ability data; recalculation must never replace host HP.
    def calc_stats(*args)
      return if @visual_authoritative
      super
    end
    def checkHPRelatedFormChange
      super unless @visual_authoritative
    end
    def form
      @visual_authoritative ? @form : super
    end
  end

  class GuestNativeScene < PokeBattle_Scene
    attr_accessor :visual_session
    def visual_animation_available?(move, user, hit)
      mapping = pbFindMoveAnimation(move, user, hit)
      animations = pbLoadBattleAnimations
      mapping && animations && animations[mapping[0]]
    end
    def pbUpdate(*args)
      super
      return unless @visual_session
      @visual_session.heartbeat(true)
      result = @visual_session.battle["result"] || {}
      raise ServerTerminal if @visual_session.terminal? && result["abnormal"]
    end

    # Native animation player, with an ensure missing from the original method.
    # A disconnect/terminal signal cannot leak its 60 transient particle sprites.
    def pbAnimationCore(animation, user, target, opposing = false)
      return unless animation
      @briefMessage = false
      user_sprite = user && @sprites["pokemon_#{user.index}"]
      target_sprite = target && @sprites["pokemon_#{target.index}"]
      ux, uy = user_sprite ? [user_sprite.x, user_sprite.y] : [0, 0]
      tx, ty = target_sprite ? [target_sprite.x, target_sprite.y] : [ux, uy]
      player = PBAnimationPlayerX.new(animation, user, target, self, opposing)
      uh = user_sprite && user_sprite.bitmap ? user_sprite.bitmap.height : 128
      th = target_sprite && target_sprite.bitmap ? target_sprite.bitmap.height : uh
      player.setLineTransform(PokeBattle_SceneConstants::FOCUSUSER_X, PokeBattle_SceneConstants::FOCUSUSER_Y,
        PokeBattle_SceneConstants::FOCUSTARGET_X, PokeBattle_SceneConstants::FOCUSTARGET_Y,
        ux, uy - uh / 2, tx, ty - th / 2)
      player.start
      loop do
        player.update
        pbUpdate
        break if player.animDone?
      end
    ensure
      player.dispose if player
      [[user_sprite, ux, uy], [target_sprite, tx, ty]].each do |sprite, x, y|
        next unless sprite && !sprite.disposed?
        sprite.x, sprite.y = x, y
        sprite.pbSetOrigin
      end
    end
  end

  class GuestBattlePresenter
    attr_reader :scene
    def self.with(session)
      old_scene, old_update = $scene, session.client.wait_update
      presenter = new(session)
      BattleIsolation.with do
        BattlePresentation.with(presenter.scene) do
          # The observer has no overworld update loop. Native windows therefore
          # cannot advance map events or UnrealTime in the original save.
          $scene = Object.new
          session.presenter = presenter
          session.client.wait_update = proc { presenter.update }
          result = yield
          presenter.finish
          result
        ensure
          session.client.wait_update = nil
          $scene = old_scene
        end
      end
    ensure
      presenter.dispose_transients if presenter
      session.presenter = nil
      session.client.wait_update = old_update
      $scene = old_scene
    end
    def initialize(session)
      @session = session
      @scene = GuestNativeScene.new
      @scene.visual_session = session
      @ready, @failed, @last_sequence = false, false, 0
      @wire = {}
    end
    def active?; @ready && !@failed; end
    def render_index(index)
      @session.battle["mode"] == "coop_boss" ? index : index ^ 1
    end
    def party_index(entry)
      @session.battle["mode"] == "coop_boss" && entry["slot"] == 2 ? 3 + entry["party_index"] : entry["party_index"]
    end
    def pokemon_from(entry)
      BattleVisuals.validate_pokemon(entry)
      pokemon = PublicVisualPokemon.new(entry["species"], entry["level"], nil, false, false)
      pokemon.form = entry["form"]
      pokemon.name = KIFMultiplayer.battle_text(entry["name"])
      pokemon.gender, pokemon.shiny = entry["gender"], entry["shiny"]
      entry["appearance"].each do |key, value|
        value = value.to_sym if key == "size_category" && value
        value = value.dup if value.is_a?(Array) || value.is_a?(String)
        pokemon.instance_variable_set("@#{key}", value)
      end
      pokemon.freeze_visual_capacity(entry)
      status = GameData::Status.get(entry["status"]).id
      pokemon.instance_variable_set(:@status, status)
      pokemon
    end
    def build(state, visuals)
      cooperative = @session.battle["mode"] == "coop_boss"
      p1, p2 = Array.new(cooperative ? 6 : 3), Array.new(cooperative ? 1 : 3)
      visuals["battlers"].each do |entry|
        side = render_index(entry["slot"]) % 2
        (side == 0 ? p1 : p2)[party_index(entry)] = pokemon_from(entry)
      end
      own = cooperative ? p1[3, 3] : p1
      $Trainer.party = own
      players = $Trainer
      if cooperative
        partner = NPCTrainer.new("Online partner", $Trainer.trainer_type)
        partner.party = p1[3, 3]
        players = [$Trainer, partner]
      end
      opponent = NPCTrainer.new(cooperative ? "Cooperative Boss" : "Online friend", $Trainer.trainer_type)
      opponent.party = p2
      @scaffold = VisualBattleScaffold.new(@scene, p1, p2, players, opponent)
      @scaffold.internalBattle, @scaffold.expGain, @scaffold.moneyGain = false, false, false
      @scaffold.backdrop, @scaffold.backdropBase = "indoora", "indoora"
      @scaffold.showAnims = $PokemonSystem.battlescene == 0
      @scaffold.party1starts = [0, 3] if cooperative
      @scaffold.setBattleMode(cooperative ? "2v1" : "single")
      visuals["battlers"].each do |entry|
        index = render_index(entry["slot"])
        pokemon = (index.even? ? p1 : p2)[party_index(entry)]
        @scaffold.pbCreateBattler(index, pokemon, party_index(entry))
      end
      apply_field(state)
      @scene.pbStartBattle(@scaffold)
      @ready = true
      KIFMultiplayer.battle_event("guest_native_started", {"battle_id" => @session.battle_id, "slots" => visuals["battlers"].map { |entry| entry["slot"] }, "reserves" => "public placeholders only"})
    end
    def install(entry)
      index = render_index(entry["slot"])
      pokemon = pokemon_from(entry)
      @scaffold.pbParty(index)[party_index(entry)] = pokemon
      @scaffold.battlers[index].pbInitialize(pokemon, party_index(entry))
      @wire[entry["slot"]] = entry
      pokemon
    end
    def apply_field(state)
      weather = GameData::BattleWeather.try_get(state["weather"])
      terrain = GameData::BattleTerrain.try_get(state["terrain"])
      @scaffold.field.weather = weather.id if weather
      @scaffold.field.terrain = terrain.id if terrain
    end
    def apply_final(state, visuals)
      visuals["battlers"].each do |entry|
        pokemon = install(entry)
        index = render_index(entry["slot"])
        @scene.pbChangePokemon(index, pokemon)
        sprites = @scene.instance_variable_get(:@sprites)
        sprites["pokemon_#{index}"].visible = entry["hp"] > 0
        sprites["dataBox_#{index}"].visible = entry["hp"] > 0
      end
      apply_field(state)
      @scene.pbRefresh
      rendered = visuals["battlers"].map do |entry|
        battler = @scaffold.battlers[render_index(entry["slot"])]
        status = GameData::Status.get(entry["status"]).id.to_s
        unless battler.hp == entry["hp"] && battler.totalhp == entry["totalhp"] && battler.status.to_s == status
          raise BattleError, "Native observer values diverged from authority"
        end
        {"index" => entry["slot"], "hp" => battler.hp, "totalhp" => battler.totalhp,
         "status" => battler.status.to_s, "species" => battler.displaySpecies.to_s}
      end
      KIFMultiplayer.battle_event("guest_visual_applied", {"battle_id" => @session.battle_id, "seq" => visuals["seq"], "battlers" => state["battlers"], "rendered_battlers" => rendered})
    end
    def play(event)
      native = true
      case event["kind"]
      when "move"
        user = @scaffold.battlers[render_index(event["user"])]
        targets = event["targets"].map { |slot| @scaffold.battlers[render_index(slot)] }
        if @scaffold.showAnims
          raise BattleError, "Missing native move animation #{event['move_id']}" unless @scene.visual_animation_available?(event["move_id"].to_sym, user.index, event["hit"])
          @scene.pbAnimation(event["move_id"].to_sym, user, targets, event["hit"])
        else
          native = false
        end
      when "hp"
        battler = @scaffold.battlers[render_index(event["slot"])]
        battler.instance_variable_set(:@totalhp, event["totalhp"])
        battler.pokemon.instance_variable_set(:@totalhp, event["totalhp"])
        battler.hp = event["to"]
        @scene.pbHPChanged(battler, event["from"], true)
      when "recall"
        @scene.pbRecall(render_index(event["slot"]))
      when "replace"
        entry = event["pokemon"]
        pokemon = install(entry)
        @scene.pbSendOutBattlers([[render_index(entry["slot"]), pokemon]], @last_sequence == 0)
      when "faint"
        @scene.pbFaintBattler(@scaffold.battlers[render_index(event["slot"])])
      end
      KIFMultiplayer.battle_event("guest_visual_event", {"battle_id" => @session.battle_id, "event" => event, "native" => native})
    end
    def accept(state)
      return if @failed
      visuals = BattleVisuals.validate(state["visuals"], state)
      # A visual batch is cosmetic metadata, not a second HP/status authority.
      # Validate its final active entries before playing any effects; the board
      # fallback then renders the actual state if the two records disagree.
      visuals["battlers"].each do |pokemon|
        battler = state["battlers"].find { |entry| entry["index"] == pokemon["slot"] }
        %w[species hp totalhp status level party_index].each do |key|
          BattleVisuals.check(!battler.key?(key) || battler[key] == pokemon[key], "visual final state differs from authoritative #{key}")
        end
      end
      raise BattleError, "Authority visual batch was truncated" unless visuals["complete"]
      return if visuals["seq"] <= @last_sequence
      first = !@ready
      build(state, visuals) if first
      if first && visuals["seq"] > 1
        KIFMultiplayer.battle_event("guest_visual_reconnected", {"seq" => visuals["seq"], "reason" => "restored current public state; past effects were not recomputed"})
      else
        visuals["events"].each { |event| play(event) }
      end
      apply_final(state, visuals)
      @last_sequence = visuals["seq"]
    rescue StandardError => error
      fallback(error)
    end
    def update
      if active?
        @scene.pbGraphicsUpdate
        @scene.pbFrameUpdate
        @session.heartbeat(true)
        raise ServerTerminal if @session.terminal? && (@session.battle["result"] || {})["abnormal"]
      end
    rescue StandardError => error
      fallback(error)
    end
    def decorate_windows(*windows)
      @decorated_windows ||= []
      @decorated_windows.reject! { |window| window.respond_to?(:disposed?) && window.disposed? }
      @decorated_windows.concat(windows)
      windows.each { |window| window.viewport = @scene.viewport if window.respond_to?(:viewport=) }
    end
    def message(text)
      @scene.pbDisplayMessage(KIFMultiplayer.battle_text(text))
    rescue StandardError => error
      fallback(error)
    end
    def finish
      @scene.pbEndBattle(@session.result_decision) if active?
    rescue StandardError => error
      fallback(error)
    end
    def fallback(error)
      return if @failed
      @failed = true
      (@decorated_windows || []).each do |window|
        next if window.respond_to?(:disposed?) && window.disposed?
        window.viewport = nil if window.respond_to?(:viewport=)
      end
      dispose_transients
      (@scene.instance_variable_get(:@sprites) || {}).each_value { |sprite| BattlePresentation.dispose(sprite) }
      BattlePresentation.dispose(@scene.instance_variable_get(:@viewport))
      KIFMultiplayer.battle_event("guest_visual_fallback", {"battle_id" => @session.battle_id, "reason" => error.message.to_s[0, 200], "complete_animation" => false})
      KIFMultiplayer.log_error(error) if KIFMultiplayer.respond_to?(:log_error)
      @session.message("原生战斗动画不可用，已切换权威快照界面；战斗逻辑继续。") unless KIFMultiplayer.battle_controller
    end
    def dispose_transients
      viewport = @scene.instance_variable_get(:@viewport)
      return unless viewport && ObjectSpace.respond_to?(:each_object)
      ObjectSpace.each_object(PokeBattle_Animation) do |animation|
        next unless animation.instance_variable_get(:@viewport).equal?(viewport)
        (animation.instance_variable_get(:@tempSprites) || []).each { |sprite| BattlePresentation.dispose(sprite) }
      end
    rescue StandardError
      nil
    end
    def self.renderRecordedFrames(session, frames)
      with(session) do
        frames.each { |frame| session.presenter.accept(frame["state"] || frame) }
      end
    end
  end
end

KIFMultiplayerBattle.prepend(KIFMultiplayer::BattleVisuals::AuthorityHooks)
KIFMultiplayerBossBattle.prepend(KIFMultiplayer::BattleVisuals::CooperativeState) if defined?(KIFMultiplayerBossBattle)
