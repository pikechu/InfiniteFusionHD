require "fileutils"
ROOT = File.expand_path("../..", __dir__)
Dir.chdir(ROOT)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
load "Data/Scripts/054_Multiplayer/017_OnlineClient.rb"
module KIFMultiplayer; class UI; end; end
load "Data/Scripts/054_Multiplayer/024_ControlledCharacters.rb"
load "Data/Scripts/054_Multiplayer/025_ControlledAdventure.rb"
checks = 0
check = lambda { |condition, name| raise "FAIL #{name}" unless condition; checks += 1; puts "PASS #{name}" }
server, directory = ARGV
raise "Loopback fixture required" unless server =~ /\Ahttp:\/\/127\.0\.0\.1:[0-9]+\z/ && directory && File.directory?(directory)
profile = KIFMultiplayer::Profile.new(File.join(directory, "ruby-adventure-profile.json"))
profile.server = server
client = KIFMultiplayer::Client.new(profile)
client.authenticate("register", "ruby_adventure", "AdventureClientFixture123", "受控主线")
assets = KIFMultiplayer::ControlledClient.new(client).refresh
character = assets.create("受控旅途")
model = KIFMultiplayer::ControlledAdventureClient.new(client, character["id"]).refresh
LegacyAdventureFixture = Struct.new(:money, :bag, :party)
legacy = LegacyAdventureFixture.new(999999, {"MASTERBALL" => 500}, [:LEGACY_POKEMON])
before = Marshal.dump(legacy)
check.call(model.state["monsters"].empty?, "legacy Pokemon are not imported")
model.act("starter", {"species" => "BULBASAUR"})
monster = model.state["monsters"].first
check.call(monster["level"] == 5 && monster["id"] =~ /\Acm_/, "server starter identity")
model.act("train", {"monster_id" => monster["id"], "stat" => "ATTACK", "amount" => 1})
check.call(model.character["wallet"]["balance"] == 980 && model.state["monsters"].first["ev"]["ATTACK"] == 1, "server cultivation debit and stat")
character = assets.character(character["id"])
ball = assets.catalog["items"].find { |item| item["id"] == "POKEBALL" }
assets.trade(character, "buy", ball, 1)
model.refresh
model.act("start", {"kind" => "trainer", "entry" => "chapter-0"})
check.call(model.state["battle"]["round"] == 0, "real HTTP persistent battle")
result = model.turn({"kind" => "flee"})
check.call(result["settled_battle"]["outcome"] == "abandoned" && model.state["battle"].nil?, "server abandonment releases battle")
sleep 1.05
region = model.catalog["regions"].min_by { |entry| entry["min_level"] }
model.act("start", {"kind" => "wild", "entry" => region["id"]})
result = model.turn({"kind" => "catch", "item" => "POKEBALL"})
check.call(result["settled_battle"]["outcome"] == "captured", "capture computed by server")
check.call(model.state["monsters"].length == 2 && model.character["inventory"].empty?, "capture consumes ball and grants exactly one creature")
model.act("heal")
check.call(model.state["monsters"].all? { |entry| entry["hp"] == entry["stats"]["HP"] }, "healing reads authoritative HP")
check.call(Marshal.dump(legacy) == before, "legacy character unchanged")
check.call(profile.account["pending"].nil?, "all intent receipts confirmed")
bad = KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump({"character" => model.character, "adventure" => model.state}))
bad["adventure"]["monsters"].first["hp"] = 999999
begin
  model.accept(bad)
  raise "Invalid authoritative projection accepted"
rescue KIFMultiplayer::Error
  check.call(true, "malformed creature projection rejected")
end
puts "CONTROLLED_ADVENTURE_CLIENT_PASS checks=#{checks}"
