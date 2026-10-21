# Actual Game.exe rendering + real HTTP + two independent test identities.
# The controller automates input only; manual mouse/menu acceptance is separate.
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  profile = ENV.fetch("KIF_MULTIPLAYER_PROFILE")
  host = profile.include?("host")
  guest_number = (profile[/guest([123])/, 1] || "1").to_i
  log = proc { |value| File.open(File.join(directory, "hall-game.log"), "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
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
  $Trainer.name = host ? "Hall native host" : "Hall native guest #{guest_number}"
  log.call("SOURCE_LOADED hall=#{KIFMultiplayer::HallScene.instance_method(:run).source_location.join(':')} pid=#{Process.pid}")
  client = KIFMultiplayer::Client.new
  client.connect($Trainer.name)
  # This isolated rendering test uses the installed native-validated catalogue
  # compatibility. Full manifest/client compatibility is verified by the release
  # runner after every developer has frozen their source files.
  compatibility = KIFMultiplayer::WireJSON.parse(File.binread("server/multiplayer/catalog-rental-v1.json"))["compatibility"]
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  if host
    hall = client.request("POST", "/v1/halls", {"name" => "Native render acceptance", "compatibility" => compatibility})["hall"]
    File.open(coordination, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump({"code" => hall["code"]})) }
  else
    deadline = Time.now + 60
    until File.file?(coordination)
      raise "Host did not create hall" if Time.now > deadline
      client.pump
    end
    code = KIFMultiplayer::WireJSON.parse(File.binread(coordination))["code"]
    hall = client.request("POST", "/v1/halls/#{code}/join", {"compatibility" => compatibility})["hall"]
  end
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  old_scene, old_update = $scene, client.wait_update
  position = [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  scene = KIFMultiplayer::HallScene.new(client, hall)
  began, last_move, move_count, captured, observed_pair, sent_emote = Time.now, Time.now, 0, false, false, false
  KIFMultiplayer.hall_controller = proc do |state, _id|
    observed_pair ||= state["members"].length >= 2
    if Time.now - began > 2 && !sent_emote
      scene.session.emote(host ? "hello" : "ready")
      sent_emote = true
    end
    if Time.now - began > 4 && !captured
      bitmap = Graphics.snap_to_bitmap
      bitmap.to_file(File.join(directory, "hall-render.png"))
      bitmap.dispose
      captured = true
      log.call("HALL_RENDERED members=#{state['members'].length} positions=#{KIFMultiplayer::WireJSON.dump(state['members'].map { |member| member.slice('id','x','y','direction','seq','emote') })}")
    end
    if Time.now - began > (host ? 9 : 6)
      :leave
    elsif move_count < 5 && Time.now - last_move > 0.25
      last_move = Time.now
      move_count += 1
      host ? 6 : {1 => 4, 2 => 8, 3 => 2}[guest_number]
    end
  end
  scene.run
  raise "Second real game identity never appeared" unless observed_pair
  raise "Scene not restored" unless $scene.equal?(old_scene) && client.wait_update == old_update
  raise "Main world position changed" unless position == [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  raise "Main globals changed" unless digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
  log.call("HALL_GAME_PASS role=#{host ? 'host' : 'guest'} identity=#{client.player_id} ORIGINAL_GLOBALS_AND_WORLD_UNCHANGED")
rescue Exception => error
  log.call("HALL_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  KIFMultiplayer.hall_controller = nil if defined?(KIFMultiplayer)
  exit
end
