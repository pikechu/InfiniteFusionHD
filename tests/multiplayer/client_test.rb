# Run with a standalone Ruby, or as a real mkxp customScript. This suite only
# writes its isolated test directory and never loads the player's save.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
if defined?(System) && ENV["KIF_MULTIPLAYER_SAVE_DIR"]
  load "scripts/multiplayer/runtime-preload.rb"
end
load "Data/Scripts/054_Multiplayer/001_Client.rb"
test_directory = ENV["KIF_MULTIPLAYER_SAVE_DIR"] || File.join(root, "temp", "multiplayer", "client-unit")
missing_directories = []
current_directory = test_directory
until File.directory?(current_directory)
  missing_directories.unshift(current_directory)
  current_directory = File.dirname(current_directory)
end
missing_directories.each { |directory| Dir.mkdir(directory) }
test_log = File.open(File.join(test_directory, "client-test.log"), "w")
checks = 0
assert = lambda do |condition, description|
  raise "FAIL: #{description}" unless condition
  checks += 1
  test_log.puts("PASS #{description}")
  test_log.flush
end
reject = lambda do |description, &block|
  begin
    block.call
  rescue KIFMultiplayer::Error
    assert.call(true, description)
  else
    raise "FAIL accepted #{description}"
  end
end

begin
  json_probe = { "uint32" => 4294967295, "signed32_edge" => 3029697254,
                 "text" => "中文闪光 \"quoted\" \\path\nline\t\u0000 😀", "items" => [nil, false, true, -1, 1.25, 1.0e-10] }
  assert.call(KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(json_probe)) == json_probe, "JSON preserves full uint32 Unicode escapes arrays and floating point values")
  assert.call(KIFMultiplayer::WireJSON.parse('"\\ud83d\\ude00"') == "😀", "JSON surrogate pair decoded losslessly")
  reject.call("JSON duplicate keys rejected") { KIFMultiplayer::WireJSON.parse('{"x":1,"x":2}') }
  reject.call("JSON unpaired surrogate rejected") { KIFMultiplayer::WireJSON.parse('"\\ud800"') }
  reject.call("JSON trailing code rejected") { KIFMultiplayer::WireJSON.parse('{};system("bad")') }
  reject.call("JSON non-finite input rejected") { KIFMultiplayer::WireJSON.parse('1e999') }
  reject.call("JSON leading zero rejected") { KIFMultiplayer::WireJSON.parse('[01]') }
  reject.call("JSON excessive nesting rejected") { KIFMultiplayer::WireJSON.parse('[' * 40 + '0' + ']' * 40) }
  reject.call("JSON arbitrary objects rejected") { KIFMultiplayer::WireJSON.dump(Object.new) }
  reject.call("JSON NaN output rejected") { KIFMultiplayer::WireJSON.dump(Float::NAN) }
  unless defined?(GameData)
    module GameData
      class Registry
        IDS = %w[TESTMON HARDY OVERGROW TACKLE LEFTOVERS FIRE REDORB BLUEORB ULTRANECROZIUMZ]
        def self.exists?(id); IDS.include?(id.to_s); end
        def self.get(id); raise "Unknown ID" unless exists?(id); Struct.new(:id).new(id.to_sym); end
      end
      Species = Class.new(Registry)
      Species.const_set(:DATA, { :TESTMON => true })
      # Reproduce the real game's permissive Species.exists? fallback.
      Species.define_singleton_method(:exists?) { |id| true }
      Nature = Class.new(Registry)
      Ability = Class.new(Registry)
      Item = Class.new(Registry)
      Move = Class.new(Registry)
      Type = Class.new(Registry)
    end
  end
  NB_POKEMON = 501 unless defined?(NB_POKEMON)
  stat = KIFMultiplayer::Snapshot::STATS
  valid = {
    "version" => 1, "species" => "TESTMON", "level" => 42, "form" => 0,
    "name" => "PrivateNickname", "gender" => 1, "personal_id" => 123,
    "nature" => "HARDY", "nature_for_stats" => nil,
    "ability" => "OVERGROW", "ability_index" => 0, "ability2" => nil, "ability2_index" => nil,
    "item" => "LEFTOVERS", "moves" => [{ "id" => "TACKLE", "pp" => 7, "ppup" => 3 }],
    "iv" => stat.each_with_object({}) { |s, h| h[s] = 31 },
    "ev" => stat.each_with_object({}) { |s, h| h[s] = 0 },
    "iv_maxed" => stat.each_with_object({}) { |s, h| h[s] = false },
    "happiness" => 200, "shiny" => true, "hidden_power_type" => "FIRE",
    "appearance" => { "head_nickname" => "SecretFusionName", "head_shinyhue" => 137, "shinyKRS" => [0, 1, 2, 0, 1, 2, 0, 1, 2], "size_category" => "AVERAGE", "sprite_scale" => 1 },
    "owner" => { "id" => 321, "name" => "SecretOT", "gender" => 0, "language" => 2 }
  }
  copy = lambda { KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(valid)) }
  assert.call(KIFMultiplayer::Snapshot.validate(valid) == valid, "supported complete snapshot accepted")
  public_data = KIFMultiplayer::Snapshot.public_snapshot(valid)
  assert.call((public_data.keys & %w[name owner iv ev personal_id item nature]).empty?, "hidden individual and trainer fields excluded")
  assert.call(!public_data["appearance"].key?("head_nickname"), "hidden fusion head nickname excluded")
  assert.call(valid["appearance"]["head_nickname"] == "SecretFusionName", "public projection does not mutate original appearance")
  assert.call(public_data["appearance"]["head_shinyhue"] == 137 && public_data["shiny"], "custom shiny appearance preserved in public projection")
  visible = KIFMultiplayer::Snapshot.public_snapshot(valid, %w[name owner iv ev])
  assert.call(visible["owner"]["name"] == "SecretOT" && visible["appearance"].key?("head_nickname"), "explicit opt-in fields exposed")
  reject.call("unknown root field rejected") { KIFMultiplayer::Snapshot.validate(valid.merge("script" => "system('bad')")) }
  reject.call("unsupported species rejected") { KIFMultiplayer::Snapshot.validate(valid.merge("species" => "UNKNOWN")) }
  reject.call("out of range fusion component rejected") { KIFMultiplayer::Snapshot.validate(valid.merge("species" => "B502H1")) }
  reject.call("zero fusion component rejected") { KIFMultiplayer::Snapshot.validate(valid.merge("species" => "B1H0")) }
  assert.call(KIFMultiplayer::Snapshot.validate(valid.merge("species" => "B1H501"))["species"] == "B1H501", "supported fusion components accepted")
  reject.call("special form rejected before play") { KIFMultiplayer::Snapshot.validate(valid.merge("form" => 1)) }
  reject.call("automatic primal transformation item rejected before battle") { KIFMultiplayer::Snapshot.validate(valid.merge("item" => "REDORB")) }
  changed = copy.call; changed["ev"]["HP"] = 252; changed["ev"]["ATTACK"] = 252; changed["ev"]["SPEED"] = 8
  reject.call("EV overflow rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  changed = copy.call; changed["appearance"]["kuraycustomfile"] = "C:/secret.png"
  reject.call("arbitrary local resource paths rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  changed = copy.call; changed["appearance"]["spriteform_head"] = "../../secret"
  reject.call("sprite variant path traversal rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  changed = copy.call; changed["appearance"]["sprite_scale"] = 1000000
  reject.call("unbounded rendering scale rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  [{"shinyKRS" => true}, {"shinyKRS" => [0, 1, 2]}, {"head_shinyhue" => "abc"}, {"shinyR" => true}, {"body_shiny" => 1}, {"shinyKRS" => [0, 0, 0, 0, 0, 0, 0, 0, 99]}].each do |malformed|
    reject.call("render-incompatible appearance rejected #{malformed.keys.first}") { KIFMultiplayer::Snapshot.validate_appearance(malformed) }
  end
  changed = copy.call; changed["moves"][0]["ppup"] = 4
  reject.call("invalid PP Up rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  changed = copy.call; changed["owner"]["id"] = -1
  reject.call("invalid original trainer identity rejected") { KIFMultiplayer::Snapshot.validate(changed) }
  reject.call("server URL credentials rejected") { KIFMultiplayer.normalized_url("http://token@127.0.0.1:8765") }

  profile_path = File.join(test_directory, "profile.json")
  File.delete(profile_path) if File.file?(profile_path)
  profile = KIFMultiplayer::Profile.new(profile_path)
  profile.server = "http://127.0.0.1:8765"
  profile.account["token"] = "test-token-a"
  profile.save
  profile.server = "http://127.0.0.1:9876"
  assert.call(profile.account["token"].nil?, "server switch isolates authentication")
  profile.account["token"] = "test-token-b"
  profile.save
  profile.server = "http://127.0.0.1:8765"
  assert.call(profile.account["token"] == "test-token-a", "server return restores only matching identity")
  assert.call(KIFMultiplayer::Profile.new(profile_path).account["token"] == "test-token-a", "atomic profile persistence reloads identity")

  class ClientTestTransport
    attr_reader :calls
    def initialize(mode = :success)
      @calls, @mode = [], mode
    end
    def call(method, url, body, token, timeout)
      @calls << [method, url, body, token]
      if url.include?("/operations/")
        if @mode == :not_found
          return { :status => 404, :body => KIFMultiplayer::WireJSON.dump({ "ok" => false, "error" => { "code" => "operation_not_found", "message" => "not found" } }) }
        end
        data = { "ok" => true, "status" => "completed", "http_status" => 200, "response" => { "ok" => true, "room" => { "code" => "ABCDEF" } } }
      elsif @mode == :timeout
        sleep 0.2
        data = { "ok" => true }
      elsif @mode == :rejected
        return { :status => 403, :body => KIFMultiplayer::WireJSON.dump({ "ok" => false, "error" => { "code" => "not_host", "message" => "host only" } }) }
      else
        data = { "ok" => true, "room" => { "code" => "ABCDEF" } }
      end
      { :status => 200, :body => KIFMultiplayer::WireJSON.dump(data) }
    end
  end
  timeout_transport = ClientTestTransport.new(:timeout)
  client = KIFMultiplayer::Client.new(profile, timeout_transport)
  frames = 0
  client.wait_update = proc { frames += 1 }
  reject.call("network timeout reported without assuming failed mutation") do
    client.request("POST", "/v1/rooms", { "name" => "test" }, 0.04)
  end
  assert.call(frames > 0, "network wait pumps game updates")
  pending = profile.account["pending"]
  assert.call(pending && pending["body"]["request_id"], "uncertain mutation journal persisted")
  recovery_transport = ClientTestTransport.new
  recovered_client = KIFMultiplayer::Client.new(KIFMultiplayer::Profile.new(profile_path), recovery_transport)
  result = recovered_client.recover_pending
  assert.call(result["room"]["code"] == "ABCDEF", "operation query restores committed response")
  assert.call(recovery_transport.calls.length == 1 && recovery_transport.calls[0][0] == "GET", "recovery queries status before any resubmission")
  assert.call(!recovered_client.profile.account.key?("pending"), "completed operation journal cleared")

  recovered_client.profile.account["pending"] = pending
  recovered_client.profile.save
  retry_transport = ClientTestTransport.new(:not_found)
  retry_client = KIFMultiplayer::Client.new(recovered_client.profile, retry_transport)
  retry_client.recover_pending
  assert.call(retry_transport.calls.map(&:first) == %w[GET POST], "uncommitted operation queried then retried")
  assert.call(retry_transport.calls[1][2]["request_id"] == pending["body"]["request_id"], "retry reuses original operation identifier")

  rejected_client = KIFMultiplayer::Client.new(retry_client.profile, ClientTestTransport.new(:rejected))
  reject.call("HTTP authorization error returned") { rejected_client.request("POST", "/v1/rooms/ABCDEF/start") }
  assert.call(!rejected_client.profile.account.key?("pending"), "definitive rejection does not retain ambiguous journal")
  broken_read_transport = Object.new
  broken_read_calls = []
  broken_read_transport.define_singleton_method(:call) do |method, url, body, *_args|
    broken_read_calls << [method, url, body]
    { :status => 200, :body => "{" }
  end
  read_client = KIFMultiplayer::Client.new(retry_client.profile, broken_read_transport)
  reject.call("damaged replay read is rejected") { read_client.request("POST", "/v1/replays/replay_fixture/download", {"compatibility" => {}}) }
  assert.call(!read_client.profile.account["pending"], "damaged read cannot strand an economic operation journal")
  assert.call(broken_read_calls[0][2]["request_id"].is_a?(String), "pure POST read still carries protocol request identifier")
  read_client.profile.account["pending"] = {"method" => "POST", "path" => "/v1/replays/replay_fixture/download", "body" => {"request_id" => "old_download_read"}}
  read_client.profile.save
  assert.call(read_client.recover_pending.nil? && !read_client.profile.account["pending"], "legacy pending replay download is safely migrated")
  assert.call(broken_read_calls.length == 1, "legacy read migration does not repeat an unrecoverable response")
  require "digest/sha2"
  digest_fixture = File.join(test_directory, "digest-fixture.bin")
  digest_content = "binary\x00fixture\n" * 2048
  File.open(digest_fixture, "wb") { |file| file.write(digest_content) }
  assert.call(KIFMultiplayer.file_digest(digest_fixture) == Digest::SHA256.hexdigest(digest_content), "streamed real file SHA256 works without standard-library Digest.file")
  inventory_root = File.join(test_directory, "inventory-#{KIFMultiplayer.operation_id}")
  [inventory_root, File.join(inventory_root, "Data"), File.join(inventory_root, "Data", "Scripts"), File.join(inventory_root, "Mods")].each { |path| Dir.mkdir(path) }
  ["Data/Scripts/a.rb", "Data/species.dat", "Data/PluginScripts.rxdata", "Mods/a.rb", "Data/Map001.rxdata", "Data/Animations.rxdata"].each do |relative|
    File.open(File.join(inventory_root, relative), "wb") { |file| file.write("fixture") }
  end
  inputs = KIFMultiplayer.build_inputs(inventory_root)
  test_log.puts("INVENTORY_NATIVE #{inputs.inspect}")
  assert.call(inputs == %w[Data/PluginScripts.rxdata Data/Scripts/a.rb Data/species.dat Mods/a.rb], "build inventory matches source data Mods and plugin inputs")
  File.open(File.join(inventory_root, "Data/Scripts/unexpected.txt"), "wb") { |file| file.write("new source") }
  assert.call(KIFMultiplayer.build_inputs(inventory_root) != inputs, "new source file detected even when extension is not rb")
  policy_root = File.join(test_directory, "mod-policy-#{KIFMultiplayer.operation_id}")
  [policy_root, File.join(policy_root, "Data"), File.join(policy_root, "Mods")].each { |path| Dir.mkdir(path) }
  assert.call(KIFMultiplayer.ensure_supported_mods(policy_root), "standard rules allow no Mods and no plugin archive")
  plugin_fixture = File.join(policy_root, "Data/PluginScripts.rxdata")
  File.open(plugin_fixture, "wb") { |file| file.write([4, 8, 91, 0].pack("C*")) }
  assert.call(KIFMultiplayer.ensure_supported_mods(policy_root), "standard rules allow exact trusted empty plugin archive")
  mod_fixture = File.join(policy_root, "Mods/custom.rb")
  File.open(mod_fixture, "wb") { |file| file.write("# arbitrary Mod") }
  begin
    KIFMultiplayer.ensure_supported_mods(policy_root)
    raise "Custom Mod was accepted"
  rescue KIFMultiplayer::Error => error
    assert.call(error.code == "unsupported_mods" && error.details["files"] == ["Mods/custom.rb"], "unknown Mods fail closed with explicit filename")
  end
  File.delete(mod_fixture)
  File.open(plugin_fixture, "wb") { |file| file.write([4, 8, 91, 6, 0].pack("C*")) }
  begin
    KIFMultiplayer.ensure_supported_mods(policy_root)
    raise "Nonempty plugin archive was accepted"
  rescue KIFMultiplayer::Error => error
    assert.call(error.code == "unsupported_mods" && error.details["files"] == ["Data/PluginScripts.rxdata"], "nonempty plugins fail closed without deserialization")
  end
  if defined?(System)
    require "digest/sha2"
    assert.call(Digest::SHA256.hexdigest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "actual runtime SHA256 available")
  end
  test_log.puts("CLIENT_TEST_PASS checks=#{checks} ruby=#{RUBY_VERSION} native=#{defined?(System) ? true : false}")
  puts "CLIENT_TEST_PASS checks=#{checks}"
rescue Exception => error
  test_log.puts("CLIENT_TEST_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  warn error.full_message
  raise
ensure
  test_log.close
  exit if defined?(System)
end
