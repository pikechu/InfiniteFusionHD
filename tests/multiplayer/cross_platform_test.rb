# Capability/compatibility contract with simulated platform flags. This is NOT
# Android/macOS/Linux game execution and must never be reported as device E2E.
require "fileutils"
require "tmpdir"
require "digest/sha2"
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
module System
  class << self
    attr_accessor :android_host, :platform_name
    def is_android?; !!@android_host; end
    def platform; @platform_name || "Windows"; end
  end
end
module Settings
  GAME_VERSION = "cross-platform-isolated-fixture"
end
module HTTPLite
  def self.get(*); raise "unsafe native HTTP must not be invoked"; end
  def self.post_body(*); raise "unsafe native HTTP must not be invoked"; end
end
load "Data/Scripts/000_Platform.rb"
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
checks = 0
verify = lambda do |value, name|
  raise "FAIL #{name}" unless value
  checks += 1
  puts "PASS #{name}"
end
reject = lambda do |code, name, &block|
  error = nil
  begin; block.call; rescue KIFMultiplayer::Error => failure; error = failure; end
  verify.call(error && error.code == code, name)
end
directory = File.join(root, "temp", "multiplayer", "cross-platform-#{Process.pid}-#{Time.now.to_i}")
FileUtils.mkdir_p(directory)
profile = KIFMultiplayer::Profile.new(File.join(directory, "profile.json"))
profile.data["server"] = "http://127.0.0.1:45678"
profile.account["identity"] = {"id" => "p_cross_platform_fixture"}
profile.account["token"] = "synthetic_fixture_token"
profile.save

System.android_host = false
transport = KIFMultiplayer::HTTPTransport.new
verify.call(transport.backend == :core_socket, "desktop selects safe core Socket transport")
verify.call(transport.validate_url("http://127.0.0.1:45678/v1/health")[:scheme] == "http", "desktop local HTTP passes preflight")
ssl_available = KIFMultiplayer::SocketHTTP.method(:ssl_available?)
KIFMultiplayer::SocketHTTP.define_singleton_method(:ssl_available?) { false }
client = KIFMultiplayer::Client.new(profile, transport)
profile.data["server"] = "https://localhost:45678"
reject.call("unsupported_https", "missing TLS blocks before writing an economic journal") { client.request("POST", "/v1/trades", {}) }
verify.call(!profile.account["pending"], "unsupported desktop TLS creates no pending operation")
KIFMultiplayer::SocketHTTP.define_singleton_method(:ssl_available?, ssl_available)
profile.data["server"] = "http://127.0.0.1:45678"

System.android_host = true
verify.call(!KIF::Platform.network_available?, "Android is unavailable without an explicitly installed adapter")
android_transport = KIFMultiplayer::HTTPTransport.new
verify.call(android_transport.backend == :platform, "Android never silently falls back to desktop/native HTTP")
client = KIFMultiplayer::Client.new(profile, android_transport)
reject.call("network_unavailable", "Android missing adapter blocks HTTP mutation preflight") { client.request("POST", "/v1/trades", {}) }
verify.call(!profile.account["pending"], "Android unavailable network creates no transaction journal")
reject.call("network_unavailable", "Android missing adapter blocks HTTPS too") { android_transport.validate_url("https://localhost/v1/health") }

explicit_socket = KIFMultiplayer::HTTPTransport.new.enable_online_network
verify.call(explicit_socket.backend == :core_socket, "online mode can explicitly enable verified core Socket networking on Android")
verify.call(explicit_socket.validate_url("http://127.0.0.1:45678/v1/health")[:scheme] == "http", "explicit Android Socket path accepts local HTTP without native HTTPLite")

calls = []
adapter = Object.new
adapter.define_singleton_method(:get) do |url, headers|
  calls << ["GET", url, headers]
  {:status => 200, :body => '{"ok":true,"fixture":true}'}
end
adapter.define_singleton_method(:post_body) do |url, body, media, headers|
  calls << ["POST", url, headers, KIFMultiplayer::WireJSON.parse(body), media]
  {:status => 200, :body => '{"ok":true,"fixture":true}'}
end
KIF::Platform.install_http_adapter(adapter)
verify.call(KIF::Platform.network_available?, "explicit mock adapter makes Android capability available")
verify.call(client.request("GET", "/v1/health")["fixture"], "Android adapter response is parsed through the real bounded JSON client")
client.request("POST", "/v1/trades", {"source" => "local_casual"})
verify.call(calls.last[0] == "POST" && calls.last[2]["Authorization"] == "Bearer synthetic_fixture_token", "Android adapter receives authenticated POST headers")
verify.call(calls.last[3]["request_id"].is_a?(String) && calls.last[3]["source"] == "local_casual", "Android adapter gets explicit JSON fields and operation ID")
verify.call(!profile.account["pending"], "successful mock mutation clears journal durably")
verify.call(!KIFMultiplayer::Profile.new(profile.path).account["pending"], "mock operation journal cleanup survives profile reload")

fixture_root = File.join(directory, "game")
FileUtils.mkdir_p(File.join(fixture_root, "Data", "Scripts"))
File.write(File.join(fixture_root, "Data", "Scripts", "Fixture.rb"), "# isolated compatibility fixture\n")
Dir.chdir(fixture_root) do
  files = KIFMultiplayer.build_inputs.each_with_object({}) { |path, value| value[path] = {"size" => File.size(path), "sha256" => KIFMultiplayer.file_digest(path)} }
  manifest = {"version" => 1, "protocol" => KIFMultiplayer::PROTOCOL, "rules_version" => KIFMultiplayer::RULES_VERSION,
    "data_hash" => Digest::SHA256.hexdigest("fixture data"), "mods_hash" => Digest::SHA256.hexdigest("fixture mods"), "files" => files}
  File.write("Data/multiplayer-build.json", KIFMultiplayer::WireJSON.dump(manifest))
  expected = client.compatibility
  verify.call(expected.keys.sort == %w[data_hash game_version mods_hash protocol rules_version], "wire compatibility binds code/data/mod/rules rather than OS name")
  ["Windows", "macOS", "Linux", "Android"].each do |name|
    System.platform_name = name
    System.android_host = name == "Android"
    verify.call(client.compatibility == expected, "simulated #{name} advertises identical compatibility for identical content")
    data = {"id" => 0xffffffff, "text" => "跨端 fixture", "hp" => 123, "scale" => 1.25}
    verify.call(KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(data)) == data, "simulated #{name} preserves typed JSON fields")
  end
  File.write("Data/Scripts/Fixture.rb", "# changed fixture\n")
  reject.call("stale_build", "same OS-independent manifest rejects modified source before joining") { client.compatibility }
end
puts "CROSS_PLATFORM_MOCK_PASS checks=#{checks} ruby=#{RUBY_VERSION} host=#{RUBY_PLATFORM} evidence=#{directory}"
puts "NOT_DEVICE_ACCEPTANCE: platform flags/adapters are mocks; no Android/macOS/Linux game was launched."
