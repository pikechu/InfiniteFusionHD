begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  success = false
  # Only explicit test input is automated; use production scenes and combat.
  original_trigger = Input.method(:trigger?)
  next_auto_use = KIFMultiplayer.monotonic
  Input.define_singleton_method(:trigger?) do |button|
    if button == Input::USE && KIFMultiplayer.monotonic >= next_auto_use
      next_auto_use = KIFMultiplayer.monotonic + 0.2
      true
    else
      original_trigger.call(button)
    end
  end
  host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
  client = KIFMultiplayer::Client.new
  test.check(client.transport.backend == :core_socket, "V2_PRODUCTION_CORE_SOCKET")
  client.connect($Trainer.name)
  test.log("IDENTITY id=#{client.player_id} role=#{host ? 'host' : 'guest'}")
  compatibility = client.compatibility
  scenario = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
  test.wait(client, "scenario parent") { File.directory?(File.dirname(scenario)) }
  own_species = host ? [:KYOGRE, :BLASTOISE, :LAPRAS] : [:STARMIE, :VAPOREON, :SLOWBRO]
  $Trainer.party = own_species.map { |species| test.pokemon(species, [:SURF, :HELPINGHAND, :HEALPULSE, :THUNDERBOLT]) }
  baseline = test.digest
  original_objects = test.globals
  snapshots = $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }
  if host
    room = client.request("POST", "/v1/rooms", {"name" => "V2 real Boss", "mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => "normal", "compatibility" => compatibility})["room"]
    test.marker(scenario, {"room" => room["code"]})
  else
    info = test.wait(client, "host room") { test.read(scenario) }
    room = client.request("POST", "/v1/rooms/#{info['room']}/join", {"compatibility" => compatibility})["room"]
  end
  base = "/v1/rooms/#{room['code']}"
  client.request("POST", base + "/team", {"candidates" => snapshots, "selected" => [0, 1, 2]})
  test.wait(client, "Boss teams") do
    members = client.request("GET", base)["room"]["members"]
    members.length == 2 && members.all? { |m| m["selected_count"] == 3 }
  end
  client.request("POST", base + "/ready", {"ready" => true})
  if host
    test.wait(client, "Boss readiness") { client.request("GET", base)["room"]["members"].all? { |m| m["ready"] } }
    battle_id = client.request("POST", base + "/start")["battle_id"]
  else
    battle_id = test.wait(client, "Boss started") do
      r = client.request("GET", base)["room"]
      r["status"] == "playing" && r["battle_id"]
    end
  end
  battle = client.request("GET", "/v1/battles/#{battle_id}")["battle"]
  action_count = 0
  KIFMultiplayer.battle_observer = proc do |event, payload|
    test.log("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}")
    if host && event == "authority_state"
      bitmap = Graphics.snap_to_bitmap
      bitmap.to_file(File.join($kif_test_directory, "boss-state.png"))
      bitmap.dispose
    end
  end
  KIFMultiplayer.battle_controller = proc do |state, id|
    options = state.fetch("actions", {})[id] || {}
    if !(state["phase_owner_ids"] || []).include?(id)
      action = {"action" => "wait"}
    elsif state["kind"] == "switch"
      action = {"action" => "switch", "party_index" => options.fetch("switches").first.fetch("party_index")}
    else
      action_count += 1
      if !host && action_count == 2 && !options["switches"].empty?
        action = {"action" => "switch", "party_index" => options["switches"].first["party_index"]}
      else
        desired = !host && action_count == 1 ? "HELPINGHAND" : "SURF"
        move = options["moves"].find { |m| m["id"] == desired } || options["moves"].first
        targets = move && move["targets"] || [-1]
        target = desired == "HELPINGHAND" && targets.include?(0) ? 0 : targets.first
        action = move ? {"action" => "move", "move_index" => move["index"], "target" => target} : {"action" => "forced"}
      end
    end
    test.log("BOSS_COMMAND #{KIFMultiplayer::WireJSON.dump(action)}")
    action
  end
  decision = KIFMultiplayer.run_boss(client, room, battle)
  final = client.request("GET", "/v1/battles/#{battle_id}")["battle"]
  test.check(final["phase"] == "finished" && decision == 1 && final["result"]["coop_outcome"] == "victory", "BOSS_REAL_VICTORY")
  reward_a = client.request("POST", "/v1/battles/#{battle_id}/claim", {})["reward"]
  reward_b = client.request("POST", "/v1/battles/#{battle_id}/claim", {})["reward"]
  test.check(reward_a["id"] == reward_b["id"], "BOSS_REWARD_UNIQUE")
  test.check(test.digest == baseline && test.globals.each_with_index.all? { |g, i| g.equal?(original_objects[i]) }, "BOSS_ORIGINAL_GLOBALS_UNCHANGED")
  test.log("BOSS_RESULT #{KIFMultiplayer::WireJSON.dump(final['result'])}")

  # The owner stops polling while the other process challenges its fixed AI.
  if host
    weak = [:MAGIKARP, :RATTATA, :PIDGEY].map { |species| KIFMultiplayer::Snapshot.export(test.pokemon(species, [:TACKLE])) }
    body = {"name" => "Offline fixture Gym", "description" => "Real AI fixed version", "intro" => "Test challenge", "team" => weak, "compatibility" => compatibility}
    gym = client.request("POST", "/v1/gyms", body)["gym"]
    test.marker(scenario + ".gym", {"code" => gym["code"]})
    test.wait(client, "frozen Gym challenge") { test.read(scenario + ".gym-started") }
    body["team"] = snapshots
    updated = client.request("POST", "/v1/gyms/#{gym['code']}/publish", body)["gym"]
    test.check(updated["version"] == 2, "GYM_VERSION_UPDATED")
    client.request("POST", "/v1/gyms/#{gym['code']}/close", {})
    client.disconnect
    test.marker(scenario + ".gym-owner-offline", {"offline" => true})
    test.wait(client, "offline challenger done", 300) { test.read(scenario + ".gym-done") }
    client.connect($Trainer.name)
  else
    info = test.wait(client, "published Gym") { test.read(scenario + ".gym") }
    challenge = client.request("POST", "/v1/gyms/#{info['code']}/challenge", {"compatibility" => compatibility, "team" => snapshots})["challenge"]
    test.marker(scenario + ".gym-started", {"challenge" => challenge["id"]})
    test.wait(client, "Gym owner offline") { test.read(scenario + ".gym-owner-offline") }
    test.check(challenge["gym_version"] == 1 && challenge["defender_team"].first["species"] == "MAGIKARP", "GYM_FROZEN_VERSION")
    KIFMultiplayer.gym_observer = proc { |event, payload| test.log("EVENT #{event} #{KIFMultiplayer::WireJSON.dump(payload)}") }
    KIFMultiplayer.gym_controller = proc do |state|
      if state["kind"] == "switch"
        {"action" => "switch", "party_index" => state["switches"].first["party_index"]}
      else
        move = state["moves"].find { |m| m["id"] == "SURF" } || state["moves"].first
        move ? {"action" => "move", "move_index" => move["index"]} : {"action" => "forced"}
      end
    end
    report = KIFMultiplayer.run_gym_challenge(client, challenge)
    test.check(report["challenge"].dig("result", "outcome") == "win", "GYM_REAL_AI_WIN_WHILE_OWNER_OFFLINE")
    repeated = client.request("POST", "/v1/gym-challenges/#{challenge['id']}/claim", {})["reward"]
    test.check(repeated["id"] == report["reward"]["id"], "GYM_REWARD_UNIQUE")
    test.check(test.digest == baseline, "GYM_ORIGINAL_GLOBALS_UNCHANGED")
    test.marker(scenario + ".gym-done", {"result" => "win"})
  end

  # A real exchange is explicitly saved in the isolated File A; it intentionally
  # replaces the offered individual while preserving every agreed field.
  $Trainer.save_slot = "File A"
  store = KIFMultiplayer::TradeSave.new
  store.persist
  session = KIFMultiplayer::TradeSession.new(client, store)
  if host
    trade = session.create
    test.marker(scenario + ".trade", {"code" => trade["code"]})
  else
    info = test.wait(client, "trade created") { test.read(scenario + ".trade") }
    trade = session.join(info["code"])
  end
  outgoing = $Trainer.party[0]
  outgoing_snapshot = KIFMultiplayer::TradeCodec.export(outgoing)
  test.log("TRADE_OUTGOING #{KIFMultiplayer::WireJSON.dump(outgoing_snapshot)}")
  session.offer(trade["code"], outgoing)
  offered = test.wait(client, "both trade offers") do
    t = session.get(trade["code"])
    t["offers"].length == 2 && t
  end
  partner_snapshot = offered["offers"].find { |id, _| id != client.player_id }[1]["snapshot"]
  session.confirm(offered)
  test.wait(client, "committed trade") { t = session.get(trade["code"]); %w[committed completed].include?(t["status"]) && t }
  session.recover
  test.check(KIFMultiplayer::TradeCodec.export($Trainer.party[0]) == partner_snapshot, "TRADE_COMPLETE_INDIVIDUAL_FIELDS")
  party_digest = test.digest($Trainer.party)
  session.recover
  test.check(test.digest($Trainer.party) == party_digest, "TRADE_REPEAT_RECEIVE_NO_DUPLICATE")
  saved = SaveData.read_from_file(store.path)
  saved_player = saved[:kuray_player] || saved[:player]
  test.check(KIFMultiplayer::TradeCodec.export(saved_player.party[0]) == partner_snapshot, "TRADE_REAL_ATOMIC_SAVE_RELOAD")
  test.check(saved_player.instance_variable_get(:@kif_multiplayer_trade_applied).length == 1, "TRADE_APPLIED_MARKER_DURABLE")
  test.log("FEATURE_SMOKE_PASS boss=#{battle_id} trade=#{trade['code']} role=#{host ? 'host' : 'guest'}")
  success = true
rescue Exception => error
  if $kif_test_log
    $kif_test_log.call("FEATURE_SMOKE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  end
ensure
  exit!(success ? 0 : 1)
end
