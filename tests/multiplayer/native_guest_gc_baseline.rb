# Resource diagnosis only: replay real locally captured public visual batches
# through the native guest presenter, without HTTP threads or combat execution.
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  result_path = File.join(directory, "native-guest-baseline.json")
  with_http = ENV["KIF_NATIVE_GUEST_HTTP"] == "1"
  http_mode = ENV.fetch("KIF_NATIVE_HTTP_MODE", "production")
  result = {"pid" => Process.pid, "ruby" => RUBY_VERSION, "with_http" => with_http, "http_mode" => http_mode, "http_requests" => 0, "rounds" => [], "finished" => false}
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
  fixture = KIFMultiplayer::WireJSON.parse(File.binread(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  $PokemonSystem.battlescene = 0
  $GameSpeed = 2
  original_trigger = Input.method(:trigger?)
  next_use = KIFMultiplayer.monotonic
  Input.define_singleton_method(:trigger?) do |button|
    if button == Input::USE && KIFMultiplayer.monotonic >= next_use
      next_use = KIFMultiplayer.monotonic + 0.2
      true
    else
      original_trigger.call(button)
    end
  end
  $Trainer.party = [:PALKIA, :KYOGRE, :LUGIA].map { |species| test.pokemon(species, [:SURF, :ICEBEAM, :SHADOWBALL, :PROTECT]) }
  original_globals = test.globals
  original_digest = test.digest(original_globals)
  forbidden_transport = Object.new
  def forbidden_transport.call(*); raise "Diagnostic forbids all network calls"; end
  transport_override = with_http ? nil : forbidden_transport
  if with_http && http_mode == "socket"
    load "tests/multiplayer/native_socket_transport.rb"
    transport_override = NativeSocketDiagnosticTransport.new
  end
  if with_http && http_mode == "curl"
    transport_override = Object.new
    def transport_override.call(method, url, body, token, timeout)
      quote = lambda do |value|
        escaped = value.to_s.gsub(/[\\"\r\n]/) { |char| {"\\" => "\\\\", '"' => '\\"', "\r" => "\\r", "\n" => "\\n"}[char] }
        '"' + escaped + '"'
      end
      marker = "\n__KIF_DIAGNOSTIC_HTTP_STATUS__"
      config = ["silent", "show-error", "url = #{quote.call(url)}", "request = #{quote.call(method)}", "connect-timeout = #{quote.call(timeout)}", "max-time = #{quote.call(timeout)}", "write-out = #{quote.call(marker + '%{http_code}')}"]
      headers = {"Accept" => "application/json", "Content-Type" => "application/json"}
      headers["Authorization"] = "Bearer #{token}" if token
      headers.each { |key, value| config << "header = #{quote.call(key + ': ' + value)}" }
      config << "data-binary = #{quote.call(KIFMultiplayer::WireJSON.dump(body))}" unless method == "GET"
      executable = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32", "curl.exe")
      output = IO.popen([executable, "--config", "-"], "r+") do |pipe|
        pipe.binmode
        pipe.write(config.join("\n") + "\n")
        pipe.close_write
        pipe.read
      end
      response_body, separator, status = output.rpartition(marker)
      raise "Diagnostic curl returned no HTTP status" unless separator == marker && status =~ /\A\d{3}\z/
      {:status => status.to_i, :body => response_body}
    rescue StandardError => error
      STDERR.puts("DIAGNOSTIC_CURL_FAILURE #{error.class}: #{error.message}")
      STDERR.flush
      raise
    end
  end
  client = KIFMultiplayer::Client.new(nil, transport_override)
  if with_http && %w[join synchronous].include?(http_mode)
    # Deliberately test-only: distinguish native adapter calls on the main
    # thread from an ordinary joined Ruby worker, without Thread#kill.
    client.define_singleton_method(:raw_request) do |method, request_path, body = {}, timeout = 8.0|
      response, failure = nil, nil
      if http_mode == "synchronous"
        response = transport.call(method, server + request_path, body, token, timeout)
      else
        worker = Thread.new do
          begin
            response = transport.call(method, server + request_path, body, token, timeout)
          rescue StandardError => error
            failure = error
          end
        end
        deadline = KIFMultiplayer.monotonic + timeout
        while worker.alive?
          raise "Diagnostic worker timed out" if KIFMultiplayer.monotonic >= deadline
          pump
          Thread.pass
        end
        worker.join
        raise failure if failure
      end
      status = response[:status] || response["status"]
      parsed = KIFMultiplayer::WireJSON.parse((response[:body] || response["body"]).to_s)
      raise "Diagnostic HTTP failure: #{status}" unless status.to_i.between?(200, 299) && parsed["ok"] == true
      parsed
    end
  end
  if with_http
    client.connect("Native visual GC diagnosis")
    room = client.request("POST", "/v1/rooms", {"mode" => "coop_boss", "boss_id" => "training-golem", "difficulty" => "normal", "name" => "Own native diagnostic room", "compatibility" => client.compatibility})["room"]
    path = "/v1/rooms/#{room['code']}"
    team = fixture.first["initial_teams"][fixture.first["host_id"]]
    client.request("POST", path + "/team", {"candidates" => team, "selected" => [0, 1, 2]})
  end
  KIFMultiplayer.battle_controller = proc { raise "Observer cannot choose combat" }
  KIFMultiplayer.battle_observer = proc do |event, payload|
    raise "Native guest fallback: #{payload.inspect}" if event == "guest_visual_fallback"
    test.log("NATIVE_GUEST_EVENT #{event}") if %w[guest_native_started guest_visual_applied].include?(event)
  end
  KIFMultiplayer.with_ui_fonts do
    (fixture + fixture).each_with_index do |battle, index|
      test.log("NATIVE_GUEST_BEGIN round=#{index} gc=#{GC.stat[:count]}")
      session = KIFMultiplayer::BossSession.new(client, battle)
      if with_http
        next_http, http_busy = KIFMultiplayer.monotonic, false
        session.define_singleton_method(:heartbeat) do |*|
          if !http_busy && KIFMultiplayer.monotonic >= next_http
            http_busy = true
            next_http = KIFMultiplayer.monotonic + 0.5
            begin
              client.request("GET", path)
              result["http_requests"] += 1
            ensure
              http_busy = false
            end
          end
        end
      else
        def session.heartbeat(*); end
      end
      KIFMultiplayer::GuestBattlePresenter.renderRecordedFrames(session, battle["updates"])
      test.check(test.digest(original_globals) == original_digest, "recorded native guest #{index} protects globals")
      result["rounds"] << {"index" => index, "battle_id" => battle["id"], "frames" => battle["updates"].length, "gc" => GC.stat[:count]}
      File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
      test.log("NATIVE_GUEST_END round=#{index} gc=#{GC.stat[:count]}")
    end
  end
  result["finished"] = true
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
  test.log("NATIVE_GUEST_ALL_PASS rounds=8 with_http=#{with_http} requests=#{result['http_requests']}")
rescue Exception => error
  message = "#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}"
  test.log("NATIVE_GUEST_FAIL #{message}") if defined?(test)
  result["error"] = message if defined?(result)
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result)) if defined?(result_path)
ensure
  exit!
end
