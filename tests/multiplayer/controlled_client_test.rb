require "fileutils"
ROOT = File.expand_path("../..", __dir__)
Dir.chdir(ROOT)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
load "Data/Scripts/054_Multiplayer/017_OnlineClient.rb"
module KIFMultiplayer; class UI; end; end
load "Data/Scripts/054_Multiplayer/024_ControlledCharacters.rb"

checks = 0
check = lambda { |condition, name| raise "FAIL #{name}" unless condition; checks += 1; puts "PASS #{name}" }
server, directory = ARGV
raise "Pass loopback server and isolated fixture directory" unless server =~ /\Ahttp:\/\/127\.0\.0\.1:[0-9]+\z/ && directory && File.directory?(directory)
profile = KIFMultiplayer::Profile.new(File.join(directory, "ruby-controlled-profile.json"))
profile.server = server
client = KIFMultiplayer::Client.new(profile)
client.authenticate("register", "ruby_controlled", "ControlledClientFixture123", "Ruby受控测试")
model = KIFMultiplayer::ControlledClient.new(client).refresh
LegacyControlledFixture = Struct.new(:money, :bag)
legacy = LegacyControlledFixture.new(999_999, {"MASTERBALL" => 500})
before = Marshal.dump(legacy)
created = model.create("全新受控角色")
check.call(created["wallet"]["balance"] == 1000, "initial server grant")
item = model.catalog["items"].first
bought = model.trade(created, "buy", item, 1)
check.call(bought["wallet"]["balance"] == 800 && bought["inventory"].first["quantity"] == 1, "real HTTP purchase updates only server inventory")
sold = model.trade(bought, "sell", item, 1)
check.call(sold["wallet"]["balance"] == 900 && sold["inventory"].empty?, "real HTTP sale consumes owned stock")
check.call(model.daily(sold) == 100, "server account daily reward")
current = model.character(created["id"])
check.call(model.daily(current) == 0, "duplicate daily grant prevented")
check.call(Marshal.dump(legacy) == before, "legacy save not imported or modified")
check.call(profile.account["pending"].nil?, "mutation journals completed")
bad = KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(current))
bad["owner"] = "p_" + "f" * 24
begin
  model.validate(bad)
  raise "FAIL foreign owner accepted"
rescue KIFMultiplayer::Error
  check.call(true, "foreign owner response rejected")
end
bad = KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(current))
bad["inventory"] = [{"item" => "../../arbitrary", "quantity" => 1}]
begin
  model.validate(bad)
  raise "FAIL unknown inventory accepted"
rescue KIFMultiplayer::Error
  check.call(true, "unknown inventory response rejected")
end
puts "CONTROLLED_CLIENT_PASS checks=#{checks}"
