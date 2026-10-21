# A deliberately single-authority adapter: only the host executes the real
# PokeBattle_Battle engine. The other client selects actions and displays the
# authority's public snapshots. This is NOT a deterministic dual-engine replay.
module KIFMultiplayer
  class BattleError < StandardError; end
  class BattleTerminated < BattleError; end
  # An official server result ends every local engine stack, including an
  # animation or a move's nested replacement request. It must pass through the
  # engine's inner bare-rescue handlers without becoming a gameplay error.
  class ServerTerminal < Exception; end
  # Must pass through the engine's inner PBDebug.logonerr (bare rescue), then
  # become a normal UI error after the engine stack has unwound.
  class BattleInterrupted < Exception
    attr_reader :original
    def initialize(original)
      @original = original
      super(original.message)
    end
  end

  class << self
    attr_accessor :battle_controller, :battle_observer

    def battle_event(event, payload)
      @battle_observer.call(event, payload) if @battle_observer
    end

    def battle_digest(state)
      require "digest/sha2"
      Digest::SHA256.hexdigest(WireJSON.dump(state))
    end

    def battle_text(value)
      # Network strings are data, not RGSS message/window formatting commands.
      value.to_s.gsub("\\", "＼").gsub("<", "＜").gsub(">", "＞").gsub(/[\x00-\x08\x0b-\x1f]/, "")
    end

    # Network pumping already performs Graphics/Input.update. Calling the
    # scene's full pbUpdate here would update Input twice and swallow the USE
    # edge in the remote-command window before it can be handled.
    def battle_wait_update(scene, session)
      proc do
        scene.pbGraphicsUpdate
        scene.pbFrameUpdate
        session.heartbeat
      end
    end

    def battle_confirm(text, session = nil)
      # Legacy pbConfirmMessage/pbShowCommands do not ensure either window is
      # disposed when a terminal heartbeat interrupts the confirmation.
      message_window = command_window = nil
      showing = $game_temp.message_window_showing if $game_temp.respond_to?(:message_window_showing)
      begin
        message_window = pbCreateMessageWindow
        message_window.letterbyletter = false
        message_window.text = text
        command_window = Window_CommandPokemonEx.new([_INTL("Yes"), _INTL("No")])
        command_window.z = 99999
        command_window.resizeToFit(command_window.commands)
        pbPositionNearMsgWindow(command_window, message_window, :right)
        session.presenter.decorate_windows(message_window, command_window) if session && session.native_presenter?
        loop do
          KIFMultiplayer.pump
          command_window.update
          message_window.update
          if session
            update = session.client.wait_update
            update.call if update
            session.heartbeat
          end
          return false if Input.trigger?(Input::BACK)
          return command_window.index == 0 if Input.trigger?(Input::USE)
        end
      ensure
        BattlePresentation.dispose(command_window)
        BattlePresentation.dispose(message_window)
        $game_temp.message_window_showing = showing if $game_temp.respond_to?(:message_window_showing=)
        Input.update if defined?(Input)
      end
    end
  end

  # Marshal is used ONLY on in-memory local game objects, never on network data.
  # The original objects remain untouched and are restored even on exceptions.
  # Item consumption in this fork can directly delete items from $PokemonBag,
  # and the standard battle ending may autosave. Merely cloning parties is not
  # sufficient protection, so the adapter also replaces the relevant globals.
  module BattleIsolation
    PRESENTATION = [:textspeed, :battlescene, :frame, :textskin, :language,
                    :bgmvolume, :sevolume, :battlegui, :darkmode, :kurayshinyanim,
                    :speedvalue, :speedtoggle, :speeduplimit, :speedvaluedef,
                    :download_sprites, :on_mobile]

    def self.copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def self.with
      originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem,
                   $game_switches, $game_variables]
      detached = originals[0, 3].map { |value| copy(value) }
      standard = PokemonSystem.new
      PRESENTATION.each do |field|
        next unless originals[3].respond_to?(field) && standard.respond_to?("#{field}=")
        standard.send("#{field}=", originals[3].send(field))
      end
      # These defaults are part of friendly-singles-v1: single ability, normal type
      # chart, damage variance, normal fusion stats/IVs/EVs and no challenges.
      standard.instance_variable_set(:@damage_variance, 1)
      standard.instance_variable_set(:@is_in_battle, true)
      # The native shiny-channel getters randomize channels >11 unless the
      # expanded palette is enabled. Keep validated 0..25 public colors intact.
      standard.instance_variable_set(:@shinyadvanced, 2)
      # Missing-sprite downloads use the runtime's unsafe native HTTPLite.
      # Cached/local sprites remain usable; restore the user's original option
      # with the original settings object when this isolated battle exits.
      standard.download_sprites = 1 if standard.respond_to?(:download_sprites=)
      fresh_switches = originals[4].class.new
      fresh_variables = originals[5].class.new
      begin
        $Trainer, $PokemonBag, $PokemonGlobal = detached
        $PokemonSystem = standard
        $game_switches, $game_variables = fresh_switches, fresh_variables
        yield
      ensure
        $Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem,
          $game_switches, $game_variables = originals
      end
    end
  end

  # The game's generic pbBattleAnimation/pbSceneStandby wrappers have no ensure
  # clauses. Keep this external battle's scene lifetime explicit so network or
  # engine errors cannot leave the map disposed, the battle flag set or audio
  # paused. The native battle scene still performs its own intro/animations.
  module BattlePresentation
    def self.dispose(object)
      return unless object && object.respond_to?(:dispose)
      return if object.respond_to?(:disposed?) && object.disposed?
      object.dispose
    rescue StandardError
      # One already-broken sprite must not prevent the other resources and
      # original overworld flags from being restored after an engine failure.
      nil
    end

    def self.with(scene)
      previous_flag = $game_temp.in_battle
      previous_alt = $PokemonTemp.forced_alt_sprites
      previous_rules = $PokemonTemp.instance_variable_get(:@battleRules)
      previous_scene = $scene
      map_scene = defined?(Scene_Map) && previous_scene.is_a?(Scene_Map) ? previous_scene : nil
      map_hidden = false
      playing_bgm = $game_system.getPlayingBGM if $game_system.respond_to?(:getPlayingBGM)
      begin
        $game_temp.in_battle = true
        $PokemonTemp.forced_alt_sprites = nil
        $PokemonTemp.instance_variable_set(:@battleRules, {})
        if map_scene
          map_hidden = true
          map_scene.disposeSpritesets
        end
        # Spriteset_Map.dispose needs the original $scene.map_renderer to
        # decrement its tileset/autotile references. Detach only after that
        # synchronous disposal, before any message/confirmation can tick maps.
        $scene = Object.new
        $game_system.bgm_pause if $game_system.respond_to?(:bgm_pause)
        yield
      ensure
        interrupted = $!
        $game_temp.in_battle = previous_flag
        $PokemonTemp.forced_alt_sprites = previous_alt
        $PokemonTemp.instance_variable_set(:@battleRules, previous_rules)
        $scene = previous_scene
        failures = []
        # One renderer/audio failure must not prevent the remaining cleanup or
        # replace an already-unwinding ServerTerminal/battle exception.
        [proc { (scene.instance_variable_get(:@sprites) || {}).each_value { |sprite| dispose(sprite) } },
         proc { (scene.instance_variable_get(:@animations) || []).each { |animation| dispose(animation) } },
         proc { dispose(scene.instance_variable_get(:@win_display_text)) },
         proc { dispose(scene.instance_variable_get(:@viewport)) },
         proc { $game_system.bgm_resume(playing_bgm) if $game_system.respond_to?(:bgm_resume) },
         proc { map_scene.createSpritesets if map_hidden },
         proc { Graphics.frame_reset }].each do |restore|
          begin
            restore.call
          rescue StandardError => error
            failures << error
          end
        end
        failures.each do |error|
          begin
            KIFMultiplayer.log_error(error) if KIFMultiplayer.respond_to?(:log_error)
          rescue StandardError
            nil
          end
        end
        raise failures.first if !interrupted && !failures.empty?
      end
    end
  end

  class BattleSession
    attr_reader :client, :battle, :player_id, :battle_id
    attr_accessor :presenter

    def initialize(client, battle)
      @client = client
      @battle = battle
      @player_id = client.player_id
      @battle_id = battle["battle_id"] || battle["id"]
      raise BattleError, "Missing battle identifier" unless @battle_id.is_a?(String)
      @path = "/v1/battles/#{@battle_id}"
      @operations = {}
      # Per in-memory engine instance, never recovered from a profile receipt.
      @authority_id = KIFMultiplayer.operation_id
      @authority_attempted = @authority_claimed = @authority_conflict = false
      @next_heartbeat = Time.now + 2
      @heartbeating = false
    end

    def host?
      @battle["host_id"] == @player_id
    end

    def authority_payload(payload)
      host? ? payload.merge("authority_id" => @authority_id) : payload
    end

    def authority_error?(error)
      %w[authority_conflict authority_required].include?(error.code)
    end

    def claim_authority
      return @battle unless host? && !terminal?
      @authority_attempted = true
      mutate("authority", {"authority_id" => @authority_id})
      @authority_claimed = !terminal?
      @battle
    end

    def adopt(response)
      value = response["battle"] || response
      raise BattleError, "Malformed battle response" unless value.is_a?(Hash)
      identifier = value["battle_id"] || value["id"]
      raise BattleError, "Response belongs to a different battle" if identifier && identifier != @battle_id
      # A request can pump the scene and perform a heartbeat before its own
      # response is consumed. Do not rewind a more recent state with that older
      # (or recovered idempotent-operation) response.
      if @battle && value["turn"].is_a?(Integer) && @battle["turn"].is_a?(Integer)
        ranks = {"initializing" => 0, "commands" => 1, "locked" => 2, "playback" => 3, "finished" => 4}
        return @battle if value["turn"] < @battle["turn"] ||
          value["turn"] == @battle["turn"] && ranks.fetch(value["phase"], 0) < ranks.fetch(@battle["phase"], 0)
      end
      @battle = value
      @battle
    end

    def fetch
      started = Time.now
      @fetching = true
      begin
        response = if host? && @authority_attempted && !terminal?
                     @client.request("POST", "#{@path}/heartbeat", {"authority_id" => @authority_id})
                   else
                     @client.request("GET", @path)
                   end
        adopt(response)
      rescue KIFMultiplayer::UncertainRequest
        # Preserve the in-memory authority stack while the server charges the
        # cumulative disconnect allowance. Reconnect always queries first.
        raise if Time.now - started >= 70
        KIFMultiplayer.battle_event("reconnecting", {"battle_id" => @battle_id})
        pause(0.5)
        retry
      rescue KIFMultiplayer::Error => error
        @authority_conflict = true if authority_error?(error)
        raise
      ensure
        @fetching = false
      end
    end

    def heartbeat(allow_terminal = false)
      return if @heartbeating || @fetching || @mutating || Time.now < @next_heartbeat
      begin
        @heartbeating = true
        @next_heartbeat = Time.now + 2
        fetch
        raise ServerTerminal if terminal? && !allow_terminal
      rescue StandardError => error
        raise BattleInterrupted.new(error)
      ensure
        @heartbeating = false
      end
    end

    def pause(seconds = 0.25)
      until_time = Time.now + seconds
      @client.pump while Time.now < until_time
    end

    # A timed-out mutation may have committed. Query the operation and battle
    # before retrying with the SAME request ID; never create a second operation.
    def mutate(endpoint, payload)
      key = [endpoint, payload["turn"]]
      request_id = (@operations[key] ||= KIFMultiplayer.operation_id)
      payload = authority_payload(payload.merge("request_id" => request_id))
      attempts = 0
      retry_deadline = Time.now + 75
      @mutating = true
      begin
        response = @client.request("POST", "#{@path}/#{endpoint}", payload)
        document = response["battle"]
        if endpoint == "resolve" && document && !terminal_document?(document) && !resolved_payload?(document, payload)
          raise BattleError, "Accepted authority response differs from this engine phase"
        end
        adopt(response)
      rescue KIFMultiplayer::Error => failure
        if authority_error?(failure)
          @authority_conflict = true
          raise
        end
        attempts += 1
        begin
          operation = @client.request("GET", "/v1/operations/#{payload['request_id']}")
          result = operation["result"] || operation["response"]
          if result.is_a?(Hash) && result["battle"]
            if endpoint == "resolve" && !terminal_document?(result["battle"]) && !resolved_payload?(result["battle"], payload)
              raise BattleError, "Recovered authority resolution differs from this engine phase"
            end
            return adopt(result)
          end
        rescue KIFMultiplayer::Error
          # Unknown operation is not proof of failure; inspect the battle too.
        end
        fetch
        return @battle if terminal?
        return @battle if endpoint == "commands" &&
          ((@battle["submitted"] || []).include?(@player_id) || @battle["turn"].to_i > payload["turn"].to_i)
        if endpoint == "resolve" &&
           (@battle["turn"].to_i > payload["turn"].to_i || @battle["phase"] == "playback")
          raise BattleError, "Authority state diverged from this engine phase" unless resolved_payload?(@battle, payload)
          return @battle
        end
        return @battle if endpoint == "ack" && @battle["turn"].to_i > payload["turn"].to_i
        if failure.code == "battle_paused" && Time.now < retry_deadline
          pause(0.5)
          retry
        end
        raise if attempts >= 2
        pause
        retry
      ensure
        @mutating = false
      end
    end

    def resolved_payload?(document, payload)
      update = (document["updates"] || []).find { |entry| entry["turn"] == payload["turn"] }
      update && (update["digest"] || update["state_hash"]) == payload["digest"] &&
        update["decision"] == payload["decision"] && update["random_tape"] == payload["random_tape"]
    end

    def terminal?
      terminal_document?(@battle)
    end

    def terminal_document?(document)
      document["phase"] == "finished" || %w[finished abnormal].include?(document["status"])
    end

    def native_presenter?
      @presenter && @presenter.active?
    end

    def wait_for
      started = Time.now
      loop do
        return @battle if yield(@battle)
        raise ServerTerminal if terminal?
        # Bounded even if an incompatible server never advances its state.
        raise BattleError, "Battle synchronization exceeded 180 seconds" if Time.now - started > 180
        pause
        fetch
      end
    end

    def state
      @battle["snapshot"] || @battle["state"] || {}
    end

    def submit(command)
      mutate("commands", {"turn" => @battle["turn"], "command" => command})
    end

    def withdraw
      current_turn = @battle["turn"]
      mutate("withdraw", {"turn" => current_turn})
      # A later resubmission in this same phase is a new operation. Retrying a
      # lost submission still keeps its original ID until withdrawal commits.
      @operations.delete(["commands", current_turn])
      @operations.delete(["withdraw", current_turn])
      @battle
    end

    def waiting_text
      lines = ["等待同步 · 阶段 #{@battle['turn']} / #{KIFMultiplayer.battle_text(@battle['phase'])}"]
      if @battle["deadline"].is_a?(Numeric)
        lines << "本阶段剩余约 #{[(@battle['deadline'] - Time.now.to_f).ceil, 0].max} 秒（以服务器为准）"
      end
      (@battle["reconnect_remaining"] || {}).each do |id, value|
        label = id == @player_id ? "你" : "队友 / 对手"
        lines << "#{label}累计重连余额 #{value} 秒"
      end
      lines << "玩家断线，正在保留已提交动作。" unless (@battle["disconnected"] || []).empty?
      lines << "AI 正在代为控制；重连后下一指令阶段恢复。" unless (@battle["ai_controlled_ids"] || []).empty?
      (@battle["signals"] || {}).each do |id, value|
        signal = value.is_a?(Hash) ? value["signal"] : value
        label = {"support" => "我来辅助", "focus" => "集中攻击", "switch" => "准备换人"}[signal]
        lines << "#{id == @player_id ? '你' : '队友'}：#{label}" if label
      end
      lines << "已锁定阶段不能撤回。" unless @battle["phase"] == "commands"
      lines.join("\n")
    end

    def wait_step
      if KIFMultiplayer.battle_controller
        pause
        fetch
        return
      end
      message_window = command_window = board = nil
      phase_key = [@battle["turn"], @battle["phase"]]
      can_withdraw = @battle["phase"] == "commands" && (@battle["submitted"] || []).include?(@player_id)
      started = Time.now
      begin
        board = BattleBoard.new(state) unless host? || native_presenter?
        message_window = pbCreateMessageWindow
        message_window.text = waiting_text
        command_window = Window_CommandPokemonEx.new(can_withdraw ? ["刷新 / 等待", "锁定前撤回动作"] : ["刷新 / 等待"])
        command_window.z = 99999
        command_window.resizeToFit(command_window.commands)
        pbPositionNearMsgWindow(command_window, message_window, :right)
        @presenter.decorate_windows(message_window, command_window) if native_presenter?
        deadline = Time.now + 0.5
        loop do
          raise BattleError, "Battle synchronization exceeded 180 seconds" if Time.now - started > 180
          @client.pump
          message_window.update
          command_window.update
          if Input.trigger?(Input::USE)
            if can_withdraw && command_window.index == 1
              begin
                withdraw
              rescue KIFMultiplayer::Error => error
                raise unless ["turn_locked", "turn_mismatch"].include?(error.code)
                fetch
              end
              return
            end
            deadline = Time.now
          end
          if Time.now >= deadline
            fetch
            return if terminal? || phase_key != [@battle["turn"], @battle["phase"]] ||
              can_withdraw != (@battle["phase"] == "commands" && (@battle["submitted"] || []).include?(@player_id))
            message_window.text = waiting_text
            deadline = Time.now + 0.5
          end
        end
      ensure
        command_window.dispose if command_window && !command_window.disposed?
        pbDisposeMessageWindow(message_window) if message_window
        board.dispose if board
      end
    end

    def abort(reason)
      # A new/rejected host instance has no right to terminate the live engine
      # already bound to the same account. Guests detach and let server rules
      # apply their remaining reconnect allowance.
      return unless host? && @authority_attempted && !@authority_conflict
      mutate("abort", {"reason" => reason}) unless terminal?
    rescue KIFMultiplayer::Error, BattleInterrupted
      # The failed termination is visible to the caller; do not write a win.
      nil
    end

    def resolve(state, tape, decision, consumed_turn = @battle["turn"])
      digest = KIFMultiplayer.battle_digest(state)
      KIFMultiplayer.battle_event("authority_state", {"turn" => consumed_turn, "state" => state,
                                                    "digest" => digest, "decision" => decision})
      mutate("resolve", {"turn" => consumed_turn, "state" => state, "digest" => digest,
                         "random_tape" => tape, "decision" => decision})
    end

    def acknowledge
      digest = @battle["digest"] || @battle["state_hash"]
      last = (@battle["updates"] || []).last
      digest ||= last["digest"] || last["state_hash"] if last.is_a?(Hash)
      digest ||= KIFMultiplayer.battle_digest(state)
      mutate("ack", {"turn" => @battle["turn"], "digest" => digest})
    end

    def display_state
      KIFMultiplayer.battle_event("received_state", {"turn" => @battle["turn"], "state" => state,
                                                   "decision" => @battle["decision"]})
      return if KIFMultiplayer.battle_controller
      board = BattleBoard.new(state) unless host? || native_presenter?
      events = state["events"] || []
      events.each_slice(5) { |lines| message(lines.map { |line| KIFMultiplayer.battle_text(line) }.join("\n")) }
    ensure
      board.dispose if board
    end

    def message(text)
      return @presenter.message(text) if native_presenter?
      # pbMessage itself has no ensure. A terminal heartbeat can interrupt a
      # guest's battle-log page, so this window also needs an explicit lifetime.
      window = pbCreateMessageWindow
      begin
        pbMessageDisplay(window, text) { heartbeat }
      ensure
        pbDisposeMessageWindow(window)
        Input.update if defined?(Input)
      end
    end

    def result_decision
      result = @battle["result"] || {}
      return 0 if result["abnormal"]
      return 5 unless result["winner_id"]
      result["winner_id"] == @battle["host_id"] ? 1 : 2
    end

    def guest_loop
      if defined?(GuestBattlePresenter)
        return GuestBattlePresenter.with(self) { guest_protocol_loop }
      end
      guest_protocol_loop
    end

    def guest_protocol_loop
      seen_playback = nil
      loop do
        fetch
        @presenter.accept(state) if @presenter && state["battlers"].is_a?(Array) && !state["battlers"].empty?
        if terminal?
          display_state
          return result_decision
        end
        if @battle["phase"] == "playback"
          if seen_playback != @battle["turn"]
            display_state
            seen_playback = @battle["turn"]
          end
          acknowledge
        elsif @battle["phase"] == "commands" && !(@battle["submitted"] || []).include?(@player_id)
          command = BattleInput.choose(self)
          submit(command) if command
        else
          wait_step
        end
      end
    end
  end

  module BattleInput
    def self.summary(state)
      lines = ["Online battle - round #{state['turn_count'].to_i + 1} (#{state['kind']})"]
      (state["battlers"] || []).each do |b|
        lines << "#{KIFMultiplayer.battle_text(b['name'] || b['species'])} HP #{b['hp']}/#{b['totalhp']} #{b['status']}"
      end
      lines << "Weather: #{state['weather']} / Terrain: #{state['terrain']}"
      (state["signals"] || {}).each do |id, value|
        signal = value.is_a?(Hash) ? value["signal"] : value
        label = {"support" => "我来辅助", "focus" => "集中攻击", "switch" => "准备换人"}[signal]
        lines << "#{KIFMultiplayer.battle_text(id)}：#{label}" if label
      end
      lines.join("\n")
    end

    def self.choices(state, player_id)
      options = (state["actions"] || {})[player_id] || {}
      return [["Continue", {"action" => "wait"}]] unless (state["phase_owner_ids"] || []).include?(player_id)
      result = []
      if state["kind"] == "command"
        (options["moves"] || []).each do |move|
          targets = move["targets"] || [move.fetch("target", -1)]
          targets.each do |target|
            label = "#{KIFMultiplayer.battle_text(move['name'])} PP #{move['pp']}/#{move['total_pp']}"
            if target != -1
              battler = (state["battlers"] || []).find { |entry| entry["index"] == target }
              label += " → #{KIFMultiplayer.battle_text(battler ? battler['name'] || battler['species'] : target)}"
            end
            result << [label, {"action" => "move", "move_index" => move["index"], "target" => target}]
          end
        end
        result << ["Continue forced action", {"action" => "forced"}] if options["forced"]
      end
      (options["switches"] || []).each do |pkmn|
        result << ["Switch: #{KIFMultiplayer.battle_text(pkmn['name'] || pkmn['species'])} HP #{pkmn['hp']}/#{pkmn['totalhp']}",
                   {"action" => "switch", "party_index" => pkmn["party_index"]}]
      end
      result << ["Forfeit", {"action" => "surrender"}]
      result
    end

    def self.choose(session)
      state = session.state
      player_id = session.player_id
      options = choices(state, player_id)
      return options[0][1] unless (state["phase_owner_ids"] || []).include?(player_id)
      if KIFMultiplayer.battle_controller
        return KIFMultiplayer.battle_controller.call(state, player_id)
      end
      if session.respond_to?(:send_signal)
        [["我来辅助", "support"], ["集中攻击", "focus"], ["准备换人", "switch"]].each do |label, signal|
          options << [label, {"action" => "signal", "signal" => signal}]
        end
      end
      # Use the existing RGSS command window but keep network timers and the
      # battle scene updating while the player is thinking. Time is wall-clock.
      msgwindow = pbCreateMessageWindow
      command_window = nil
      board = nil
      begin
        board = BattleBoard.new(state) unless session.host? || session.native_presenter?
        msgwindow.text = summary(state)
        command_window = Window_CommandPokemonEx.new(options.map { |entry| entry[0] })
        command_window.z = 99999
        command_window.resizeToFit(command_window.commands)
        pbPositionNearMsgWindow(command_window, msgwindow, :right)
        session.presenter.decorate_windows(msgwindow, command_window) if session.native_presenter?
        next_poll = Time.now + 0.5
        turn = session.battle["turn"]
        shown = false
        loop do
          Graphics.update
          Input.update
          command_window.update
          msgwindow.update
          update = session.client.wait_update
          update.call if update
          unless shown
            KIFMultiplayer.battle_event("command_menu_ready", {"turn" => turn, "player_id" => player_id,
              "native_scene" => session.native_presenter? == true})
            shown = true
          end
          if Time.now >= next_poll
            session.fetch
            return nil if session.terminal? || session.battle["turn"] != turn ||
              session.battle["phase"] != "commands" || (session.battle["submitted"] || []).include?(player_id)
            if state["signals"] != session.state["signals"]
              state = session.state
              msgwindow.text = summary(state)
            end
            next_poll = Time.now + 0.5
          end
          next unless Input.trigger?(Input::USE)
          selected = options[command_window.index][1]
          if selected["action"] == "signal"
            session.send_signal(selected["signal"])
            msgwindow.text = summary(session.state)
            next
          end
          if selected["action"] == "surrender"
            next unless KIFMultiplayer.battle_confirm("Forfeit this online battle?", session)
          end
          return selected
        end
      ensure
        command_window.dispose if command_window && !command_window.disposed?
        pbDisposeMessageWindow(msgwindow) if msgwindow
        board.dispose if board
        Input.update
      end
    end
  end

  # A lightweight observer board renders official public species and HP. It
  # does not reconstruct hidden parties or run a second combat simulation.
  class BattleBoard
    def initialize(state)
      @sprites = []
      battlers = state["battlers"] || []
      raise BattleError, "Invalid public board battlers" unless battlers.is_a?(Array) && battlers.length <= 4
      public_pokemon = {}
      if state["visuals"]
        raise BattleError, "Public visual validator is unavailable" unless defined?(BattleVisuals)
        BattleVisuals.validate(state["visuals"], state)["battlers"].each do |entry|
          public_pokemon[entry["slot"]] = entry
        end
      end
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 95000
      background = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      @sprites << background
      background.bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(24, 32, 56))
      pbSetSystemFont(background.bitmap)
      background.bitmap.font.size = 20
      # Keep every sprite inside its own column and above the separate labels.
      # Native bitmaps can be much larger than the 128/170px four/three slots.
      sprite_top = 28
      baseline = [Graphics.height * 0.48, Graphics.height - 128].min.to_i
      battlers.each_with_index do |entry, position|
        Snapshot.registry(:Species, entry["species"])
        visible = public_pokemon[entry["index"]]
        # A timeline may describe an earlier replacement. Only the matching
        # final active species can lend its already-validated appearance.
        visible = nil if visible && visible["species"] != entry["species"]
        pokemon = Pokemon.new(entry["species"], visible ? visible["level"] : 50, nil, false, false)
        if visible
          pokemon.form = visible["form"]
          pokemon.gender, pokemon.shiny = visible["gender"], visible["shiny"]
          visible["appearance"].each do |key, value|
            value = value.to_sym if key == "size_category" && value
            value = value.dup if value.is_a?(Array) || value.is_a?(String)
            pokemon.instance_variable_set("@#{key}", value)
          end
        end
        sprite = PokemonSprite.new(@viewport)
        @sprites << sprite
        sprite.setPokemonBitmap(pokemon)
        left = position * Graphics.width / battlers.length
        right = (position + 1) * Graphics.width / battlers.length
        width = right - left - 16
        sprite.x, sprite.y = (left + right) / 2, baseline
        if sprite.bitmap && sprite.bitmap.width > 0 && sprite.bitmap.height > 0
          scale = [1.0, width.to_f / sprite.bitmap.width,
                   (baseline - sprite_top).to_f / sprite.bitmap.height].min
          sprite.zoom_x = sprite.zoom_y = scale
          sprite.ox, sprite.oy = sprite.bitmap.width / 2, sprite.bitmap.height
        end
        name = KIFMultiplayer.battle_text(entry["name"] || entry["species"])
        name = "★ #{name}" if visible && visible["shiny"]
        draw_label(background.bitmap, left + 8, baseline + 8, width, name, true)
        draw_label(background.bitmap, left + 8, baseline + 32, width, "#{entry['hp']}/#{entry['totalhp']} HP")
        status = entry["status"].to_s == "NONE" ? "Healthy" : KIFMultiplayer.battle_text(entry["status"])
        draw_label(background.bitmap, left + 8, baseline + 56, width, status)
      end
    rescue StandardError => error
      dispose
      KIFMultiplayer.log_error(error) if KIFMultiplayer.respond_to?(:log_error)
    end

    def draw_label(bitmap, left, top, width, text, shorten = false)
      original_size = bitmap.font.size
      if shorten
        if bitmap.text_size(text).width > width
          text = text[0...-1] while !text.empty? && bitmap.text_size(text + "...").width > width
          text += "..."
        end
      else
        bitmap.font.size -= 1 while bitmap.font.size > 12 && bitmap.text_size(text).width > width
      end
      bitmap.draw_text(left, top, width, 24, text, 1)
    ensure
      bitmap.font.size = original_size if original_size
    end

    def dispose
      (@sprites || []).each { |sprite| BattlePresentation.dispose(sprite) }
      BattlePresentation.dispose(@viewport)
    end
  end

  def self.run_battle(client, room, battle)
    old_update = client.wait_update
    session = BattleSession.new(client, battle)
    if session.terminal?
      present_battle_result(session)
      return session.result_decision
    end
    unless session.host?
      decision = session.guest_loop
      present_battle_result(session)
      return decision
    end
    unless battle["turn"].to_i == 0 && battle["phase"] == "initializing"
      raise BattleError, "Host engine cannot be reconstructed after process restart; end this battle as abnormal."
    end
    session.claim_authority
    if session.terminal?
      present_battle_result(session)
      return session.result_decision
    end
    decision = BattleIsolation.with do
      players = battle["players"]
      raise BattleError, "Only two-player singles are supported" unless players.is_a?(Array) && players.length == 2
      raise BattleError, "Authority must occupy the first battle side" unless players[0] == battle["host_id"]
      teams = battle["initial_teams"]
      raise BattleError, "Host did not receive frozen teams" unless teams.is_a?(Hash)
      parties = players.map do |id|
        team = teams[id]
        raise BattleError, "Each frozen team must contain exactly three Pokemon" unless team.is_a?(Array) && team.length == 3
        team.map do |snapshot|
          pkmn = Snapshot.import(snapshot, 50)
          pkmn.name = battle_text(pkmn.name)
          pkmn
        end
      end
      $Trainer.party = parties[0]
      opponent = NPCTrainer.new("Online guest", $Trainer.trainer_type)
      opponent.party = parties[1]
      scene = pbNewBattleScene
      engine = KIFMultiplayerBattle.new(scene, parties[0], parties[1], $Trainer, opponent, session)
      original_update = scene.method(:pbUpdate)
      scene.define_singleton_method(:pbUpdate) do |*args|
        original_update.call(*args)
        session.heartbeat
      end
      client.wait_update = battle_wait_update(scene, session)
      KIFMultiplayer.battle_event("engine_started", {"battle_id" => session.battle_id, "players" => players})
      BattlePresentation.with(scene) do
        pbBGMPlay(pbGetTrainerBattleBGM(opponent))
        engine.pbStartBattle
      end
    end
    # The engine scene is already disposed and original globals restored. A
    # result observer/network request must not pump its pbUpdate again: this
    # fork's UnrealTime hook would otherwise advance the main world's clock.
    client.wait_update = old_update
    present_battle_result(session)
    session.terminal? ? session.result_decision : decision
  rescue ServerTerminal
    client.wait_update = old_update if defined?(old_update)
    present_battle_result(session)
    session.result_decision
  rescue StandardError, BattleInterrupted => error
    client.wait_update = old_update if defined?(old_update)
    session.abort(session.host? ? "authority_unrecoverable" : "client_error") if session
    raise(error.is_a?(BattleInterrupted) ? error.original : error)
  ensure
    client.wait_update = old_update if defined?(old_update)
  end

  def self.present_battle_result(session)
    result = session.battle["result"] || {}
    battle_event("settlement", result.merge("battle_id" => session.battle_id))
    return if battle_controller
    outcome = if result["abnormal"]
                "Online battle ended abnormally."
              elsif result["winner_id"].nil?
                "Online battle ended in a draw."
              elsif result["winner_id"] == session.player_id
                "You won the online battle."
              else
                "You lost the online battle."
              end
    pbMessage("#{outcome}\nReason: #{result['reason']}\nNo main-save rewards were issued.")
  end
end

# No base-game class is monkey-patched. Single-player battles use their existing
# classes and continue to work when the multiplayer service is unavailable.
class KIFMultiplayerBattle < PokeBattle_Battle
  class OnlineForfeit < Exception; end

  def initialize(scene, p1, p2, player, opponent, session)
    super(scene, p1, p2, player, opponent)
    @online = session
    @online_events = []
    @online_random = []
    @online_pending = false
    @online_consumed_turn = session.battle["turn"]
    @internalBattle = false
    @expGain = false
    @moneyGain = false
    @canRun = false
    @canLose = true
    @switchStyle = false
    @backdrop = "indoora"
    @backdropBase = "indoora"
    @showAnims = ($PokemonSystem.battlescene == 0)
    setBattleMode("single")
  end

  def pbGainExp; end
  def pbGainMoney; end
  def pbLoseMoney; end
  def pbSetSeen(_battler); end
  def pbRecordAndStoreCaughtPokemon; end
  def pbCanMegaEvolve?(_idxBattler); false; end

  def pbStartBattle
    result = super
    @online.abort("engine_aborted") if result == 0 && !@online.terminal?
    result
  rescue OnlineForfeit
    pbEndOfBattle
  end

  # The ordinary battle loop wraps each phase in PBDebug.logonerr, which
  # catches StandardError and continues the next phase. A rejected network
  # command or lost synchronization must unwind and abort this session instead.
  def pbBattleLoop
    @turnCount = 0
    loop do
      pbCommandPhase
      break if @decision > 0
      pbAttackPhase
      break if @decision > 0
      pbEndOfRoundPhase
      break if @decision > 0
      @turnCount += 1
    end
    $PokemonSystem.is_in_battle = false
    pbEndOfBattle
  end

  def pbRandom(limit)
    value = super(limit)
    # Diagnostic only: direct rand, sample, aliases and Mods are not a complete
    # replay tape. The guest never computes outcomes using this data.
    @online_random << {"limit" => limit, "value" => value} if limit.is_a?(Integer) && limit > 0 && value.is_a?(Integer)
    value
  end

  def online_log(text)
    @online_events << text.to_s.gsub(/[\x00-\x1f]/, " ")[0, 1000]
    @online_events.shift if @online_events.length > 200
  end

  def pbDisplay(text)
    online_log(text)
    super
  end

  def pbDisplayBrief(text)
    online_log(text)
    super
  end

  def pbDisplayPaused(text)
    pbDisplay(text)
  end

  def online_actions(index, kind, required, lax)
    switches = []
    pbParty(index).each_with_index do |pkmn, i|
      legal = lax ? pbCanSwitchLax?(index, i) : pbCanSwitch?(index, i)
      next unless legal
      switches << {"party_index" => i, "species" => pkmn.species.to_s,
                   "hp" => pkmn.hp, "totalhp" => pkmn.totalhp, "name" => pkmn.name}
    end
    moves = []
    if kind == "command" && required && pbCanShowCommands?(index)
      @battlers[index].eachMoveWithIndex do |move, i|
        next unless pbCanChooseMove?(index, i, false)
        moves << {"index" => i, "id" => move.id.to_s, "name" => move.name,
                  "pp" => move.pp, "total_pp" => move.total_pp,
                  "targets" => online_move_targets(index, move)}
      end
    end
    {"moves" => moves, "switches" => required ? switches : [],
     "can_switch" => required && !switches.empty?, "forced" => kind == "command" && moves.empty?}
  end

  # Only explicitly chosen, live, legal battlers are accepted for a single
  # target in cooperative combat. Random, spread and self/field moves retain
  # the engine's automatic target. Singles use the existing automatic target.
  def online_move_targets(index, move)
    data = move.pbTarget(@battlers[index])
    return [-1] if singleBattle? || data.num_targets != 1 || data.id == :RandomNearFoe
    targets = @battlers.compact.select do |b|
      !b.fainted? && pbMoveCanTarget?(index, b.index, data)
    end.map { |b| b.index }
    # Existing combat can spend a move and fail when every suitable target is
    # absent (e.g. Helping Hand after the partner was eliminated). Auto-target
    # preserves that legal failure rather than leaving only a Forfeit button.
    targets.empty? ? [-1] : targets
  end

  def online_legal_targets(index, move_index)
    return [] unless move_index.is_a?(Integer) && move_index.between?(0, 3) && @battlers[index]
    move = @battlers[index].moves[move_index]
    move ? online_move_targets(index, move) : []
  end

  def online_state(kind, required_indices, lax = false)
    ids = @online.battle["players"]
    actions = {}
    ids.each_with_index { |id, i| actions[id] = online_actions(i, kind, required_indices.include?(i), lax) }
    battlers = @battlers.compact.map do |b|
      {"owner_id" => ids[b.index % 2], "index" => b.index, "party_index" => b.pokemonIndex,
       "species" => b.displaySpecies.to_s, "name" => b.name, "hp" => b.hp,
       "totalhp" => b.totalhp, "status" => b.status.to_s, "level" => b.level}
    end
    {"kind" => kind, "turn_count" => @turnCount, "battlers" => battlers,
     "weather" => @field.weather.to_s, "terrain" => @field.terrain.to_s,
     "events" => @online_events.dup, "actions" => actions,
     "phase_owner_ids" => required_indices.map { |i| ids[i] }}
  end

  # Resolve exactly once at the next input boundary. The boundary can be a
  # replacement in the middle of an attack, hence server turn != engine round.
  def online_boundary(kind, required_indices, lax = false)
    state = online_state(kind, required_indices, lax)
    @online.resolve(state, @online_random, @decision, @online_consumed_turn)
    @online_events.clear
    @online_random.clear
    @online_pending = false
    raise KIFMultiplayer::ServerTerminal if @online.terminal?
    @online.wait_for { |b| ["commands", "locked"].include?(b["phase"]) }
    boundary_started = Time.now
    until @online.battle["phase"] == "locked"
      raise KIFMultiplayer::BattleError, "Cooperative synchronization exceeded 180 seconds" if Time.now - boundary_started > 180
      raise KIFMultiplayer::ServerTerminal if @online.terminal?
      if @online.battle["phase"] == "commands" && !(@online.battle["submitted"] || []).include?(@online.player_id)
        command = KIFMultiplayer::BattleInput.choose(@online)
        @online.submit(command) if command
      else
        @online.wait_step
      end
    end
    @online_pending = true
    @online_consumed_turn = @online.battle["turn"]
    commands = @online.battle["commands"]
    raise KIFMultiplayer::BattleError, "Locked commands were not supplied to authority" unless commands.is_a?(Hash)
    commands
  rescue KIFMultiplayer::BattleTerminated
    @decision = @online.result_decision
    @online_pending = false
    raise OnlineForfeit
  rescue StandardError => error
    raise KIFMultiplayer::BattleInterrupted.new(error)
  end

  def online_forfeit(commands)
    ids = @online.battle["players"]
    surrender = ids.select { |id| commands[id] && commands[id]["action"] == "surrender" }
    return false if surrender.empty?
    @decision = surrender.length == 2 ? 5 : (surrender[0] == ids[0] ? 2 : 1)
    online_log("Online battle ended by forfeit.")
    true
  end

  def pbCommandPhase
    @scene.pbBeginCommandPhase
    @battlers.each_with_index { |b, i| pbClearChoice(i) if b && pbCanShowCommands?(i) }
    required = [0, 1].select { |i| pbCanShowCommands?(i) }
    commands = online_boundary("command", required)
    return if online_forfeit(commands)
    @online.battle["players"].each_with_index do |id, index|
      command = commands[id]
      raise KIFMultiplayer::BattleError, "Missing locked command" unless command.is_a?(Hash)
      next unless required.include?(index)
      case command["action"]
      when "move"
        move = command["move_index"]
        target = command.fetch("target", -1)
        unless move.is_a?(Integer) && (0..3).include?(move) &&
               pbCanChooseMove?(index, move, false) &&
               online_legal_targets(index, move).include?(target) &&
               pbRegisterMove(index, move, false)
          raise KIFMultiplayer::BattleError, "Authority rejected an illegal move"
        end
        pbRegisterTarget(index, target)
      when "switch"
        party = command["party_index"]
        unless party.is_a?(Integer) && party >= 0 && pbRegisterSwitch(index, party)
          raise KIFMultiplayer::BattleError, "Authority rejected an illegal switch"
        end
      when "forced"
        raise KIFMultiplayer::BattleError, "Forced action requested while a move was available" if pbCanShowFightMenu?(index)
        pbAutoChooseMove(index, false)
      else
        raise KIFMultiplayer::BattleError, "Unsupported locked battle command"
      end
    end
  end

  def pbSwitchInBetween(index, checkLaxOnly = false, _canCancel = false)
    commands = online_boundary("switch", [index], checkLaxOnly)
    if online_forfeit(commands)
      # Never return an invalid party index to the existing engine. End the
      # battle before the interrupted effect can perform another action.
      raise OnlineForfeit
    end
    command = commands[@online.battle["players"][index % 2]]
    party = command && command["party_index"]
    legal = party.is_a?(Integer) && party >= 0 &&
      (checkLaxOnly ? pbCanSwitchLax?(index, party) : pbCanSwitch?(index, party))
    raise KIFMultiplayer::BattleError, "Authority rejected an illegal replacement" unless command.is_a?(Hash) && command["action"] == "switch" && legal
    party
  rescue StandardError => error
    raise KIFMultiplayer::BattleInterrupted.new(error)
  end

  # The base ending autosaves on a win and updates rematch/global fields even
  # for external battles. This narrowly scoped ending deliberately skips it.
  def pbEndOfBattle
    if @online_pending && !@online.terminal?
      @online.resolve(online_state("command", []), @online_random, @decision, @online_consumed_turn)
      @online_pending = false
    end
    # A finish attempt can race a server timeout/disconnect settlement. Local
    # HP and decision never override the already committed official result.
    @decision = @online.result_decision if @online.terminal?
    @scene.pbEndBattle(@decision)
    KIFMultiplayer.battle_event("engine_finished", {"decision" => @decision, "rounds" => @turnCount + 1})
    @decision
  end
end
