# Real cooperative engine regression: one trainer starts with three fainted
# carried Pokemon, watches, and wins only when the surviving partner wins.
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
  log = proc { |value| File.open(File.join(directory, "boss-watcher.log"), "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
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
  $Trainer.name = host ? "Watcher host" : "Surviving guest"
  $PokemonSystem.download_sprites = 1
  $PokemonSystem.battlescene = 1
  $PokemonSystem.textspeed = 2
  $Trainer.party = 3.times.map do
    pokemon = Pokemon.new(:BLASTOISE, 31, $Trainer)
    pokemon.moves = [:SURF, :ICEBEAM].map { |id| Pokemon::Move.new(id) }
    pokemon.heal
    pokemon
  end
  client = KIFMultiplayer::Client.new
  client.connect($Trainer.name)
  compatibility = KIFMultiplayer::WireJSON.parse(File.binread("server/multiplayer/catalog-rental-v1.json"))["compatibility"]
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  wait = proc do |&condition|
    deadline = Time.now + 90
    loop do
      value = condition.call
      break value if value
      raise "Cooperative setup timed out" if Time.now > deadline
      client.pump
    end
  end
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "Initial watcher regression", "mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => "normal", "compatibility" => compatibility})["room"]
    File.open(coordination, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump({"code" => room["code"]})) }
  else
    wait.call { File.file?(coordination) }
    code = KIFMultiplayer::WireJSON.parse(File.binread(coordination))["code"]
    room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => compatibility})["room"]
  end
  path = "/v1/rooms/#{room['code']}"
  client.request("POST", "#{path}/team", {"candidates" => $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }, "selected" => [0, 1, 2]})
  wait.call { client.request("GET", path)["room"]["members"].all? { |member| member["selected_count"] == 3 } && client.request("GET", path)["room"]["members"].length == 2 }
  client.request("POST", "#{path}/ready", {"ready" => true})
  if host
    wait.call { client.request("GET", path)["room"]["members"].all? { |member| member["ready"] } }
    id = client.request("POST", "#{path}/start")["battle_id"]
  else
    id = wait.call do
      current = client.request("GET", path)["room"]
      current["status"] == "playing" && current["battle_id"]
    end
  end
  battle = client.request("GET", "/v1/battles/#{id}")["battle"]
  if host
    KIFMultiplayer::BattleIsolation.with do
      players = battle["players"]
      parties = players.map { |owner| battle["initial_teams"][owner].map { |snapshot| KIFMultiplayer::Snapshot.import(snapshot, 50) } }
      runtime = KIFMultiplayer.boss_team_state(parties, players)
      runtime[players[0]].each { |entry| entry["hp"] = 0; entry["status"] = "NONE"; entry["status_count"] = 0 }
      battle["runtime_state"] = runtime
      log.call("INITIAL_RUNTIME #{KIFMultiplayer::WireJSON.dump(runtime)}")
    end
  end
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  original_bytes = originals.map { |value| Marshal.dump(value) }
  digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  post_state, commands, native_ready, visual_fallback = nil, 0, false, false
  KIFMultiplayer.battle_observer = proc do |event, payload|
    log.call("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
    post_state = payload["team_states"] if event == "boss_team_state"
    native_ready = true if event == "guest_native_started"
    visual_fallback = true if event == "guest_visual_fallback"
  end
  KIFMultiplayer.battle_controller = proc do |state, owner|
    commands += 1
    raise "Initially eliminated trainer received controls" if host
    options = state["actions"][owner]
    if state["kind"] == "switch"
      {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
    else
      move = options["moves"].find { |entry| entry["id"] == "SURF" } || options["moves"].first
      move ? {"action" => "move", "move_index" => move["index"], "target" => move["targets"].first} : {"action" => "forced"}
    end
  end
  decision = KIFMultiplayer.run_boss(client, room, battle)
  result = client.request("GET", "/v1/battles/#{id}")["battle"]["result"]
  raise "Partner failed to finish cooperative battle" unless decision == 1 && result["coop_outcome"] == "victory"
  raise "Watcher was revived or post-state absent" if host && (!post_state || post_state[client.player_id].any? { |entry| entry["hp"] != 0 })
  if !host && defined?(KIFMultiplayer::GuestBattlePresenter)
    raise "Cooperative guest native renderer fell back" unless native_ready && !visual_fallback
  end
  unless digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
    originals.each_with_index do |current, index|
      next if original_bytes[index] == Marshal.dump(current)
      old = Marshal.load(original_bytes[index])
      changed = (old.instance_variables + current.instance_variables).uniq.select do |field|
        Marshal.dump(old.instance_variable_get(field)) != Marshal.dump(current.instance_variable_get(field))
      end
      log.call("GLOBAL_DIFF index=#{index} class=#{current.class} fields=#{changed.inspect}")
      changed.each { |field| log.call("GLOBAL_VALUE #{field} before=#{old.instance_variable_get(field).inspect} after=#{current.instance_variable_get(field).inspect}") }
    end
    raise "Original globals changed"
  end
  log.call("BOSS_INITIAL_WATCHER_PASS role=#{host ? 'host' : 'guest'} controls=#{commands} result=#{KIFMultiplayer::WireJSON.dump(result)} ORIGINAL_GLOBALS_UNCHANGED")
rescue Exception => error
  log.call("BOSS_INITIAL_WATCHER_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  KIFMultiplayer.battle_controller = nil if defined?(KIFMultiplayer)
  exit
end
