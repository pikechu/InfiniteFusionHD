require "fileutils"
ROOT = File.expand_path("../..", __dir__)
Dir.chdir(ROOT)
%w[001_Client 015_Transport 017_OnlineClient].each { |name| load "Data/Scripts/054_Multiplayer/#{name}.rb" }
module KIFMultiplayer; class UI; end; end
load "Data/Scripts/054_Multiplayer/024_ControlledCharacters.rb"
load "Data/Scripts/054_Multiplayer/026_OriginalCharacters.rb"
load "Data/Scripts/054_Multiplayer/030_OriginalCommerce.rb"
server, directory = ARGV
raise "Loopback fixture required" unless server =~ /\Ahttp:\/\/127\.0\.0\.1:\d+\z/ && File.directory?(directory)
profile = KIFMultiplayer::Profile.new(File.join(directory, "original-client-profile.json"))
profile.server = server
client = KIFMultiplayer::Client.new(profile)
client.authenticate("register", "native_ruby", "OriginalClientFixture123", "Native")
controlled = KIFMultiplayer::ControlledClient.new(client).refresh
character = controlled.create("原版客户端角色")
legacy = {"money" => 999999, "bag" => {"MASTERBALL" => 50}}
before = Marshal.dump(legacy)
model = KIFMultiplayer::OriginalClient.new(client).refresh(character["id"])
raise "Fresh role already active" if model.original["active"]
model.act("activate")
raise "Native opening location differs" unless model.original["view"]["world"]["map_id"] == 295 && model.original["view"]["party"].empty?
sleep 0.06
model.act("wait")
30.times do
  prompt = model.original["prompt"]
  break unless prompt
  value = case prompt["kind"]
          when "choice" then prompt["choices"].index("Confirm") || prompt["choices"].index("Normal") || 0
          when "confirm" then true
          when "name" then "Native"
          else raise "Unexpected native prompt"
          end
  model.choose(value)
end
raise "Native opening did not finish" unless model.original["prompt"].nil? && model.original["view"]["world"]["map_id"] == 157
raise "Native model changed local assets" unless Marshal.dump(legacy) == before
raise "Native request receipt was not cleared" unless profile.account["pending"].nil?
market = model.commerce_read("market", {"page" => 0, "species" => "PIKACHU"})
raise "Native market currency differs" unless market["currency"] == "GOLD" && market["listings"].empty?
peer_profile = KIFMultiplayer::Profile.new(File.join(directory, "original-peer-profile.json"))
peer_profile.server = server
peer_client = KIFMultiplayer::Client.new(peer_profile)
peer_client.authenticate("register", "native_peer", "OriginalPeerFixture123", "Peer")
other = KIFMultiplayer::ControlledClient.new(peer_client).refresh.create("双方确认测试")
other_model = KIFMultiplayer::OriginalClient.new(peer_client).refresh(other["id"])
other_model.act("activate")
invited = model.commerce_act("trades", "invite", {"target" => other["id"], "monsters" => [], "items" => [], "gold" => 10})
raise "Original offer missing" unless invited["offer"]["status"] == "open"
offers = model.commerce_read("trades")
raise "Original offer not discoverable" unless offers["offers"].any? { |offer| offer["id"] == invited["offer"]["id"] }
model.commerce_act("trades", "cancel", {"offer_id" => invited["offer"]["id"], "expected_offer_version" => invited["offer"]["version"]})
pending = {"path" => "/v1/controlled/characters/#{character['id']}/original", "method" => "POST", "identity_id" => client.player_id,
  "body" => {"request_id" => "unsent_fixture_operation"}}
profile.account["pending"] = pending
profile.save
model.heartbeat
raise "Presence overwrote an uncertain economic operation" unless profile.account["pending"] == pending
profile.account["pending"] = nil
profile.save
bad = KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump({"character" => model.character, "original" => model.original}))
bad["original"]["state"] = "untrusted"
begin
  model.accept(bad)
  raise "Native client accepted a private blob"
rescue KIFMultiplayer::Error
end
puts "ORIGINAL_CLIENT_HTTP_OPENING_AND_LEGACY_ISOLATION_PASS"
