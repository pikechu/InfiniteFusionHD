# Real native host/guest plus separate same-identity contender and restarted
# reader. The PowerShell coordinator terminates the actual authority process.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  profile_name = ENV.fetch("KIF_MULTIPLAYER_PROFILE")
  role = %w[impostor reader guest].find { |value| profile_name.end_with?("-#{value}") } || "host"
  base, directory = ENV.fetch("KIF_MULTIPLAYER_SCENARIO"), ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  own = {"pid" => Process.pid, "role" => role, "stage" => "boot"}
  client = nil
  write = lambda do |values|
    own.merge!(values)
    retries = 0
    begin
      test.marker(base + ".#{role}.json", own)
    rescue Errno::EACCES
      retries += 1
      raise if retries > 30
      sleep(0.03)
      retry
    end
  end
  wait_peer = lambda do |peer, key|
    test.wait(client, "#{peer}.#{key}", 240) do
      value = test.read(base + ".#{peer}.json")
      raise "Peer failed: #{peer}" if value && value["stage"] == "failed"
      value if value && value[key]
    end
  end
  write.call({})
  profile = KIFMultiplayer::Profile.new
  host = nil
  if %w[impostor reader].include?(role)
    # Copy only the deliberately independent host test profile. Credentials
    # stay in profile files and are never written to coordinator/log output.
    host = wait_peer.call("host", "killable")
    profile.data.replace(KIFMultiplayer::WireJSON.parse(File.binread(host["profile_path"])))
    profile.save
  end
  backend = KIFMultiplayer::HTTPTransport.new
  paths = []
  transport = Object.new
  transport.define_singleton_method(:validate_url) { |url| backend.validate_url(url) }
  transport.define_singleton_method(:call) do |method, url, body, token, timeout|
    paths << [method, url.sub(/\Ahttps?:\/\/[^\/]+/, "")]
    backend.call(method, url, body, token, timeout)
  end
  client = KIFMultiplayer::Client.new(profile, transport)
  client.connect("Authority review #{role}")
  compatibility = client.compatibility
  KIFMultiplayer.battle_controller = proc { |_state, _id| raise "Reader/contender must never execute combat" }
  if %w[impostor reader].include?(role)
    battle_path = "/v1/battles/#{host['battle_id']}"
    battle = client.request("GET", battle_path)["battle"]
    test.check(battle["host_id"] == client.player_id, "#{role}: exact original host identity restored")
    test.check((battle.keys & %w[authority_id authority_last_seen]).empty?, "#{role}: authority lease is not disclosed")
    if role == "impostor"
      session = KIFMultiplayer::BossSession.new(client, battle)
      begin
        session.claim_authority
        raise "Second process acquired an already-owned authority"
      rescue KIFMultiplayer::Error => error
        raise unless error.code == "authority_conflict"
      end
      session.abort("authority_unrecoverable")
      begin
        KIFMultiplayer.run_boss(client, {"code" => host["room_code"]}, battle)
        raise "Second process reconstructed an in-progress host engine"
      rescue KIFMultiplayer::BattleError
        # It may query the original result later, never abort another engine.
      end
      current = client.request("GET", battle_path)["battle"]
      test.check(current["status"] == "active" && !paths.any? { |method, path| method == "POST" && path.end_with?("/abort") }, "contender cannot terminate the first live engine")
      write.call("stage" => "passed", "passed" => true, "battle_id" => battle["id"], "request_paths" => paths)
    else
      started = KIFMultiplayer.monotonic
      reads = 0
      loop do
        battle = client.request("GET", battle_path)["battle"]
        reads += 1
        break if battle["phase"] == "finished"
        raise "Plain host reads kept the dead authority alive" if KIFMultiplayer.monotonic - started > 100
        deadline = KIFMultiplayer.monotonic + 0.5
        client.pump while KIFMultiplayer.monotonic < deadline
      end
      elapsed = KIFMultiplayer.monotonic - started
      test.check(battle.dig("result", "abnormal") && elapsed >= 45, "dead real authority expires under cumulative budget despite continuous host GET")
      test.check(!paths.any? { |method, path| method == "POST" && (path.end_with?("/abort") || path.end_with?("/heartbeat")) }, "restarted reader neither aborts nor impersonates an engine heartbeat")
      test.check(KIFMultiplayer.run_boss(client, {"code" => host["room_code"]}, battle) == 0, "restarted host can display durable abnormal terminal result")
      test.check(Digest::SHA256.hexdigest(File.binread(host["save_path"])) == host["save_sha256"], "terminated authority's independent original disk save unchanged")
      write.call("stage" => "passed", "passed" => true, "reads" => reads, "elapsed" => elapsed, "result" => battle["result"], "request_paths" => paths)
    end
  else
    $Trainer.party = [:PALKIA, :KYOGRE, :LUGIA].map { |species| test.pokemon(species, [:SURF, :PROTECT, :ICEBEAM, :REST]) }
    $Trainer.save_slot = "Authority restart #{role}"
    writer = KIFMultiplayer::TradeSave.new
    test.check(writer.persist, "#{role}: isolated original save persisted")
    save_path = File.expand_path(writer.path)
    test.check(save_path.start_with?(File.expand_path(directory) + "/"), "#{role}: only independent test save used")
    save_sha = Digest::SHA256.hexdigest(File.binread(save_path))
    original_globals, original_digest = test.globals, test.digest
    team = $Trainer.party.map { |pokemon| KIFMultiplayer::Snapshot.export(pokemon) }
    if role == "host"
      room = client.request("POST", "/v1/rooms", {"mode" => "coop_boss", "name" => "Authority process lifetime", "compatibility" => compatibility})["room"]
      write.call("room_code" => room["code"], "profile_path" => File.expand_path(profile.path), "save_path" => save_path, "save_sha256" => save_sha)
    else
      host = wait_peer.call("host", "room_code")
      room = client.request("POST", "/v1/rooms/#{host['room_code']}/join", {"compatibility" => compatibility})["room"]
    end
    room_path = "/v1/rooms/#{room['code']}"
    client.request("POST", room_path + "/team", {"candidates" => team, "selected" => [0, 1, 2]})
    write.call("team_submitted" => true)
    wait_peer.call(role == "host" ? "guest" : "host", "team_submitted")
    client.request("POST", room_path + "/ready", {"ready" => true})
    original_trigger, next_use = Input.method(:trigger?), KIFMultiplayer.monotonic
    Input.define_singleton_method(:trigger?) do |button|
      if button == Input::USE && KIFMultiplayer.monotonic >= next_use
        next_use = KIFMultiplayer.monotonic + 0.18
        true
      else
        original_trigger.call(button)
      end
    end
    KIFMultiplayer.battle_controller = proc do |state, id|
      if role == "host"
        write.call("killable" => true, "stage" => "engine_running", "battle_id" => own["battle_id"])
        deadline = Time.now + 240
        client.pump while Time.now < deadline
        raise "Coordinator did not terminate the real authority process"
      end
      move = state.fetch("actions").fetch(id).fetch("moves").find { |candidate| candidate["id"] == "PROTECT" }
      {"action" => "move", "move_index" => move["index"], "target" => move["targets"].first}
    end
    if role == "host"
      test.wait(client, "both real clients ready") do
        candidate = client.request("GET", room_path)["room"]
        candidate if candidate["members"].length == 2 && candidate["members"].all? { |member| member["ready"] }
      end
      response = client.request("POST", room_path + "/start", {})
      battle_id = response["battle_id"] || response.dig("room", "battle_id")
      write.call("battle_id" => battle_id)
    else
      battle_id = wait_peer.call("host", "battle_id")["battle_id"]
    end
    battle = client.request("GET", "/v1/battles/#{battle_id}")["battle"]
    decision = KIFMultiplayer.run_boss(client, room, battle)
    test.check(role == "guest" && decision == 0, "guest observes original engine process death as abnormal")
    test.check(test.digest(original_globals) == original_digest && original_globals.each_with_index.all? { |value, i| value.equal?(test.globals[i]) }, "guest original save globals restored")
    test.check(Digest::SHA256.hexdigest(File.binread(save_path)) == save_sha, "guest original disk save unchanged")
    write.call("stage" => "passed", "passed" => true, "decision" => decision, "save_path" => save_path, "save_sha256" => save_sha)
  end
  test.log("AUTHORITY_RESTART_NATIVE_PASS role=#{role}")
  passed = true
rescue Exception => error
  $kif_test_log.call("AUTHORITY_RESTART_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if $kif_test_log
  write.call("stage" => "failed", "error" => "#{error.class}: #{error.message}") if defined?(write) && write
ensure
  exit!(passed ? 0 : 1)
end
