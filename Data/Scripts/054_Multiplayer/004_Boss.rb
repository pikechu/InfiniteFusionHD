# Cooperative battles reuse the production 2v1 engine. Only the authority
# executes combat; the second player selects their own slot's legal actions.
module KIFMultiplayer
  class BossSession < BattleSession
    def state
      super.merge("signals" => @battle["signals"] || {})
    end
    def result_decision
      result = @battle["result"] || {}
      return 0 if result["abnormal"] || result["coop_outcome"] == "abnormal"
      return 1 if result["coop_outcome"] == "victory" || result["outcome"] == "win" ||
        (result["winner_ids"] || result["winning_player_ids"] || []).include?(@player_id)
      return 2 if terminal?
      0
    end

    def send_signal(value)
      raise BattleError, "Unsupported cooperative signal" unless %w[support focus switch].include?(value)
      adopt(@client.request("POST", "#{@path}/signal", authority_payload({"signal" => value})))
      KIFMultiplayer.battle_event("signal", {"player_id" => @player_id, "signal" => value})
    rescue Error => error
      # Preset communication is optional. A dropped response must not abort a
      # healthy combat; its operation is recovered by the normal client journal
      # before the next mutation, and polling reveals any committed signal.
      KIFMultiplayer.log_error(error) if KIFMultiplayer.respond_to?(:log_error)
      KIFMultiplayer.battle_event("signal_pending", {"player_id" => @player_id, "signal" => value, "code" => error.code})
      nil
    end

    def claim_medal
      # Route encounters grant only temporary progress. Their single account
      # medal is claimed through the completed dungeon, never per battle node.
      return nil if @battle["dungeon_id"]
      return nil unless terminal? && result_decision == 1
      response = @client.request("POST", "#{@path}/claim", {})
      reward = response["reward"]
      raise BattleError, "Malformed cooperative reward" unless reward.is_a?(Hash) &&
        reward["owner_id"] == @player_id && reward["battle_id"] == @battle_id && reward["kind"] == "boss_medal"
      KIFMultiplayer.battle_event("boss_reward", reward)
      reward
    end
  end

  # This local-only subclass keeps the configured HP multiplier through engine
  # refreshes (pbUpdate calls Pokemon#calc_stats). Recalculating must neither
  # stack the multiplier nor heal damage or resurrect a defeated Boss.
  class BossPokemon < Pokemon
    def enable_boss_hp(multiplier)
      @boss_hp_multiplier = multiplier
      @totalhp *= multiplier
      @hp *= multiplier
    end

    def calc_stats(*args)
      return super(*args) unless @boss_hp_multiplier
      damage = @totalhp - @hp
      fainted = @hp <= 0
      super(*args)
      @totalhp *= @boss_hp_multiplier
      @hp = fainted ? 0 : [[@totalhp - damage, 0].max, @totalhp].min
    end
  end

  def self.build_boss(config)
    raise BattleError, "Unsupported Boss version" unless config.is_a?(Hash) && config["version"] == 1
    Snapshot.registry(:Species, config["species"])
    Snapshot.registry(:Ability, config["ability"])
    level, multiplier = config["level"], config["hp_multiplier"]
    raise BattleError, "Invalid Boss level or HP multiplier" unless Snapshot.number(level, 1, 100) && Snapshot.number(multiplier, 1, 10)
    moves = config["moves"]
    raise BattleError, "Invalid Boss moves" unless moves.is_a?(Array) && moves.length.between?(1, 4)
    moves.each { |move| Snapshot.registry(:Move, move) }
    stages = config["stat_stages"] || {}
    raise BattleError, "Invalid Boss stat boosts" unless stages.is_a?(Hash) &&
      (stages.keys - %w[ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED ACCURACY EVASION]).empty? &&
      stages.values.all? { |value| Snapshot.number(value, -6, 6) }
    pokemon = BossPokemon.new(config["species"], level, nil, false, false)
    pokemon.name = battle_text(config["name"] || "Cooperative Boss")[0, 32]
    pokemon.ability = config["ability"]
    pokemon.nature = :HARDY
    Snapshot::STATS.each do |stat|
      pokemon.iv[stat.to_sym] = 31
      pokemon.ev[stat.to_sym] = 0
    end
    pokemon.moves.clear
    moves.each { |move| pokemon.learn_move(move) }
    pokemon.calc_stats
    pokemon.heal
    pokemon.enable_boss_hp(multiplier)
    pokemon
  end

  def self.present_boss_result(session)
    result = session.battle["result"] || {}
    battle_event("settlement", result.merge("battle_id" => session.battle_id))
    reward, reward_error = nil, nil
    begin
      reward = session.claim_medal
    rescue Error, BattleError => error
      # A reward request may have committed. The Client keeps its operation
      # journal; reopening this result queries it before any retry.
      reward_error = error
      log_error(error) if respond_to?(:log_error)
    end
    return if battle_controller
    outcome = case session.result_decision
              when 1 then "合作胜利！双方击败了 Boss。"
              when 2 then "合作失败，双方队伍已无法继续。"
              else "合作战斗异常结束。"
              end
    outcome += "\n账号纪念章已领取（每人每场一次）。" if reward
    outcome += "\n纪念章领取待恢复；返回此结果可查询重试。" if reward_error
    pbMessage("#{outcome}\n原因：#{battle_text(result['reason'])}\n原精灵、背包和主线未改变。")
  end

  # A fixed-route dungeon may carry only these explicit, temporary runtime
  # fields across encounters. Base species/moves/stats still come from the
  # frozen validated snapshot, and incompatible capacities fail closed.
  def self.apply_boss_runtime(parties, players, runtime)
    return unless runtime
    raise BattleError, "Invalid cooperative runtime owners" unless runtime.is_a?(Hash) && runtime.keys.all? { |key| key.is_a?(String) } && runtime.keys.sort == players.sort
    players.each_with_index do |id, owner_index|
      values = runtime[id]
      raise BattleError, "Each runtime party must contain three Pokemon" unless values.is_a?(Array) && values.length == 3
      values.each_with_index do |value, party_index|
        pokemon = parties[owner_index][party_index]
        fields = %w[hp totalhp status status_count pp total_pp item]
        raise BattleError, "Invalid cooperative runtime fields" unless value.is_a?(Hash) && value.keys.sort == fields.sort
        raise BattleError, "Runtime HP capacity differs from frozen team" unless Snapshot.number(value["totalhp"], 1, 100000) && value["totalhp"] == pokemon.totalhp && Snapshot.number(value["hp"], 0, pokemon.totalhp)
        raise BattleError, "Runtime PP capacity differs from frozen moves" unless value["total_pp"].is_a?(Array) && value["total_pp"].all? { |amount| Snapshot.number(amount, 0, 999) } && value["total_pp"] == pokemon.moves.map { |move| move.total_pp }
        raise BattleError, "Invalid runtime PP" unless value["pp"].is_a?(Array) && value["pp"].length == pokemon.moves.length && value["pp"].each_with_index.all? { |amount, index| Snapshot.number(amount, 0, value["total_pp"][index]) }
        Snapshot.registry(:Status, value["status"])
        Snapshot.registry(:Item, value["item"], true)
        raise BattleError, "Invalid runtime status counter" unless Snapshot.number(value["status_count"], 0, 255)
        pokemon.hp = value["hp"]
        pokemon.status = value["status"]
        pokemon.statusCount = value["status_count"]
        pokemon.moves.each_with_index { |move, index| move.pp = value["pp"][index] }
        pokemon.item = value["item"]
      end
    end
  end

  def self.boss_team_states(parties, players)
    players.each_with_index.each_with_object({}) do |(id, owner_index), result|
      result[id] = parties[owner_index].map do |pokemon|
        {"hp" => pokemon.hp, "totalhp" => pokemon.totalhp, "status" => pokemon.status.to_s,
         "status_count" => pokemon.statusCount, "pp" => pokemon.moves.map { |move| move.pp },
         "total_pp" => pokemon.moves.map { |move| move.total_pp }, "item" => pokemon.item_id && pokemon.item_id.to_s}
      end
    end
  end

  # Kept for existing local observers and previously saved diagnostic scripts.
  def self.boss_team_state(parties, players)
    boss_team_states(parties, players)
  end

  def self.run_boss(client, _room, battle)
    old_update = client.wait_update
    raise BattleError, "This is not a cooperative Boss battle" unless battle["mode"] == "coop_boss"
    session = BossSession.new(client, battle)
    if session.terminal?
      present_boss_result(session)
      return session.result_decision
    end
    unless session.host?
      session.guest_loop
      present_boss_result(session)
      return session.result_decision
    end
    unless battle["turn"].to_i == 0 && battle["phase"] == "initializing"
      raise BattleError, "Authority engine cannot be restored after process restart. This battle must end abnormally."
    end
    session.claim_authority
    if session.terminal?
      present_boss_result(session)
      return session.result_decision
    end
    decision = BattleIsolation.with do
      players = battle["players"]
      raise BattleError, "Cooperative Boss requires two players with authority first" unless
        players.is_a?(Array) && players.length == 2 && players.uniq.length == 2 && players[0] == battle["host_id"]
      teams = battle["initial_teams"]
      raise BattleError, "Missing frozen cooperative teams" unless teams.is_a?(Hash)
      parties = players.map do |id|
        team = teams[id]
        raise BattleError, "Each player must bring three temporary Pokemon" unless team.is_a?(Array) && team.length == 3
        team.map do |snapshot|
          pokemon = Snapshot.import(snapshot, 50)
          pokemon.name = battle_text(pokemon.name)
          pokemon
        end
      end
      apply_boss_runtime(parties, players, battle["runtime_state"])
      $Trainer.party = parties[0]
      partner = NPCTrainer.new("Online partner", $Trainer.trainer_type)
      partner.party = parties[1]
      boss = build_boss(battle["boss"])
      opponent = NPCTrainer.new("Cooperative Boss", $Trainer.trainer_type)
      opponent.party = [boss]
      scene = pbNewBattleScene
      engine = KIFMultiplayerBossBattle.new(scene, parties[0] + parties[1], [boss], [$Trainer, partner], opponent, session)
      original_update = scene.method(:pbUpdate)
      scene.define_singleton_method(:pbUpdate) do |*args|
        original_update.call(*args)
        session.heartbeat
      end
      client.wait_update = battle_wait_update(scene, session)
      battle_event("engine_started", {"battle_id" => session.battle_id, "players" => players, "mode" => "coop_boss", "boss" => battle["boss"]})
      BattlePresentation.with(scene) do
        pbBGMPlay(pbGetTrainerBattleBGM(opponent))
        engine.pbStartBattle
      end
      if session.terminal? && !(session.battle["result"] || {})["abnormal"]
        battle_event("boss_team_state", {"battle_id" => session.battle_id, "team_states" => boss_team_state(parties, players)})
      end
    end
    # Claim requests pump frames after original globals have been restored.
    # Release the disposed scene first so its UnrealTime hook cannot advance
    # the player's main-save clock during medal retrieval.
    client.wait_update = old_update
    present_boss_result(session)
    session.terminal? ? session.result_decision : decision
  rescue ServerTerminal
    client.wait_update = old_update if defined?(old_update)
    present_boss_result(session)
    session.result_decision
  rescue StandardError, BattleInterrupted => error
    client.wait_update = old_update if defined?(old_update)
    if session && session.host?
      session.abort("authority_unrecoverable")
    elsif session
      # A non-authority process has no engine to invalidate. Its transport or
      # local UI failure detaches this client while the server's existing AI
      # takeover/reconnect budget continues; it must not terminate the host.
      original = error.is_a?(BattleInterrupted) ? error.original : error
      record_boss_detachment(client, _room, session, original)
    end
    raise(error.is_a?(BattleInterrupted) ? error.original : error)
  ensure
    client.wait_update = old_update if defined?(old_update)
  end

  def self.record_boss_detachment(client, room, session, error)
    code = error.respond_to?(:code) ? error.code : error.class.to_s
    detached = {"battle_id" => session.battle_id, "player_id" => session.player_id,
                "reason" => code, "recoverable" => true, "at" => Time.now.to_i}
    room_code = room.is_a?(Hash) && room["code"] || session.battle["room_code"]
    detached["room_code"] = room_code if room_code.is_a?(String) && room_code =~ /\A[A-Z0-9]{4,12}\z/
    if client.respond_to?(:profile)
      client.profile.account["boss_detached"] = detached
      client.profile.save
    end
    battle_event("guest_detached", detached)
    log_error(error) if respond_to?(:log_error)
  rescue StandardError
    # Diagnostic persistence cannot replace the original connection failure or
    # be used as a reason to abort the surviving authority's session.
    nil
  end

  def self.open_boss_menu(client)
    ui = UI.new(client)
    loop do
      choice = ui.choose("双人合作 Boss\n每人三只临时精灵、各控制一只；奖励为账号纪念章。", ["创建 Boss 房间", "加入好友房间", "恢复当前房间", "返回"])
      return if choice < 0 || choice == 3
      ui.perform do
        ui.connect
        case choice
        when 0
          difficulty = ui.choose("岩钢试炼（GOLEM / ONIX 融合）\n普通：50 级 / 3 倍 HP；困难：60 级 / 4 倍 HP。", ["普通", "困难", "取消"])
          next unless [0, 1].include?(difficulty)
          room = client.request("POST", "/v1/rooms", {"name" => "双人岩钢试炼", "mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => difficulty == 0 ? "normal" : "hard", "compatibility" => client.compatibility})["room"]
        when 1
          code = ui.enter("输入好友房间码", "", 12).upcase
          next if code.empty?
          room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => client.compatibility})["room"]
          raise Error, "该房间不是合作 Boss。" unless room["mode"] == "coop_boss"
        when 2
          raise Error, "没有当前房间。" unless client.room_code
          room = client.request("GET", "/v1/rooms/#{client.room_code}")["room"]
          raise Error, "当前房间不是合作 Boss。" unless room["mode"] == "coop_boss"
        end
        client.room_code = room["code"]
        ui.room_menu(room)
      end
    end
  end
end

class KIFMultiplayerBossBattle < KIFMultiplayerBattle
  def initialize(*args)
    super(*args)
    @party1starts = [0, 3]
    setBattleMode("2v1")
  end

  def pbEnsureParticipants
    # The generic initializer requires an able Pokemon from every trainer and
    # packs their slots together. Dungeon continuation instead keeps ownership
    # at 0/2 even when one trainer's entire carried party has fainted.
    unless @party1.length == 6 && @party2.length == 1 && @player.length == 2 && @opponent.length == 1
      raise KIFMultiplayer::BattleError, "Cooperative Boss requires two separate three-Pokemon teams and one Boss"
    end
    unless @party1.any? { |pokemon| pokemon && pokemon.able? } && @party2[0] && @party2[0].able?
      raise KIFMultiplayer::BattleError, "No able cooperative participants remain"
    end
    @sideSizes = [2, 1]
  end

  def pbSetUpSides
    sent = [[[], []], [[]]]
    2.times do |owner|
      start = owner * 3
      index = (start...(start + 3)).find { |party_index| @party1[party_index].able? }
      # Keep a fainted placeholder battler for engine bookkeeping; it is never
      # sent out, commanded, targeted, revived or transferred to the partner.
      pokemon_index = index || start
      pbCreateBattler(owner * 2, @party1[pokemon_index], pokemon_index)
      if index
        sent[0][owner] << owner * 2
      else
        online_log("#{@player[owner].name} has no Pokemon remaining and is watching.")
      end
    end
    pbCreateBattler(1, @party2[0], 0)
    sent[1][0] << 1
    (@online.battle["boss"]["stat_stages"] || {}).each do |stat, stage|
      @battlers[1].stages[stat.to_sym] = stage
    end
    sent
  end

  def online_owner(index)
    return "boss" if index.odd?
    @online.battle["players"][index / 2]
  end

  def online_offset(index)
    index == 2 ? 3 : 0
  end

  def online_actions(index, kind, required, lax)
    actions = super
    actions["switches"].each { |entry| entry["party_index"] -= online_offset(index) }
    actions
  end

  def online_state(kind, required_indices, lax = false)
    ids = @online.battle["players"]
    actions = {}
    [0, 2].each { |index| actions[online_owner(index)] = online_actions(index, kind, required_indices.include?(index), lax) }
    battlers = @battlers.compact.map do |b|
      {"owner_id" => online_owner(b.index), "index" => b.index, "party_index" => b.pokemonIndex - online_offset(b.index),
       "species" => b.displaySpecies.to_s, "name" => b.name, "hp" => b.hp, "totalhp" => b.totalhp,
       "status" => b.status.to_s, "level" => b.level}
    end
    {"kind" => kind, "turn_count" => @turnCount, "battlers" => battlers, "weather" => @field.weather.to_s,
     "terrain" => @field.terrain.to_s, "events" => @online_events.dup, "actions" => actions,
     "phase_owner_ids" => required_indices.select { |index| index.even? }.map { |index| online_owner(index) },
     # Included in the same authoritative resolve as the result. A client crash
     # before dungeon/advance cannot discard reserve HP, PP, status or items.
     "team_states" => KIFMultiplayer.boss_team_states([@party1[0, 3], @party1[3, 3]], ids)}
  end

  # A voluntary surrender ends the entire cooperative attempt as a loss. A
  # disconnected partner is represented by server-only action:ai instead.
  def online_forfeit(commands)
    surrender = @online.battle["players"].any? { |id| commands[id].is_a?(Hash) && commands[id]["action"] == "surrender" }
    return false unless surrender
    @decision = 2
    online_log("Cooperative challenge ended by surrender.")
    true
  end

  def pbCommandPhase
    @scene.pbBeginCommandPhase
    @battlers.each_with_index { |b, index| pbClearChoice(index) if b && pbCanShowCommands?(index) }
    required = [0, 2].select { |index| pbCanShowCommands?(index) }
    commands = online_boundary("command", required)
    return if online_forfeit(commands)
    required.each do |index|
      command = commands[online_owner(index)]
      raise KIFMultiplayer::BattleError, "Missing locked cooperative command" unless command.is_a?(Hash)
      case command["action"]
      when "ai"
        @battleAI.pbDefaultChooseEnemyCommand(index)
      when "move"
        move, target = command["move_index"], command["target"]
        unless move.is_a?(Integer) && move.between?(0, 3) && pbCanChooseMove?(index, move, false) &&
          online_legal_targets(index, move).include?(target) && pbRegisterMove(index, move, false)
          raise KIFMultiplayer::BattleError, "Authority rejected an illegal cooperative move or target"
        end
        pbRegisterTarget(index, target)
      when "switch"
        party = command["party_index"]
        unless party.is_a?(Integer) && party.between?(0, 2) && pbRegisterSwitch(index, party + online_offset(index))
          raise KIFMultiplayer::BattleError, "Authority rejected a cooperative switch across owners"
        end
      when "forced"
        raise KIFMultiplayer::BattleError, "Forced action while a move is available" if pbCanShowFightMenu?(index)
        pbAutoChooseMove(index, false)
      else
        raise KIFMultiplayer::BattleError, "Unsupported cooperative command"
      end
    end
    @battleAI.pbDefaultChooseEnemyCommand(1) if pbCanShowCommands?(1)
  end

  def pbSwitchInBetween(index, checkLaxOnly = false, _canCancel = false)
    return @battleAI.pbDefaultChooseNewEnemy(index, pbParty(index)) if index.odd?
    commands = online_boundary("switch", [index], checkLaxOnly)
    raise OnlineForfeit if online_forfeit(commands)
    command = commands[online_owner(index)]
    raise KIFMultiplayer::BattleError, "Missing cooperative replacement" unless command.is_a?(Hash)
    if command["action"] == "ai"
      party = @battleAI.pbDefaultChooseNewEnemy(index, pbParty(index))
    else
      local = command["party_index"]
      raise KIFMultiplayer::BattleError, "Invalid cooperative replacement" unless command["action"] == "switch" && local.is_a?(Integer) && local.between?(0, 2)
      party = local + online_offset(index)
    end
    legal = party.is_a?(Integer) && party >= 0 && (checkLaxOnly ? pbCanSwitchLax?(index, party) : pbCanSwitch?(index, party))
    raise KIFMultiplayer::BattleError, "Authority rejected an illegal cooperative replacement" unless legal
    party
  rescue StandardError => error
    raise KIFMultiplayer::BattleInterrupted.new(error)
  end
end
