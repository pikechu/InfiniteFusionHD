# Actual Game.exe: default 60-second guest budget, 70-second transport failure,
# authority AI continuation, then next-phase human control restoration.
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
  log = proc { |value| File.open(File.join(directory, "boss-disconnect.log"), "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
  loader = lambda do |path|
    entries = Dir.entries(path).reject { |entry| entry == "." || entry == ".." }
    files, folders = entries.partition { |entry| !File.directory?(File.join(path, entry)) }
    files.sort.each { |entry| load File.join(path, entry) }
    folders.sort.each { |entry| loader.call(File.join(path, entry)) unless path == "Data/Scripts" && entry == "999_Main" }
  end
  loader.call("Data/Scripts")
  $POKEMONDATA_QUEUEING = []
  MessageTypes.loadMessageFile("Data/messages.dat")
  PluginManager.runPlugins
  Dir["Mods/*.rb"].sort.each { |file| load File.expand_path(file) }
  Game.initialize
  SaveData.initialize_bootup_values
  SaveData.load_new_game_values
  $scene = Object.new
  $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
  $game_player.moveto($data_system.start_x, $data_system.start_y)
  $Trainer.name = host ? "AI takeover authority" : "Returning guest"
  $PokemonSystem.download_sprites, $PokemonSystem.battlescene, $PokemonSystem.textspeed = 1, 1, 2
  $Trainer.party = 3.times.map do
    pokemon = Pokemon.new(:GYARADOS, 31, $Trainer)
    pokemon.moves = [:PROTECT, :SURF, :GROWL].map { |id| Pokemon::Move.new(id) }
    pokemon.ability, pokemon.nature, pokemon.item = :INTIMIDATE, :BOLD, :LEFTOVERS
    KIFMultiplayer::Snapshot::STATS.each { |stat| pokemon.iv[stat.to_sym] = 31; pokemon.ev[stat.to_sym] = 0 }
    pokemon.ev[:HP], pokemon.ev[:DEFENSE] = 252, 252
    pokemon.calc_stats
    pokemon.heal
    pokemon
  end
  base_transport = KIFMultiplayer::HTTPTransport.new
  transport = Object.new
  transport.define_singleton_method(:backend) { base_transport.backend }
  transport.define_singleton_method(:restore!) { @blocked_until = nil; @disarmed = true }
  accepted_commands, abort_attempts = [], []
  transport.define_singleton_method(:call) do |method, url, body, token, timeout|
    if !host && !@disarmed && !@blocked_until && method == "POST" && url.end_with?("/commands")
      @blocked_until = Time.now + 72
      log.call("FAULT_BEGIN seconds=72 request=#{body['request_id']} turn=#{body['turn']}")
    end
    abort_attempts << body if !host && url.end_with?("/abort")
    raise IOError, "Diagnostic guest transport outage" if @blocked_until && Time.now < @blocked_until
    response = base_transport.call(method, url, body, token, timeout)
    if method == "POST" && url.end_with?("/commands") && (response[:status] || response["status"]) == 200
      accepted_commands << {"turn" => body["turn"], "request_id" => body["request_id"], "command" => body["command"]}
      log.call("ACCEPTED_COMMAND #{KIFMultiplayer::WireJSON.dump(accepted_commands.last)}")
    end
    response
  end
  client = KIFMultiplayer::Client.new(nil, transport)
  client.connect($Trainer.name)
  compatibility = client.compatibility
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  wait = proc do |label, &condition|
    deadline = Time.now + 180
    loop do
      value = condition.call
      break value if value
      raise "Timed out #{label}" if Time.now > deadline
      client.pump
    end
  end
  direct_get = proc do |path|
    saved = client.wait_update
    begin
      client.wait_update = nil
      client.request("GET", path)
    ensure
      client.wait_update = saved
    end
  end
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "Default budget recovery", "mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => "hard", "compatibility" => compatibility})["room"]
    File.write(coordination, KIFMultiplayer::WireJSON.dump({"code" => room["code"]}))
  else
    wait.call("room") { File.file?(coordination) }
    code = KIFMultiplayer::WireJSON.parse(File.read(coordination))["code"]
    room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => compatibility})["room"]
  end
  path = "/v1/rooms/#{room['code']}"
  client.request("POST", "#{path}/team", {"candidates" => $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }, "selected" => [0, 1, 2]})
  wait.call("teams") do
    members = client.request("GET", path)["room"]["members"]
    members.length == 2 && members.all? { |member| member["selected_count"] == 3 }
  end
  client.request("POST", "#{path}/ready", {"ready" => true})
  if host
    wait.call("ready") { client.request("GET", path)["room"]["members"].all? { |member| member["ready"] } }
    id = client.request("POST", "#{path}/start")["battle_id"]
  else
    id = wait.call("start") do
      current = client.request("GET", path)["room"]
      current["status"] == "playing" && current["battle_id"]
    end
  end
  battle = client.request("GET", "/v1/battles/#{id}")["battle"]
  raise "Test did not use default cumulative allowance" unless battle["reconnect_remaining"].values.all? { |seconds| seconds == 60 }
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  guest_id = battle["players"][1]
  observed_ai, restored = false, false
  KIFMultiplayer.battle_observer = proc do |event, payload|
    log.call("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}") if %w[guest_detached settlement boss_reward engine_finished].include?(event)
    if host && event == "authority_state"
      current = direct_get.call("/v1/battles/#{id}")["battle"]
      if current["ai_controlled_ids"].include?(guest_id) && !observed_ai
        observed_ai = true
        info = {"turn" => current["turn"], "remaining" => current["reconnect_remaining"][guest_id], "phase" => current["phase"]}
        File.write(coordination + ".ai", KIFMultiplayer::WireJSON.dump(info))
        log.call("AI_TAKEOVER #{KIFMultiplayer::WireJSON.dump(info)}")
      end
    end
  end
  KIFMultiplayer.battle_controller = proc do |state, owner|
    options = state["actions"][owner]
    if state["kind"] == "switch"
      {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
    else
      if !host && transport.instance_variable_get(:@disarmed)
        current = direct_get.call("/v1/battles/#{id}")["battle"]
        raise "Human acted before AI released control" if current["ai_controlled_ids"].include?(owner)
        unless restored
          restored = true
          info = {"turn" => current["turn"], "remaining" => current["reconnect_remaining"][owner]}
          File.write(coordination + ".restored", KIFMultiplayer::WireJSON.dump(info))
          log.call("CONTROL_RESTORED #{KIFMultiplayer::WireJSON.dump(info)}")
        end
      end
      attack = !host || File.file?(coordination + ".restored")
      move = options["moves"].find { |entry| entry["id"] == (attack ? "SURF" : "PROTECT") }
      move ||= options["moves"].first
      move ? {"action" => "move", "move_index" => move["index"], "target" => move["targets"].first} : {"action" => "forced"}
    end
  end
  if host
    decision = KIFMultiplayer.run_boss(client, room, battle)
    raise "Guest allowance never exhausted" unless observed_ai
  else
    began = Time.now
    begin
      KIFMultiplayer.run_boss(client, room, battle)
      raise "Expected guest transport detachment"
    rescue KIFMultiplayer::Error
      raise "Guest did not preserve detachment recovery" unless client.profile.account["boss_detached"] && abort_attempts.empty?
      raise "Guest fetch did not exercise 70-second recovery boundary" unless Time.now - began >= 70
      log.call("DETACHED_WITHOUT_ABORT elapsed=#{(Time.now - began).round(1)}")
    end
    transport.restore!
    wait.call("real AI takeover") { File.file?(coordination + ".ai") }
    current = client.request("GET", "/v1/battles/#{id}")["battle"]
    raise "Guest client error terminated authority" if current["phase"] == "finished"
    log.call("RECONNECTED turn=#{current['turn']} phase=#{current['phase']} ai=#{current['ai_controlled_ids'].inspect} pending=#{current['control_restore_pending_ids'].inspect}")
    begin
      client.recover_pending
    rescue KIFMultiplayer::Error => error
      raise unless %w[turn_mismatch turn_locked ai_controlled].include?(error.code) && !client.profile.account["pending"]
      log.call("STALE_COMMAND_DEFINITIVELY_REJECTED code=#{error.code}")
    end
    current = client.request("GET", "/v1/battles/#{id}")["battle"]
    decision = KIFMultiplayer.run_boss(client, room, current)
    raise "Human control did not return" unless restored && abort_attempts.empty?
  end
  final = client.request("GET", "/v1/battles/#{id}")["battle"]
  raise "Cooperative recovery did not finish in victory" unless decision == 1 && final["result"]["coop_outcome"] == "victory"
  raise "Accepted a duplicate command phase" unless accepted_commands.map { |entry| entry["turn"] }.uniq.length == accepted_commands.length
  raise "Main globals changed" unless digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
  log.call("BOSS_DISCONNECT_GAME_PASS role=#{host ? 'host' : 'guest'} battle_id=#{id} accepted=#{KIFMultiplayer::WireJSON.dump(accepted_commands)} result=#{KIFMultiplayer::WireJSON.dump(final['result'])} ORIGINAL_GLOBALS_UNCHANGED")
rescue Exception => error
  log.call("BOSS_DISCONNECT_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  KIFMultiplayer.battle_controller = nil if defined?(KIFMultiplayer)
  exit
end
