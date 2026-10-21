begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
  log = proc { |value| File.open(File.join(directory, "rental-game.log"), "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
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
  $Trainer.name = host ? "Rental native host" : "Rental native guest"
  $PokemonSystem.download_sprites = 1
  $PokemonSystem.battlescene = 1
  $PokemonSystem.textspeed = 2
  $Trainer.party = [Pokemon.new(:MAGIKARP, 31, $Trainer)]
  client = KIFMultiplayer::Client.new
  client.connect($Trainer.name)
  # Native rendering/combat acceptance while other developers work on source;
  # the release runner separately rebuilds and checks Client#compatibility.
  catalog = KIFMultiplayer::WireJSON.parse(File.binread("server/multiplayer/catalog-rental-v1.json"))
  compatibility = catalog["compatibility"]
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "Native rental acceptance", "mode" => "rental_singles", "compatibility" => compatibility})["room"]
    File.open(coordination, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump({"code" => room["code"]})) }
  else
    deadline = Time.now + 60
    until File.file?(coordination)
      raise "Host did not create rental cup" if Time.now > deadline
      client.pump
    end
    code = KIFMultiplayer::WireJSON.parse(File.binread(coordination))["code"]
    room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => compatibility})["room"]
  end
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  KIFMultiplayer.rental_controller = proc do |draft, id|
    log.call("PICK id=#{draft['id']} index=#{draft['picks'].values.flatten.length} owner=#{id} pool_digest=#{KIFMultiplayer.battle_digest(draft['pool'])}")
    draft["remaining"].first
  end
  KIFMultiplayer.battle_controller = proc do |state, id|
    options = state.fetch("actions").fetch(id)
    if !state["phase_owner_ids"].include?(id)
      {"action" => "wait"}
    elsif state["kind"] == "switch"
      {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
    else
      opponent = state["battlers"].find { |battler| battler["owner_id"] != id && battler["hp"] > 0 }
      species = GameData::Species.get(opponent["species"]) if opponent
      move = options["moves"].max_by do |entry|
        data = GameData::Move.get(entry["id"])
        multiplier = species ? Effectiveness.calculate(data.type, species.type1, species.type2) : 8
        data.base_damage * multiplier
      end
      move ? {"action" => "move", "move_index" => move["index"], "target" => (move["targets"] || [-1]).first} : {"action" => "forced"}
    end
  end
  KIFMultiplayer.battle_observer = proc do |event, payload|
    log.call("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
  end
  decision = KIFMultiplayer.run_rental(client, room)
  final = client.request("GET", "/v1/rooms/#{room['code']}")["room"]
  battle = client.request("GET", "/v1/battles/#{final['battle_id']}")["battle"]
  raise "Rental did not finish normally" unless battle["phase"] == "finished" && !battle["result"]["abnormal"]
  raise "Main globals changed" unless digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
  raise "Rental escaped into main party" unless $Trainer.party.length == 1 && $Trainer.party[0].species == :MAGIKARP && $Trainer.party[0].level == 31
  restored_decision = KIFMultiplayer.run_rental(client, final)
  raise "Finished cup recovery tried to restart host engine" unless restored_decision == decision
  log.call("RENTAL_GAME_PASS role=#{host ? 'host' : 'guest'} identity=#{client.player_id} decision=#{decision} result=#{KIFMultiplayer::WireJSON.dump(battle['result'])} ORIGINAL_GLOBALS_UNCHANGED")
rescue Exception => error
  log.call("RENTAL_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  KIFMultiplayer.rental_controller = nil if defined?(KIFMultiplayer)
  KIFMultiplayer.battle_controller = nil if defined?(KIFMultiplayer)
  exit
end
