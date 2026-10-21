# Actual Game.exe + HTTP acceptance. Only player choices and restart timing are
# automated; every battle is resolved by the existing native authority engine.
begin
  native_pass = false
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  # Use the actual overworld scene that players enter from. Object.new hid
  # message-window miniupdate leaks in the original acceptance fixture.
  $scene = Scene_Map.new
  $scene.createSpritesets
  original_map_scene = $scene
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  profile = ENV.fetch("KIF_MULTIPLAYER_PROFILE")
  role = profile.include?("viewer") ? "viewer" : profile.include?("host") ? "host" : "guest"
  fault_only = ENV["KIF_DUNGEON_FAULT_ONLY"] == "1"
  gc_diagnostic = ENV["KIF_DUNGEON_GC_PROBE"] == "1"
  capture_images = ENV["KIF_DUNGEON_NO_CAPTURE"] != "1"
  host = role == "host"
  base = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  own_file = base + ".#{role}.json"
  own = {"pid" => Process.pid, "role" => role, "scope" => fault_only ? "fault_only" : "full_route_replay_recovery", "stage" => "boot"}
  write = lambda do |values|
    own.merge!(values)
    attempts = 0
    begin
      test.marker(own_file, own)
    rescue Errno::EACCES
      # Windows readers/virus scanners can briefly deny atomic replacement.
      # This coordinator is outside the game protocol; retry the same document.
      attempts += 1
      raise if attempts >= 30
      sleep(0.025)
      retry
    end
  end
  read_role = lambda { |name| test.read(base + ".#{name}.json") || {} }
  checks = 0
  client = nil
  check = lambda do |condition, message|
    test.check(condition, "DUNGEON_REPLAY #{role} #{message}")
    checks += 1
  end
  wait_role = lambda do |name, key, timeout = 300|
    test.wait(client, "#{name}.#{key}", timeout) do
      value = read_role.call(name)
      raise "Peer #{name} failed: #{value['error']}" if value["stage"] == "failed"
      value if value[key]
    end
  end
  write.call({})
  client = KIFMultiplayer::Client.new
  check.call(client.transport.backend == :core_socket && defined?(KIFMultiplayer::SocketHTTP), "production module 015 core Socket transport is loaded")
  client.connect("Route #{role}")
  compatibility = client.compatibility
  catalog = KIFMultiplayer::WireJSON.parse(File.binread("server/multiplayer/catalog-rental-v1.json"))
  check.call(compatibility == catalog["compatibility"], "actual loaded source matches final installed catalog")
  test.log("VERIFIED_BUILD role=#{role} player=#{client.player_id} compatibility=#{KIFMultiplayer::WireJSON.dump(compatibility)}")
  $PokemonSystem.battlescene = role == "guest" ? 0 : 1
  $GameSpeed = role == "guest" ? 2 : 4
  original_trigger = Input.method(:trigger?)
  next_auto_use = KIFMultiplayer.monotonic
  Input.define_singleton_method(:trigger?) do |button|
    if button == Input::USE && KIFMultiplayer.monotonic >= next_auto_use
      next_auto_use = KIFMultiplayer.monotonic + 0.2
      true # Advance genuine native message windows; move choices stay explicit.
    else
      original_trigger.call(button)
    end
  end
  species = host ? [:PALKIA, :KYOGRE, :LUGIA] : [:KYOGRE, :PALKIA, :LUGIA]
  $Trainer.party = species.each_with_index.map do |id, index|
    moves = [:SURF, :ICEBEAM, :SHADOWBALL, :PROTECT]
    moves[2] = :SOLARBEAM if host && index == 0
    moves[3] = :GLARE if role == "guest" && index == 0
    pokemon = test.pokemon(id, moves, host && index == 0 ? :POWERHERB : :SITRUSBERRY)
    pokemon.nature = :HARDY
    GameData::Stat.each_main { |stat| pokemon.iv[stat.id] = 31; pokemon.ev[stat.id] = 0 }
    pokemon.name = "#{role} #{id.to_s[0, 12]}"
    pokemon.calc_stats
    pokemon.hp = [pokemon.totalhp - 7 - index, 1].max
    pokemon.moves.first.pp = 3
    pokemon
  end
  check.call($Trainer.party.all? { |pokemon| pokemon.level == 31 }, "original team starts at level 31 with reduced HP and PP")
  $Trainer.save_slot = "Dungeon Native Fixture"
  save_writer = KIFMultiplayer::TradeSave.new
  check.call(save_writer.persist, "original independent test save written atomically before battles")
  original_save_path = File.expand_path(save_writer.path)
  check.call(original_save_path.start_with?(File.expand_path(directory) + "/"), "fixture save stays inside this isolated test profile")
  original_save_digest = Digest::SHA256.hexdigest(File.binread(original_save_path))
  originals = test.globals
  original_bytes = originals.map { |value| Marshal.dump(value) }
  original_digest = test.digest(originals)
  original_world = [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  world_callbacks = {"miniupdate" => 0, "map.update" => 0, "player.update" => 0, "transfer_player" => 0}
  [[original_map_scene, :miniupdate, "miniupdate"], [$game_map, :update, "map.update"],
   [$game_player, :update, "player.update"], [original_map_scene, :transfer_player, "transfer_player"]].each do |object, method, label|
    object.define_singleton_method(method) do |*|
      world_callbacks[label] += 1
      raise "ORIGINAL_WORLD_UPDATED_DURING_MULTIPLAYER #{label}"
    end
  end
  check_globals = lambda do |label|
    unless original_digest == test.digest(originals)
      originals.each_with_index do |value, index|
        next if original_bytes[index] == Marshal.dump(value)
        old = Marshal.load(original_bytes[index])
        changed = (old.instance_variables + value.instance_variables).uniq.select { |field| Marshal.dump(old.instance_variable_get(field)) != Marshal.dump(value.instance_variable_get(field)) }
        test.log("GLOBAL_DIFF #{label} index=#{index} fields=#{changed.inspect}")
      end
    end
    check.call(original_digest == test.digest(originals), "#{label}: original six save globals unchanged")
    check.call(originals.each_with_index.all? { |value, index| value.equal?(test.globals[index]) }, "#{label}: original global object identities restored")
    check.call(original_world == [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction], "#{label}: original map and player position unchanged")
    check.call($scene.equal?(original_map_scene) && world_callbacks.values.all? { |count| count == 0 }, "#{label}: actual Scene_Map restored with zero overworld updates")
    check.call(Digest::SHA256.hexdigest(File.binread(original_save_path)) == original_save_digest, "#{label}: actual original disk save unchanged")
  end
  gc_checkpoint = lambda do |label|
    next unless gc_diagnostic
    test.log("GC_PROBE_BEGIN role=#{role} boundary=#{label} count=#{GC.stat[:count]}")
    GC.start
    test.log("GC_PROBE_END role=#{role} boundary=#{label} count=#{GC.stat[:count]}")
  end
  if gc_diagnostic
    board_dispose = KIFMultiplayer::BattleBoard.instance_method(:dispose)
    KIFMultiplayer::BattleBoard.define_method(:dispose) do
      board_dispose.bind(self).call
      gc_checkpoint.call("board_disposed")
    end
  end
  gc_checkpoint.call("initial_fixture")
  write.call("player_id" => client.player_id, "compatibility" => compatibility, "original_digest" => original_digest, "original_save_path" => original_save_path, "original_save_sha256" => original_save_digest, "game_speed" => $GameSpeed, "animations" => $PokemonSystem.battlescene, "http_backend" => client.transport.backend.to_s, "ruby_version" => RUBY_VERSION)
  current_battle, first_states, final_states = nil, {}, {}
  engine_ids, native_ids, glare_ids, switched_ids = [], [], {}, {}
  native_events = Hash.new(0)
  replay_frames = 0
  rewards = []
  fallback = []
  images = 0
  KIFMultiplayer.battle_observer = proc do |event, payload|
    test.log("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
    if event == "engine_started"
      current_battle = payload["battle_id"]
      engine_ids << current_battle unless engine_ids.include?(current_battle)
    elsif event == "guest_native_started"
      current_battle = payload["battle_id"]
      native_ids << current_battle unless native_ids.include?(current_battle)
    elsif event == "authority_state"
      first_states[current_battle] ||= payload["state"]
      final_states[current_battle] = payload["state"] if payload["decision"].to_i > 0
    elsif event == "guest_visual_event" && payload["native"]
      native_events[payload["event"]["kind"]] += 1
    elsif event == "guest_visual_fallback"
      fallback << payload
    elsif event == "dungeon_reward"
      rewards << payload
    elsif event == "replay_frame"
      replay_frames += 1
    end
    gc_checkpoint.call(event) if %w[engine_finished settlement dungeon_reward].include?(event)
    if capture_images && images < 3 && %w[guest_visual_applied replay_frame].include?(event)
      Graphics.update
      bitmap = Graphics.snap_to_bitmap
      bitmap.to_file(File.join(directory, "dungeon-replay-#{images}-#{event}.png"))
      bitmap.dispose
      images += 1
    end
  end
  grass_species = catalog["pokemon"][1]["species"]
  KIFMultiplayer.battle_controller = proc do |state, owner|
    options = state.fetch("actions").fetch(owner)
    if !state.fetch("phase_owner_ids").include?(owner)
      {"action" => "wait"}
    elsif state["kind"] == "switch"
      choice = options.fetch("switches").first
      raise "No legal forced replacement" unless choice
      {"action" => "switch", "party_index" => choice["party_index"]}
    else
      moves = options.fetch("moves")
      own_battler = state.fetch("battlers").find { |entry| entry["owner_id"] == owner }
      boss = state.fetch("battlers").find { |entry| entry["owner_id"] == "boss" }
      grass = boss && boss["species"] == grass_species
      held = state.dig("team_states", owner, own_battler && own_battler["party_index"].to_i, "item")
      move = nil
      target = nil
      if host && grass && held == "POWERHERB"
        move = moves.find { |entry| entry["id"] == "SOLARBEAM" }
      elsif role == "guest" && grass && !glare_ids[current_battle]
        move = moves.find { |entry| entry["id"] == "GLARE" && entry["targets"].include?(0) }
        if move
          glare_ids[current_battle] = true
          target = 0 # Legal ally target: exercise actual paralysis carry.
        end
      elsif host && grass && own_battler && own_battler["status"] == "PARALYSIS" && !switched_ids[current_battle] && !options["switches"].empty?
        switched_ids[current_battle] = true
        next {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
      end
      move ||= moves.find { |entry| entry["id"] == (grass ? "ICEBEAM" : "SURF") }
      move ||= moves.find { |entry| %w[ICEBEAM SHADOWBALL].include?(entry["id"]) }
      move ||= moves.first
      if move
        target ||= move["targets"].include?(1) ? 1 : move["targets"].first
        {"action" => "move", "move_index" => move["index"], "target" => target}
      else
        {"action" => "forced"}
      end
    end
  end

  KIFMultiplayer.with_ui_fonts do
    if role != "viewer"
      create_route = lambda do |prefix|
        if host
          room = client.request("POST", "/v1/rooms", {"name" => "Native route #{prefix}", "mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => "normal", "compatibility" => compatibility})["room"]
          write.call("#{prefix}_room_code" => room["code"])
        else
          peer = wait_role.call("host", "#{prefix}_room_code")
          room = client.request("POST", "/v1/rooms/#{peer["#{prefix}_room_code"]}/join", {"compatibility" => compatibility})["room"]
        end
        client.room_code = room["code"]
        path = "/v1/rooms/#{room['code']}"
        client.request("POST", path + "/team", {"candidates" => $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }, "selected" => [0, 1, 2]})
        test.wait(client, "two selected #{prefix}") do
          members = client.request("GET", path)["room"]["members"]
          members.length == 2 && members.all? { |member| member["selected_count"] == 3 }
        end
        if host
          route = client.request("POST", "/v1/dungeons", {"room_code" => room["code"]})["dungeon"]
          write.call("#{prefix}_route_id" => route["id"])
        else
          peer = wait_role.call("host", "#{prefix}_route_id")
          route = client.request("GET", "/v1/dungeons/#{peer["#{prefix}_route_id"]}")["dungeon"]
        end
        route
      end

      unless fault_only
      route = create_route.call("main")
      session = KIFMultiplayer::DungeonSession.new(client, route["id"])
      completed = session.play(true)
      check.call(completed["status"] == "completed", "production DungeonSession completes four real battles and rest")
      history = completed.fetch("history")
      check.call(history.map { |entry| entry["node_index"] } == [0, 1, 2, 4], "fixed node order and four unique settlements")
      check.call(history.map { |entry| entry["battle_id"] }.uniq.length == 4 && history.all? { |entry| entry["result"]["coop_outcome"] == "victory" }, "all four actual engine outcomes are shared victories")
      check.call(history[1]["pre_state"] == history[0]["post_state"] && history[2]["pre_state"] == history[1]["post_state"], "all six HP PP status and item values carry exactly between encounters")
      previous_items = history[2]["post_state"].transform_values { |party| party.map { |value| value["item"] } }
      rest = history[3]["pre_state"]
      check.call(rest.all? { |owner, party| party.all? { |value| value["hp"] == value["totalhp"] && value["pp"] == value["total_pp"] && value["status"] == "NONE" } && party.map { |value| value["item"] } == previous_items[owner] }, "rest heals temporary HP PP status without replacing consumed items")
      main_host_id = completed["host_id"]
      check.call(history[0]["post_state"][main_host_id][0]["item"].nil?, "real Power Herb consumed before authoritative node commit")
      check.call(history[1]["pre_state"][main_host_id][0]["status"] == "PARALYSIS", "real ally Glare paralysis persists into next node")
      check.call(history.any? { |entry| entry["post_state"].values.flatten.any? { |value| value["pp"] != value["total_pp"] } }, "real move PP consumption recorded")
      if host
        check.call(engine_ids.length == 4, "four native authority engines ran")
        check.call(history.drop(1).all? { |entry| first_states.fetch(entry["battle_id"]).fetch("team_states") == entry["pre_state"] }, "next real engines load exact server-carried party state")
      else
        check.call(native_ids.length == 4 && fallback.empty? && native_events["move"] > 0, "native guest renders all four battles without fallback")
      end
      medal = session.claim
      check.call(medal == session.claim && rewards.any? { |reward| reward["id"] == medal["id"] }, "final medal claim is unique and repeatable")
      check_globals.call("completed route")
      write.call("stage" => "main_complete", "main_done" => true, "completed_route" => completed, "main_medal" => medal, "native_events" => native_events)
      wait_role.call(host ? "guest" : "host", "main_done")

      final_battle_id = history.last["battle_id"]
      if host
        replay = client.request("POST", "/v1/replays", {"battle_id" => final_battle_id})["replay"]
        client.request("POST", "/v1/replays/#{replay['id']}/consent", {"consent" => true})
        write.call("replay_id" => replay["id"])
        wait_role.call("guest", "replay_consented")
        client.request("POST", "/v1/replays/#{replay['id']}/publish", {"visibility" => "unlisted"})
        write.call("stage" => "replay_published", "replay_published" => true, "replay_result" => history.last["result"])
      else
        peer = wait_role.call("host", "replay_id")
        replay = {"id" => peer["replay_id"]}
        client.request("POST", "/v1/replays/#{replay['id']}/consent", {"consent" => true})
        write.call("replay_consented" => true)
        wait_role.call("host", "replay_published")
      end
      end
    else
      peer = wait_role.call("host", "replay_published", 900)
      replay = {"id" => peer["replay_id"]}
    end

    unless fault_only
    read_request = "native_replay_#{role}_#{KIFMultiplayer.operation_id}"
    replay_path = "/v1/replays/#{replay['id']}"
    downloaded = client.request("POST", replay_path + "/download", {"compatibility" => compatibility, "request_id" => read_request})["replay"]
    check.call(role == "viewer" ? !downloaded["players"].include?(client.player_id) : downloaded["players"].include?(client.player_id), "replay access uses intended participant or independent viewer identity")
    before_frames = replay_frames
    result = KIFMultiplayer.play_replay(client, downloaded, false)
    gc_checkpoint.call("replay_returned")
    check.call(result == read_role.call("host")["replay_result"], "real recorded replay reaches identical final result")
    check.call(replay_frames - before_frames == downloaded["data"]["updates"].length, "every authoritative replay frame presented")
    check_globals.call("replay")
    write.call("replay_done" => true, "replay_frames" => replay_frames, "replay_final_result" => result)
    if host
      wait_role.call("guest", "replay_done")
      wait_role.call("viewer", "replay_done")
      client.request("POST", replay_path + "/unpublish", {})
      write.call("replay_unpublished" => true)
    else
      wait_role.call("host", "replay_unpublished")
    end
    blocked = false
    begin
      client.request("POST", replay_path + "/download", {"compatibility" => compatibility, "request_id" => read_request})
    rescue KIFMultiplayer::Error => error
      blocked = %w[replay_private replay_unpublished].include?(error.code)
    end
    check.call(blocked, "unpublish blocks original download request ID instead of returning cached data")
    write.call("replay_revocation_checked" => true)
    end

    if role != "viewer"
      unless fault_only
        wait_role.call(host ? "guest" : "host", "replay_revocation_checked")
        wait_role.call("viewer", "replay_revocation_checked")
      end
      fault_route = create_route.call("fault")
      fault = KIFMultiplayer::DungeonSession.new(client, fault_route["id"])
      fault.fetch
      fault.mutate("ready", {"ready" => true})
      test.wait(client, "fault node start") { fault.fetch if fault.fetch["status"] == "battle" }
      fault_battle_id = fault.dungeon["battle_id"]
      battle = client.request("GET", "/v1/battles/#{fault_battle_id}")["battle"]
      KIFMultiplayer.run_boss(client, {"code" => fault_route["room_code"]}, battle)
      check_globals.call("pre-restart native node")
      if host
        wait_role.call("guest", "fault_guest_paused")
        finished = client.request("GET", "/v1/battles/#{fault_battle_id}")["battle"]
        check.call(finished["status"] == "finished" && finished["result"]["coop_outcome"] == "victory", "fault point is after real committed victory")
        check.call(finished["state"]["team_states"] == finished["result"]["team_states"], "final result and full bench state committed together")
        write.call("stage" => "fault_wait_restart", "fault_battle_id" => fault_battle_id, "fault_state" => finished["state"]["team_states"], "fault_result" => finished["result"])
      else
        write.call("stage" => "fault_pause", "fault_guest_paused" => true)
      end
      restart = test.wait(client, "actual service restart", 180) { test.read(base + ".service-restarted.json") }
      if host
        stored = client.request("GET", "/v1/battles/#{fault_battle_id}")["battle"]
        check.call(stored["status"] == "finished" && stored["result"] == own["fault_result"], "service restart keeps normal victory unchanged")
        fault.fetch
        advanced = fault.mutate("advance", {"battle_id" => fault_battle_id})
        check.call(advanced["node_index"] == 1 && advanced["team_states"] == own["fault_state"] && !advanced["retry_used"], "normal victory resumes from authority without supplied state or retry")
        write.call("fault_advanced" => true, "fault_recovered" => advanced)
        fault.mutate("abandon")
        write.call("fault_host_vote" => true)
        test.wait(client, "second abandonment vote") { fault.fetch if fault.fetch["status"] == "abandoned" }
      else
        peer = wait_role.call("host", "fault_advanced")
        current = fault.fetch
        check.call(current["node_index"] == 1 && current["team_states"] == peer["fault_state"], "remote client sees restored bench state after actual service restart")
        wait_role.call("host", "fault_host_vote")
        abandoned = fault.mutate("abandon")
        check.call(abandoned["status"] == "abandoned", "both real identities confirm ending the recovery fixture")
      end
      check_globals.call("post-restart recovery")
      write.call("service_restart_verified" => true, "service_restart" => restart, "final_fault_route" => fault.fetch)
    end
    check.call(fallback.empty?, "no native guest visual fallback occurred")
    check_globals.call("final")
    write.call("stage" => "finished", "finished" => true, "checks" => checks, "final_digest" => test.digest(originals), "native_events" => native_events,
               "actual_scene" => "Scene_Map", "world_callbacks" => world_callbacks, "manual_replay_windows" => true)
    test.log("DUNGEON_REPLAY_NATIVE_PASS role=#{role} checks=#{checks} pid=#{Process.pid} player=#{client.player_id}")
    native_pass = true
  end
rescue Exception => error
  message = "#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}"
  STDERR.puts("DUNGEON_REPLAY_NATIVE_FAIL #{message}")
  STDERR.flush
  begin
    KIFMultiplayerFeatureTest.log("DUNGEON_REPLAY_NATIVE_FAIL #{message}") if defined?(KIFMultiplayerFeatureTest)
    write.call("stage" => "failed", "error" => message) if defined?(write) && write
  rescue Exception => reporting_error
    STDERR.puts("DUNGEON_REPLAY_REPORT_FAILED #{reporting_error.class}: #{reporting_error.message}")
    STDERR.flush
  end
ensure
  if defined?(KIFMultiplayer)
    KIFMultiplayer.battle_controller = nil
    KIFMultiplayer.battle_observer = nil
  end
  exit!(defined?(native_pass) && native_pass ? 0 : 1)
end
