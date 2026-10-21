require "ostruct"
ROOT = File.expand_path("../..", __dir__)
load File.join(ROOT, "Data/Scripts/054_Multiplayer/001_Client.rb")
class PokeBattle_Battle; end
load File.join(ROOT, "Data/Scripts/054_Multiplayer/005_Gym.rb")
load File.join(ROOT, "Data/Scripts/054_Multiplayer/011_Dungeon.rb")
load File.join(ROOT, "Data/Scripts/054_Multiplayer/012_Replay.rb")
module GameData
  class Registry
    def self.exists?(_value); true; end
  end
  class Species < Registry; DATA = {:TESTMON => true}; end
  Nature = Class.new(Registry)
  Ability = Class.new(Registry)
  Item = Class.new(Registry)
  Move = Class.new(Registry)
  Type = Class.new(Registry)
  Status = Class.new(Registry)
end
class PokeBattle_Scene; end
class Pokemon; end
class KIFMultiplayerBattle < PokeBattle_Battle; end
load File.join(ROOT, "Data/Scripts/054_Multiplayer/014_GuestScene.rb")
class FeatureProfile
  attr_reader :data
  def initialize; @data = {"servers" => {"test" => {}}}; end
  def server; "test"; end
  def account; @data["servers"][server]; end
  def save; true; end
end
class FeatureClient
  attr_reader :profile, :requests
  attr_accessor :fail_once, :wait_update
  def initialize
    @profile, @requests, @failed = FeatureProfile.new, [], false
  end
  def player_id; "p_aaaaaaaaaaaaaaaaaaaaaaaa"; end
  def recover_pending; nil; end
  def request(method, path, body = {})
    @requests << [method, path, Marshal.load(Marshal.dump(body))]
    if fail_once && !@failed
      @failed = true
      raise KIFMultiplayer::UncertainRequest, "Injected committed response loss"
    end
    if path.end_with?("/result")
      {"challenge" => {"id" => "gc_" + "a" * 32, "owner_id" => player_id, "status" => "finished", "result" => body.dup}}
    elsif path.end_with?("/claim")
      {"reward" => {"id" => "medal_unique", "kind" => "gym_medal", "owner_id" => player_id}}
    else
      {"challenge" => {"id" => "gc_" + "a" * 32, "owner_id" => player_id, "status" => "active"}}
    end
  end
end
$feature_checks = 0
def verify(value, name)
  raise "FAIL #{name}" unless value
  $feature_checks += 1
end
def reject(name)
  begin
    yield
  rescue KIFMultiplayer::Error
    verify(true, name)
  else
    raise "FAIL accepted #{name}"
  end
end
client = FeatureClient.new
challenge = {"id" => "gc_" + "a" * 32, "owner_id" => client.player_id, "status" => "active"}
session = KIFMultiplayer::GymSession.new(client)
client.fail_once = true
begin
  session.finish(challenge, "win", 3, "Real result")
rescue KIFMultiplayer::UncertainRequest
  verify(session.journal["report"]["outcome"] == "win", "uncertain report remains durable")
end
request_id = session.journal["report"]["request_id"]
report = session.finish(challenge, "loss", 99, "must not replace original")
verify(report["challenge"]["result"]["outcome"] == "win", "recovery reuses original immutable result")
verify(client.requests.select { |r| r[1].end_with?("/result") }.all? { |r| r[2]["request_id"] == request_id }, "same report request id reused")
verify(session.journal.nil?, "finished report clears local journal")
verify(report["reward"]["id"] == "medal_unique", "win returns account medal")
session.remember(challenge)
result = session.recover
verify(result["challenge"]["result"]["outcome"] == "abnormal", "crashed local engine cannot fabricate win")
client.profile.account["last_recovered_operation"] = {"path" => "/v1/gyms/AABBCCDD/challenge", "response" => {"challenge" => challenge}}
verify(session.journal.nil?, "lost create response initially has no local challenge journal")
adopted = session.adopt_recovered_challenge
verify(adopted["id"] == challenge["id"] && !client.profile.account["last_recovered_operation"], "recovered create response adopts and consumes original challenge exactly once")
result = session.recover
verify(result["challenge"]["result"]["outcome"] == "abnormal" && session.journal.nil?, "original interrupted challenge can be closed instead of orphaned")
session.remember(challenge)
reject("pending gym forbids server switch") { KIFMultiplayer.assert_identity_change_safe!(client.profile) }
client.profile.account.delete("gym_session")
verify(KIFMultiplayer.assert_identity_change_safe!(client.profile), "resolved gym allows identity switch")
client.profile.data["servers"]["original-server"] = {"trade_pending" => {"player_id" => client.player_id}}
verify(KIFMultiplayer.assert_identity_change_safe!(client.profile, "original-server"), "lost profile can return to the bound original server")
reject("bound trade cannot switch to arbitrary new server") { KIFMultiplayer.assert_identity_change_safe!(client.profile, "unrelated-server") }
client.profile.data["servers"].delete("original-server")
reject("foreign challenge blocked") { session.remember(challenge.merge("owner_id" => "p_bad")) }
reject("route identifier traversal") { KIFMultiplayer::DungeonSession.new(client, "../../secret") }
route = KIFMultiplayer::DungeonSession.new(client, "d_" + "a" * 32)
route.adopt({"dungeon" => {"id" => "d_" + "a" * 32, "players" => [client.player_id], "host_id" => client.player_id, "status" => "preparing"}})
verify(route.host? && !route.terminal?, "route identity and active state")
reject("foreign route blocked") { route.adopt({"dungeon" => {"players" => ["p_other"]}}) }
players = [client.player_id, "p_bbbbbbbbbbbbbbbbbbbbbbbb"]
stats = KIFMultiplayer::Snapshot::STATS
pokemon = {"version" => 1, "species" => "TESTMON", "level" => 31, "form" => 0, "name" => "Fixture", "gender" => 0, "personal_id" => 4,
  "nature" => "HARDY", "nature_for_stats" => nil, "ability" => "STATIC", "ability_index" => 0, "ability2" => nil, "ability2_index" => nil,
  "item" => nil, "moves" => [{"id" => "TACKLE", "pp" => 35, "ppup" => 0}], "iv" => stats.to_h { |s| [s, 31] },
  "ev" => stats.to_h { |s| [s, 0] }, "iv_maxed" => stats.to_h { |s| [s, false] }, "happiness" => 70, "shiny" => false,
  "appearance" => {}, "hidden_power_type" => nil, "owner" => {"id" => 1, "name" => "Fixture", "gender" => 0, "language" => 2}}
result = {"id" => "result_fixture", "winner_id" => players[0], "reason" => "battle_decision_1", "abnormal" => false}
compat = {"protocol" => 1, "data_hash" => "verified-test-data"}
replay = {"id" => "replay_fixture", "players" => players, "compatibility" => compat, "result" => result,
  "data" => {"version" => 1, "mode" => "friendly_singles", "host_id" => players[0], "initial_teams" => players.to_h { |id| [id, [pokemon] * 3] },
    "updates" => [{"turn" => 0, "state" => {"kind" => "command", "battlers" => [{"owner_id" => players[0], "index" => 0, "species" => "TESTMON", "hp" => 50, "totalhp" => 50, "status" => "NONE"}], "events" => ["A recorded move"]}, "random_tape" => [{"limit" => 16, "value" => 8}]}], "result" => result}}
verify(KIFMultiplayer::ReplayData.validate(replay, compat)["result"] == result, "recorded final result preserved without simulation")
copy = -> { KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(replay)) }
reject("wrong replay compatibility") { KIFMultiplayer::ReplayData.validate(replay, {}) }
broken = copy.call; broken["data"]["updates"][0]["state"]["battlers"][0]["hp"] = 51
reject("damaged replay HP") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["updates"] << broken["data"]["updates"][0]
reject("duplicate replay phase") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["updates"][0]["random_tape"][0]["value"] = 16
reject("damaged random result") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["result"] = result.merge("winner_id" => players[1])
reject("conflicting replay final result") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["updates"][0]["state"]["battlers"][0]["status"] = {"script" => "none"}
reject("object instead of replay status") { KIFMultiplayer::ReplayData.validate(broken, compat) }
visual = {"version" => 1, "seq" => 1, "complete" => true, "events" => [], "battlers" => [
  {"slot" => 0, "species" => "TESTMON", "level" => 50, "name" => "Fixture", "hp" => 50, "totalhp" => 50,
   "status" => "NONE", "party_index" => 0, "form" => 0, "gender" => 0, "shiny" => true, "appearance" => {"sprite_scale" => 1.5}}
]}
replay["data"]["updates"][0]["state"]["visuals"] = visual
verify(KIFMultiplayer::ReplayData.validate(replay, compat)["updates"][0]["state"]["visuals"]["battlers"][0]["shiny"], "supported public replay appearance validated before rendering")
broken = copy.call; broken["data"]["updates"][0]["state"]["visuals"]["battlers"][0]["appearance"]["sprite_scale"] = "arbitrary"
reject("malformed replay appearance stays a recoverable UI error") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["updates"][0]["state"]["visuals"]["battlers"][0]["hp"] = 49
reject("replay public visual HP cannot differ from authority") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; broken["data"]["updates"][0]["state"]["battlers"] *= 2
reject("duplicate replay slots") { KIFMultiplayer::ReplayData.validate(broken, compat) }
broken = copy.call; next_frame = copy.call["data"]["updates"][0]; next_frame["turn"] = 1; broken["data"]["updates"] << next_frame
reject("replay visual sequence cannot repeat") { KIFMultiplayer::ReplayData.validate(broken, compat) }
puts "GYM_DUNGEON_REPLAY_TEST_PASS checks=#{$feature_checks}"
