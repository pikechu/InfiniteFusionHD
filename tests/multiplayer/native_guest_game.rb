# Real two-Game.exe regression for the native guest renderer. Only input is
# automated; the authority alone executes Pokemon combat and random outcomes.
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
  log = proc { |value| File.open(File.join(directory, "native-guest.log"), "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
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
  $Trainer.name = host ? "Visual authority" : "Visual native guest"
  $PokemonSystem.download_sprites = 1
  $PokemonSystem.battlescene = host ? 1 : 0
  $PokemonSystem.textspeed = 2
  fixture = host ? [:MEWTWO, :ALAKAZAM, :GENGAR] : [:MAGIKARP, :RATTATA, :PIDGEY]
  $Trainer.party = fixture.map do |species|
    pokemon = Pokemon.new(species, 31, $Trainer)
    pokemon.moves = (host ? [:TOXIC, :PSYCHIC] : [:TACKLE, :GROWL]).map { |id| Pokemon::Move.new(id) }
    pokemon.item = :LEFTOVERS
    pokemon.heal
    pokemon
  end
  client = KIFMultiplayer::Client.new
  client.connect($Trainer.name)
  compatibility = client.compatibility
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  wait = proc do |&condition|
    deadline = Time.now + 90
    loop do
      value = condition.call
      break value if value
      raise "Visual battle setup timed out" if Time.now > deadline
      client.pump
    end
  end
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "Native guest acceptance", "compatibility" => compatibility})["room"]
    File.open(coordination, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump({"code" => room["code"]})) }
  else
    wait.call { File.file?(coordination) }
    code = KIFMultiplayer::WireJSON.parse(File.binread(coordination))["code"]
    room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => compatibility})["room"]
  end
  path = "/v1/rooms/#{room['code']}"
  client.request("POST", "#{path}/team", {"candidates" => $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }, "selected" => [0, 1, 2]})
  wait.call do
    members = client.request("GET", path)["room"]["members"]
    members.length == 2 && members.all? { |member| member["selected_count"] == 3 }
  end
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
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  original_bytes = originals.map { |value| Marshal.dump(value) }
  original_digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  original_position = [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  calls, switched = 0, false
  native_counts, fallback, image_count = Hash.new(0), false, 0
  automatic_ui = !host && ENV["KIF_NATIVE_GUEST_UI"] == "1"
  if automatic_ui
    original_trigger = Input.method(:trigger?)
    next_auto_use = Time.now + 0.5
    Input.define_singleton_method(:trigger?) do |button|
      if button == Input::USE && Time.now >= next_auto_use
        next_auto_use = Time.now + 0.5
        true
      else
        original_trigger.call(button)
      end
    end
  end
  KIFMultiplayer.battle_observer = proc do |event, payload|
    log.call("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
    fallback = true if event == "guest_visual_fallback"
    if event == "command_menu_ready" && !host
      bitmap = Graphics.snap_to_bitmap
      bitmap.to_file(File.join(directory, "native-command-menu.png"))
      bitmap.dispose
    end
    if event == "guest_visual_event" && payload["native"]
      native_counts[payload["event"]["kind"]] += 1
      if image_count < 3 && %w[move hp replace].include?(payload["event"]["kind"])
        bitmap = Graphics.snap_to_bitmap
        bitmap.to_file(File.join(directory, "native-#{image_count}-#{payload['event']['kind']}.png"))
        bitmap.dispose
        image_count += 1
      end
    end
  end
  KIFMultiplayer.battle_controller = proc do |state, owner|
    options = state["actions"][owner]
    if !state["phase_owner_ids"].include?(owner)
      {"action" => "wait"}
    elsif state["kind"] == "switch"
      {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
    else
      calls += 1
      if !host && !switched && calls == 2 && !options["switches"].empty?
        switched = true
        {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
      else
        move = host && calls == 1 ? options["moves"].find { |entry| entry["id"] == "TOXIC" } : nil
        move ||= host ? options["moves"].find { |entry| entry["id"] == "PSYCHIC" } : options["moves"].first
        move ||= options["moves"].first
        move ? {"action" => "move", "move_index" => move["index"], "target" => move["targets"].first} : {"action" => "forced"}
      end
    end
  end
  KIFMultiplayer.battle_controller = nil if automatic_ui
  decision = KIFMultiplayer.run_battle(client, room, battle)
  result = client.request("GET", "/v1/battles/#{id}")["battle"]["result"]
  raise "Battle did not settle normally" unless result && !result["abnormal"]
  if !host
    raise "Guest silently fell back instead of native animations" if fallback
    raise "Native move/HP/replacement not exercised" unless native_counts["move"] > 0 && native_counts["hp"] > 0 && native_counts["replace"] >= 3
  end
  unless original_digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
    originals.each_with_index do |value, index|
      next if original_bytes[index] == Marshal.dump(value)
      old = Marshal.load(original_bytes[index])
      changes = (old.instance_variables + value.instance_variables).uniq.select { |field| Marshal.dump(old.instance_variable_get(field)) != Marshal.dump(value.instance_variable_get(field)) }
      log.call("GLOBAL_DIFF index=#{index} fields=#{changes.inspect}")
    end
    raise "Original main globals changed"
  end
  raise "Original map/player moved" unless original_position == [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  log.call("NATIVE_GUEST_GAME_PASS role=#{host ? 'host' : 'guest'} decision=#{decision} native=#{KIFMultiplayer::WireJSON.dump(native_counts)} fallback=#{fallback} result=#{KIFMultiplayer::WireJSON.dump(result)} ORIGINAL_GLOBALS_AND_WORLD_UNCHANGED")
rescue Exception => error
  log.call("NATIVE_GUEST_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  KIFMultiplayer.battle_controller = nil if defined?(KIFMultiplayer)
  exit
end
