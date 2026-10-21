# Actual Game.exe integration scenario. Only user input is automated; the host
# uses the production battle scene/engine/data. This does not certify manual UI.
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  profile = ENV.fetch("KIF_MULTIPLAYER_PROFILE")
  host = profile.include?("host")
  faults = ENV["KIF_MULTIPLAYER_FAULTS"] == "1"
  expect_restart = ENV["KIF_MULTIPLAYER_EXPECT_RESTART"] == "1"
  log_file = File.join(directory, "game-smoke.log")
  log = lambda do |message|
    File.open(log_file, "a") { |file| file.puts("#{Time.now.utc} #{message}"); file.flush }
  end
  log.call("BEGIN pid=#{Process.pid} role=#{host ? 'host' : 'guest'} ruby=#{RUBY_VERSION}")
  loaded = []
  loader = lambda do |path|
    entries = Dir.entries(path).reject { |name| name == "." || name == ".." }
    files, folders = entries.partition { |name| !File.directory?(File.join(path, name)) }
    files.sort.each do |name|
      full = File.join(path, name)
      eval(File.read(full), TOPLEVEL_BINDING, full)
      loaded << full
    end
    folders.sort.each do |name|
      next if path == "Data/Scripts" && name == "999_Main"
      loader.call(File.join(path, name))
    end
  end
  loader.call("Data/Scripts")
  raise "Multiplayer scripts were not loaded" unless loaded.grep(%r{054_Multiplayer/}).length >= 3
  log.call("SOURCE_LOADED count=#{loaded.length} multiplayer=#{loaded.grep(%r{054_Multiplayer/}).join(',')}")
  $POKEMONDATA_QUEUEING = []
  MessageTypes.loadMessageFile("Data/messages.dat")
  PluginManager.runPlugins
  Dir["Mods/*.rb"].sort.each { |file| load File.expand_path(file) }
  # Use the same compiled database as production, but do not invoke boot/load
  # menus, migration, compiler output, any player's save, or the starting events.
  Game.initialize
  SaveData.initialize_bootup_values
  SaveData.load_new_game_values
  $scene = Object.new
  $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
  $game_player.moveto($data_system.start_x, $data_system.start_y)
  $PokemonEncounters = PokemonEncounters.new
  $PokemonEncounters.setup($game_map.map_id)
  $Trainer.name = host ? "MP Test Host" : "MP Test Guest"
  $PokemonSystem.shiny_cache = 2
  $PokemonSystem.download_sprites = 1
  $PokemonSystem.battlescene = host ? 1 : 0
  $PokemonSystem.textspeed = 2
  if ENV["KIF_MULTIPLAYER_DIFFERENT_SPEED"] == "1"
    $GameSpeed = host ? 4 : 1
    $PokemonSystem.battlescene = host ? 0 : 1
  end
  log.call("PRESENTATION game_speed=#{$GameSpeed} battlescene=#{$PokemonSystem.battlescene}")
  log.call("GAME_INITIALIZED map=#{$game_map.map_id} trainer_type=#{$Trainer.trainer_type}")
  load "tests/multiplayer/client_game_test.rb"
  KIFMultiplayerClientGameTest.run(log)
  fixture = host ? [:MEWTWO, :ALAKAZAM, :GENGAR] : [:MAGIKARP, :RATTATA, :PIDGEY]
  $Trainer.party = fixture.map do |species|
    pokemon = Pokemon.new(species, 31, $Trainer)
    pokemon.moves.clear
    (host ? [:TOXIC, :PSYCHIC, :THUNDERBOLT] : [:TACKLE, :GROWL]).each do |move|
      pokemon.learn_move(move)
    end
    pokemon.item = :LEFTOVERS
    pokemon.heal
    pokemon
  end
  originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  original_digest = Digest::SHA256.hexdigest(Marshal.dump(originals))
  # Faults are confined to this explicit diagnostic entrypoint. A request is
  # really committed on the service before its response is intentionally lost.
  transport = KIFMultiplayer::HTTPTransport.new
  if faults && !host
    base_transport = transport
    transport = Object.new
    transport.define_singleton_method(:backend) { base_transport.backend }
    transport.define_singleton_method(:call) do |method, url, body, token, timeout|
      response = base_transport.call(method, url, body, token, timeout)
      if !@lost_once && url.end_with?("/commands") && response[:status] == 200
        @lost_once = true
        log.call("FAULT_RESPONSE_LOST committed_request=#{body['request_id']}")
        raise IOError, "Diagnostic response loss after real service commit"
      end
      response
    end
  end
  client = KIFMultiplayer::Client.new(nil, transport)
  client.connect($Trainer.name)
  log.call("IDENTITY id=#{client.player_id} backend=#{client.transport.backend}")
  compatibility = client.compatibility
  snapshots = $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }
  log.call("SNAPSHOTS_VALID count=#{snapshots.length}")
  coordination = ENV.fetch("KIF_MULTIPLAYER_SCENARIO", "temp/multiplayer/scenario.json")
  wait_until = lambda do |label, &condition|
    start = Time.now
    loop do
      result = condition.call
      break result if result
      raise "Timed out: #{label}" if Time.now - start > 180
      limit = Time.now + 0.3
      client.pump while Time.now < limit
    end
  end
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "Real game integration", "compatibility" => compatibility})["room"]
    showcase = client.request("POST", "/v1/showcases", {"snapshot" => snapshots[0], "public_fields" => []})["showcase"]
    File.write(coordination + ".pending", KIFMultiplayer::WireJSON.dump({"room_code" => room["code"], "showcase_code" => showcase["code"], "host_id" => client.player_id}))
    File.rename(coordination + ".pending", coordination)
    log.call("CREATED room=#{room['code']} showcase=#{showcase['code']}")
  else
    configuration = wait_until.call("host room") do
      File.file?(coordination) && KIFMultiplayer::WireJSON.parse(File.read(coordination))
    end
    room = client.request("POST", "/v1/rooms/#{configuration['room_code']}/join", {"compatibility" => compatibility})["room"]
    showcase = client.request("GET", "/v1/showcases/#{configuration['showcase_code']}")["showcase"]
    raise "Hidden showcase fields leaked" unless (showcase["snapshot"].keys & %w[name owner iv ev personal_id]).empty?
    log.call("JOINED room=#{room['code']} SHOWCASE_PRIVACY_PASS species=#{showcase['snapshot']['species']}")
  end
  base = "/v1/rooms/#{room['code']}"
  client.request("POST", base + "/team", {"candidates" => snapshots, "selected" => [0, 1, 2]})
  # Wait for both frozen candidate sets before ready; changing a team invalidates
  # readiness on both sides and is intentionally exercised by service tests.
  wait_until.call("both teams") do
    room = client.request("GET", base)["room"]
    room["members"].length == 2 && room["members"].all? { |member| member["selected_count"] == 3 }
  end
  log.call("TEAMS_READY")
  battles = []
  2.times do |match|
    client.request("POST", base + "/ready", {"ready" => true})
    if host
      wait_until.call("both ready") { client.request("GET", base)["room"]["members"].all? { |member| member["ready"] } }
      id = client.request("POST", base + "/start")["battle_id"]
    else
      id = wait_until.call("battle started") do
        r = client.request("GET", base)["room"]
        r["status"] == "playing" && r["battle_id"]
      end
    end
    battles << id
    battle = client.request("GET", "/v1/battles/#{id}")["battle"]
    chosen_rounds = 0
    voluntary_switched = false
    poison_observed = false
    KIFMultiplayer.battle_controller = proc do |state, player_id|
      opts = (state["actions"] || {})[player_id] || {}
      poison_observed ||= (state["battlers"] || []).any? { |b| b["owner_id"] != player_id && b["status"] == "POISON" }
      if !(state["phase_owner_ids"] || []).include?(player_id)
        action = {"action" => "wait"}
      elsif state["kind"] == "switch"
        choice = opts["switches"].first
        action = {"action" => "switch", "party_index" => choice["party_index"]}
      else
        chosen_rounds += 1
        if faults && !host && match == 0 && chosen_rounds == 2
          log.call("FAULT_RECONNECT_BEGIN no_heartbeat_seconds=12")
          resume_at = Time.now + 12
          client.pump while Time.now < resume_at
          restored = client.request("GET", "/v1/battles/#{id}")["battle"]
          remaining = restored["reconnect_remaining"][player_id]
          raise "Disconnect did not consume cumulative budget" unless remaining < 60 && remaining > 0
          log.call("FAULT_RECONNECT_PASS remaining=#{remaining}")
        end
        if faults && !host && match == 1 && chosen_rounds == 1
          # Keep heartbeats alive but provide no command until the real service
          # has selected its deterministic default after the 60-second deadline.
          log.call("FAULT_ACTION_TIMEOUT_BEGIN wait_seconds=63")
          resume_at = Time.now + 63
          next_heartbeat = Time.now
          while Time.now < resume_at
            client.pump
            if Time.now >= next_heartbeat
              client.request("GET", "/v1/battles/#{id}")
              next_heartbeat = Time.now + 2
            end
          end
          log.call("FAULT_ACTION_TIMEOUT_RESUMED")
        end
        if !host && !voluntary_switched && chosen_rounds == 2 && !opts["switches"].empty?
          voluntary_switched = true
          action = {"action" => "switch", "party_index" => opts["switches"].first["party_index"]}
        else
          move = host && !poison_observed ? opts["moves"].find { |m| m["id"] == "TOXIC" } : nil
          move ||= host ? opts["moves"].find { |m| m["id"] == "PSYCHIC" } : opts["moves"].first
          move ||= opts["moves"].first
          action = move ? {"action" => "move", "move_index" => move["index"], "target" => -1} : {"action" => "forced"}
        end
      end
      log.call("COMMAND match=#{match + 1} round=#{state['turn_count']} #{KIFMultiplayer::WireJSON.dump(action)}")
      action
    end
    screenshots = 0
    KIFMultiplayer.battle_observer = proc do |event, payload|
      log.call("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
      if event == "authority_state" && screenshots < 2
        bitmap = Graphics.snap_to_bitmap
        bitmap.to_file(File.join(directory, "match-#{match + 1}-state-#{screenshots}.png"))
        bitmap.dispose
        screenshots += 1
      end
    end
    log.call("BATTLE_BEGIN match=#{match + 1} id=#{id}")
    decision = KIFMultiplayer.run_battle(client, room, battle)
    final = client.request("GET", "/v1/battles/#{id}")["battle"]
    if expect_restart && match == 1
      raise "Expected official service restart cancellation" unless final["phase"] == "finished" && final["result"] && final["result"]["abnormal"] && final["result"]["reason"] == "service_restart" && final["result"]["winner_id"].nil? && decision == 0
      log.call("BATTLE_ABORT_PASS decision=#{decision} result=#{KIFMultiplayer::WireJSON.dump(final['result'])}")
    else
      raise "No authoritative final result" unless final["phase"] == "finished" && final["result"] && !final["result"]["abnormal"]
    end
    raise "Original global object replaced" unless originals.each_with_index.all? { |value, i| value.equal?([$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables][i]) }
    raise "Original save data changed" unless original_digest == Digest::SHA256.hexdigest(Marshal.dump(originals))
    log.call("BATTLE_PASS match=#{match + 1} decision=#{decision} result=#{KIFMultiplayer::WireJSON.dump(final['result'])} ORIGINAL_GLOBALS_UNCHANGED")
  end
  raise "Rematch reused battle identifier" unless battles.uniq.length == 2
  log.call("GAME_SMOKE_PASS battles=#{battles.join(',')}")
rescue Exception => error
  if defined?(log) && log
    log.call("GAME_SMOKE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  end
ensure
  exit
end
