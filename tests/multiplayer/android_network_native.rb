# Explicit Android runtime network diagnostic. Loaded instead of game-smoke in
# a temporary diagnostic run; only its dedicated directory receives files.
begin
  root = File.join(ENV.fetch("KIF_ANDROID_FILES"), "diagnostics", "online-network")
  load "kif_android_preload.rb" # customScript bypasses the engine preload path
  load File.join(root, "000_Platform.rb")
  load File.join(root, "001_Client.rb")
  load File.join(root, "015_Transport.rb")
  load File.join(root, "020_AndroidNetwork.rb")
  config = KIFMultiplayer::WireJSON.parse(File.read(File.join(root, "config.json")))
  checks = []
  check = lambda { |value, name| raise "FAIL #{name}" unless value; checks << name; System.puts("ANDROID_NETWORK_CHECK #{name}") }
  check.call(System.is_android? && KIF::Platform.network_available?, "production adapter auto-installs on Android runtime")
  require "openssl"
  require "zlib"
  profile = KIFMultiplayer::Profile.new(File.join(root, "fixture-profile.json"))
  profile.server = config["server"]
  client = KIFMultiplayer::Client.new(profile)
  check.call(client.transport.backend == :platform, "production Android platform transport selected")
  health = client.request("GET", "/v1/health")
  check.call(health["protocol"] == KIFMultiplayer::PROTOCOL, "Android reaches remote coordination service")
  # No credential/session request is written to the economic operation journal.
  client.request("POST", "/v1/auth/register", {"username" => config["username"], "password" => "NativeAndroidFixture8", "nickname" => "安卓测试", "protocol" => KIFMultiplayer::PROTOCOL})
  login = client.request("POST", "/v1/auth/login", {"username" => config["username"], "password" => "NativeAndroidFixture8", "protocol" => KIFMultiplayer::PROTOCOL})
  profile.account.merge!("token" => login["token"], "identity" => login["identity"], "username" => config["username"])
  profile.save
  check.call(client.request("GET", "/v1/identity")["identity"]["nickname"] == "安卓测试", "registration login bearer token and Unicode identity work")
  sid = KIFMultiplayer.operation_id
  compat = {"protocol" => KIFMultiplayer::PROTOCOL, "game_version" => "network-probe", "data_hash" => "network-probe", "mods_hash" => "network-probe", "rules_version" => KIFMultiplayer::RULES_VERSION}
  client.request("POST", "/v1/cloud/open", {"session_id" => sid, "compatibility" => compat})
  json = KIFMultiplayer::WireJSON.dump({"fixture" => "中文跨端", "id" => 4294967295, "large" => [Random.new(123).bytes(160000)].pack("m0")})
  bytes = Zlib::Deflate.deflate(json)
  document = {"format" => "kif-save-json-v1", "game_version" => "network-probe", "payload" => [bytes].pack("m0"), "sha256" => KIFMultiplayer.file_digest(File.join(root, "001_Client.rb"))}
  document["sha256"] = Digest::SHA256.hexdigest(bytes)
  upload = {"session_id" => sid, "slot" => "file-a", "revision" => 0, "upload_id" => KIFMultiplayer.operation_id, "save" => document}
  client.request("POST", "/v1/cloud/upload", upload, 45.0)
  received = client.request("POST", "/v1/cloud/download", {"session_id" => sid, "slot" => "file-a"}, 45.0)
  check.call(received["revision"] == 1 && received["save"] == document && document["payload"].bytesize > 65536, "Android cloud upload and download exceed old 64 KiB bridge limit without truncation")
  client.request("POST", "/v1/world/join", {"session_id" => sid, "compatibility" => compat})
  position = {"map_id" => 1, "map_hash" => "a" * 64, "width" => 20, "height" => 20, "x" => 2, "y" => 3, "direction" => 6, "character_id" => 0, "moving" => false}
  client.request("POST", "/v1/world/sync", {"session_id" => sid, "seq" => 1, "after" => 0, "position" => position})
  %w[map world].each do |channel|
    client.request("POST", "/v1/chat/send", {"session_id" => sid, "client_id" => KIFMultiplayer.operation_id, "channel" => channel, "text" => "安卓#{channel}你好😀"})
  end
  world = client.request("POST", "/v1/world/sync", {"session_id" => sid, "seq" => 2, "after" => 0, "position" => position})["world"]
  check.call(world["messages"].map { |message| message["channel"] }.sort == %w[map world], "Android map presence and both chat channels work")
  check.call(!profile.account["pending"], "online traffic does not pollute economic journal")
  https = KIF::Platform.http_get("https://example.com")
  check.call(https[:status] == 200 && https[:body].include?("Example Domain"), "HTTPS verifies public certificate and hostname with Android system roots")
  untrusted = KIF::Platform.http_get(config["untrusted_https"])
  check.call(untrusted[:status] == 0 && untrusted[:error].to_s.start_with?("SSL"), "self-signed untrusted TLS certificate is rejected")
  begin
    task = KIFMultiplayer.network_worker { client.transport.call("GET", config["server"] + "/probe/slow", {}, nil, 0.2) }
    task.value
    raise "deadline was ignored"
  rescue KIFMultiplayer::Error => error
    check.call(error.code == "network_timeout", "Android socket enforces request deadlines")
  end
  client.request("POST", "/v1/cloud/close", {"session_id" => sid})
  report = {"passed" => true, "ruby" => RUBY_VERSION, "openssl" => OpenSSL::OPENSSL_VERSION, "checks" => checks}
  File.write(File.join(root, "result.json"), KIFMultiplayer::WireJSON.dump(report))
  System.puts("ANDROID_NETWORK_NATIVE_PASS checks=#{checks.length}")
rescue Exception => error
  report = {"passed" => false, "error" => "#{error.class}: #{error.message}", "details" => (error.respond_to?(:details) ? error.details : nil), "backtrace" => error.backtrace}
  File.write(File.join(root, "result.json"), KIFMultiplayer::WireJSON.dump(report)) if defined?(root) && defined?(KIFMultiplayer::WireJSON)
  System.puts("ANDROID_NETWORK_NATIVE_FAIL #{error.class}: #{error.message}")
end
loop { Graphics.update; Input.update }
