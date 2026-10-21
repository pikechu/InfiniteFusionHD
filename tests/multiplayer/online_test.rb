require "fileutils"
require "tmpdir"
require "digest/sha2"
ROOT = File.expand_path("../..", __dir__)
Dir.chdir(ROOT)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
module Settings; GAME_VERSION = "online-fixture"; end
class Player; attr_accessor :name, :party; end
module SaveData
  def self.valid?(value); value.is_a?(Hash) && value[:player].is_a?(Player); end
end
class Scene_Map; end
load "Data/Scripts/054_Multiplayer/016_CloudCodec.rb"
load "Data/Scripts/054_Multiplayer/017_OnlineClient.rb"
load "Data/Scripts/054_Multiplayer/018_World.rb"
checks = 0
assert = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
reject = lambda do |name, &block|
  begin; block.call; rescue KIFMultiplayer::Error; assert.call(true, name); else; raise "FAIL accepted #{name}"; end
end

player = Player.new
player.name, player.party = "测试账号😀", []
shared = [4294967295, :PIKACHU, "\xff".b, Time.at(1700000000, 123456789, :nanosecond)]
save = {:player => player, :shared => shared, :same => shared, :hash => Hash.new(false)}
player.party << shared
shared << player
save[:hash][[1, 2, "A"]] = true
packed = KIFMultiplayer::CloudCodec.pack(save)
decoded = KIFMultiplayer::CloudCodec.unpack(packed)
assert.call(decoded[:player].name == player.name && decoded[:shared][0] == 4294967295, "safe graph preserves Unicode and uint32")
assert.call(decoded[:shared].equal?(decoded[:same]) && decoded[:shared][-1].equal?(decoded[:player]), "safe graph preserves shared references and cycles")
assert.call(decoded[:shared][2] == "\xff".b && decoded[:shared][3].nsec == 123456789, "safe graph preserves binary strings and nanosecond time")
assert.call(decoded[:hash][[1, 2, "A"]] && decoded[:hash]["missing"] == false, "safe graph restores composite keys and hash defaults")
reject.call("cloud checksum rejects modified payload") { KIFMultiplayer::CloudCodec.unpack(packed.merge("sha256" => "0" * 64)) }
reject.call("unknown game classes cannot be encoded") { KIFMultiplayer::CloudCodec.pack({:player => player, :evil => Object.new}) }
reject.call("wire class names cannot allocate arbitrary Ruby classes") do
  KIFMultiplayer::CloudCodec::Decoder.new.decode({"version" => 1, "root" => {"ref" => 0}, "nodes" => [{"type" => "object", "class" => "Object", "ivars" => {}}]})
end
reject.call("wire event scripts cannot be installed through ivars") do
  KIFMultiplayer::CloudCodec::Decoder.new.decode({"version" => 1, "root" => {"ref" => 0}, "nodes" => [{"type" => "object", "class" => "Player", "ivars" => {"@list" => "evil"}}]})
end
reject.call("invalid graph reference rejected") do
  KIFMultiplayer::CloudCodec::Decoder.new.decode({"version" => 1, "root" => {"ref" => 99}, "nodes" => []})
end

class OnlineFixtureTransport
  attr_accessor :lose_upload_once, :delay
  attr_reader :uploads, :saves, :calls
  def initialize
    @uploads, @saves, @calls, @delay = {}, {}, [], 0
  end
  def call(method, url, body, _token, _timeout)
    sleep(@delay) if @delay > 0
    @calls << [method, url, body]
    result = {"ok" => true}
    if url.end_with?("/auth/register") || url.end_with?("/auth/login")
      result.merge!("identity" => {"id" => "p_" + "a" * 24, "nickname" => "Fixture", "friend_code" => "AABBCCDD"}, "username" => "fixture", "token" => "fixture_secret_token")
    elsif url.end_with?("/cloud/open")
      result["saves"] = @saves.map { |slot, entry| {"slot" => slot, "revision" => entry["revision"]} }
    elsif url.end_with?("/cloud/upload")
      id, slot = body["upload_id"], body["slot"]
      unless @uploads[id]
        current = @saves.dig(slot, "revision") || 0
        raise "revision conflict" unless current == body["revision"]
        @saves[slot] = {"revision" => current + 1, "save" => body["save"]}
        @uploads[id] = {"ok" => true, "slot" => slot, "revision" => current + 1, "upload_id" => id}
      end
      if @lose_upload_once
        @lose_upload_once = false
        raise IOError, "lost committed upload reply"
      end
      result = @uploads[id]
    elsif url.end_with?("/cloud/download")
      result.merge!(@saves.fetch(body["slot"]))
    end
    {:status => 200, :body => KIFMultiplayer::WireJSON.dump(result)}
  end
end

directory = File.join(ROOT, "temp", "multiplayer", "online-unit-#{Process.pid}")
FileUtils.mkdir_p(directory)
profile = KIFMultiplayer::Profile.new(File.join(directory, "profile.json"))
transport = OnlineFixtureTransport.new
client = KIFMultiplayer::Client.new(profile, transport)
client.authenticate("register", "fixture", "private_password")
assert.call(!File.read(profile.path).include?("private_password") && !profile.account["pending"], "password and login body never enter profile or economic journal")
compat = {"protocol" => KIFMultiplayer::PROTOCOL, "game_version" => Settings::GAME_VERSION, "data_hash" => "fixture-data", "mods_hash" => "fixture-mods", "rules_version" => KIFMultiplayer::RULES_VERSION}
cloud = KIFMultiplayer::CloudSession.new(client, compat)
cloud.open
cloud.queue_save("File A", save)
transport.lose_upload_once = true
deadline = Time.now + 5
while cloud.pending?
  raise "upload timeout" if Time.now > deadline
  cloud.instance_variable_set(:@next_poll, 0)
  cloud.tick
  sleep(0.005)
end
assert.call(transport.uploads.length == 1 && transport.saves["file-a"]["revision"] == 1, "lost committed upload response retries same ID without duplicate revision")
assert.call(!profile.account["pending"] && !File.read(profile.path).include?("kif-save-json"), "cloud networking does not overwrite economic journal or profile with save contents")
transport.delay = 0.08
cloud.queue_save("File A", save)
cloud.tick
player.name = "newer local progress"
cloud.queue_save("File A", save)
deadline = Time.now + 5
while cloud.pending? || cloud.instance_variable_get(:@io).pending?
  raise "coalesced upload timeout" if Time.now > deadline
  cloud.tick
  sleep(0.005)
end
assert.call(transport.saves["file-a"]["revision"] == 3, "save while upload is running queues next revision")
latest = KIFMultiplayer::CloudCodec.unpack(transport.saves["file-a"]["save"])
assert.call(latest[:player].name == player.name, "latest local progress survives an earlier upload acknowledgement")
cloud.queue_save("File B", save)
crashed = KIFMultiplayer::CloudSession.new(client, compat)
crashed.open
assert.call(transport.saves["file-b"]["revision"] == 1 && File.file?(crashed.file("file-b")), "new process replays durable pending upload before pulling cloud save")
assert.call(cloud.directory.include?(client.player_id), "online cache is scoped by server and account")

world = KIFMultiplayer::WorldSession.new(client, compat)
key = "a" * 64
world.instance_variable_set(:@map_key, key)
world.remember({"id" => 1, "channel" => "map", "map_key" => key, "sender_id" => "p_other", "nickname" => "玩家", "text" => "你好"})
world.remember({"id" => 1, "channel" => "map", "map_key" => key, "sender_id" => "p_other", "nickname" => "玩家", "text" => "你好"})
world.remember({"id" => 2, "channel" => "world", "map_key" => nil, "sender_id" => "p_other", "nickname" => "玩家", "text" => "世界"})
assert.call(world.visible_messages.length == 2, "message retry and poll overlap display only once")
world.instance_variable_set(:@map_key, "b" * 64)
assert.call(world.visible_messages.map { |message| message["text"] } == ["世界"], "old map messages disappear on map change while world remains visible")
reject.call("chat rejects control characters") { world.send_chat("world", "\n") }
reject.call("chat enforces 200 character limit") { world.send_chat("world", "a" * 201) }
world.send_chat("world", "中文😀")
assert.call(world.pending_messages == 1, "Unicode world message is queued without blocking game")
puts "ONLINE_TEST_PASS checks=#{checks}"
