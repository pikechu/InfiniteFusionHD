# Boundary checks complement the separate real Game.exe cooperative scenario.
load File.expand_path("battle_test.rb", __dir__)

class Pokemon
  attr_reader :totalhp, :hp
  def initialize
    @totalhp, @hp = 100, 100
  end
  def calc_stats
    damage = @totalhp - @hp
    @totalhp = 100
    @hp = [@totalhp - damage, 0].max
  end
end
load File.join(ROOT, "Data/Scripts/054_Multiplayer/004_Boss.rb")

pokemon = KIFMultiplayer::BossPokemon.new
pokemon.enable_boss_hp(3)
assert(pokemon.totalhp == 300 && pokemon.hp == 300, "Boss HP multiplier was not applied")
pokemon.instance_variable_set(:@hp, 217)
3.times { pokemon.calc_stats }
assert(pokemon.totalhp == 300 && pokemon.hp == 217, "Boss stat refresh stacked HP or healed damage")
pokemon.instance_variable_set(:@hp, 0)
pokemon.calc_stats
assert(pokemon.hp == 0, "Boss stat refresh resurrected defeated Boss")

class BossBoundaryEngine < KIFMultiplayerBossBattle
  attr_accessor :test_commands, :active_indices
  attr_reader :registered_switches
  def online_boundary(*_args); @test_commands; end
  def online_legal_targets(index, _move); index == 0 ? [1, 2] : [0, 1]; end
  def pbCanShowCommands?(index); @active_indices.include?(index); end
  def pbRegisterSwitch(index, party)
    return false unless [[0, 1], [2, 4]].include?([index, party])
    (@registered_switches ||= []) << [index, party]
    true
  end
  def pbCanSwitchLax?(index, party); [[0, 1], [2, 4]].include?([index, party]); end
  def pbCanSwitch?(index, party); pbCanSwitchLax?(index, party); end
end

class BossTestAI
  attr_reader :commands, :switches
  def initialize; @commands, @switches = [], []; end
  def pbDefaultChooseEnemyCommand(index); @commands << index; end
  def pbDefaultChooseNewEnemy(index, _party); @switches << index; index == 2 ? 4 : 0; end
end

engine = BossBoundaryEngine.allocate
engine.instance_variable_set(:@online, OpenStruct.new(:battle => {"players" => ["host_id", "guest_id"]}))
scene = Object.new
def scene.pbBeginCommandPhase; end
engine.instance_variable_set(:@scene, scene)
engine.instance_variable_set(:@battlers, [Object.new, Object.new, Object.new])
engine.instance_variable_set(:@online_events, [])
ai = BossTestAI.new
engine.instance_variable_set(:@battleAI, ai)
engine.active_indices = [0, 1, 2]
def engine.pbParty(_index); []; end
assert(engine.online_owner(0) == "host_id" && engine.online_owner(2) == "guest_id" && engine.online_owner(1) == "boss", "Cooperative battler ownership incorrect")
assert(engine.online_offset(0) == 0 && engine.online_offset(2) == 3, "Cooperative party offsets incorrect")
engine.test_commands = {"host_id" => {"action" => "move", "move_index" => 0, "target" => 2},
                        "guest_id" => {"action" => "move", "move_index" => 0, "target" => 1}}
engine.pbCommandPhase
assert(engine.instance_variable_get(:@targets) == {0 => 2, 2 => 1}, "Support/enemy targets were not registered for each owner")
assert(ai.commands == [1], "Boss must receive exactly one engine AI command")
engine.test_commands["guest_id"]["target"] = 2
assert_raises(KIFMultiplayer::BattleError, "Invalid cooperative target accepted") { engine.pbCommandPhase }
engine.test_commands["guest_id"] = {"action" => "switch", "party_index" => 1}
engine.pbCommandPhase
assert(engine.registered_switches.last == [2, 4], "Guest wire party slot did not map to own trainer")
engine.test_commands["guest_id"]["party_index"] = 4
assert_raises(KIFMultiplayer::BattleError, "Guest could select a global party slot") { engine.pbCommandPhase }
engine.test_commands["guest_id"] = {"action" => "ai"}
ai.commands.clear
engine.pbCommandPhase
assert(ai.commands == [2, 1], "AI takeover acted more than once or controlled wrong slot")
engine.active_indices = [1, 2]
engine.test_commands["host_id"] = {"action" => "wait"}
ai.commands.clear
engine.pbCommandPhase
assert(ai.commands == [2, 1], "Eliminated host slot was commanded while surviving partner continued")
engine.test_commands["guest_id"] = {"action" => "switch", "party_index" => 1}
assert(engine.pbSwitchInBetween(2, true) == 4, "Guest replacement used host's reserve")
engine.test_commands["guest_id"] = {"action" => "switch", "party_index" => 0}
assert_raises(KIFMultiplayer::BattleInterrupted, "Illegal owner replacement accepted") { engine.pbSwitchInBetween(2, true) }
engine.test_commands["guest_id"] = {"action" => "ai"}
assert(engine.pbSwitchInBetween(2, true) == 4 && ai.switches == [2], "AI replacement did not use engine ownership validation")
engine.test_commands["guest_id"] = {"action" => "surrender"}
assert_raises(KIFMultiplayerBattle::OnlineForfeit, "Cooperative forfeit returned an invalid party index") { engine.pbSwitchInBetween(2, true) }
assert(engine.instance_variable_get(:@decision) == 2, "Cooperative surrender incorrectly awarded victory")

state = {"kind" => "command", "phase_owner_ids" => ["guest_id"], "battlers" => [
  {"index" => 0, "name" => "Ally"}, {"index" => 1, "name" => "Boss"}],
  "actions" => {"guest_id" => {"moves" => [{"index" => 0, "name" => "Heal Pulse", "pp" => 5, "total_pp" => 10, "targets" => [0, 1]}]}}}
options = KIFMultiplayer::BattleInput.choices(state, "guest_id")
assert(options[0][0].include?("Ally") && options[0][1]["target"] == 0, "Support target absent from input menu")
assert(options[1][0].include?("Boss") && options[1][1]["target"] == 1, "Enemy target absent from input menu")

# Test the actual target-list helper against target categories, independently
# from BossBoundaryEngine's command-boundary stub above.
target_engine = KIFMultiplayerBossBattle.allocate
BattlerTargetFixture = Struct.new(:index, :moves, :down) do
  def fainted?; down; end
end
move = Object.new
def move.pbTarget(_battler); @test_target; end
def move.target=(value); @test_target = value; end
target_engine.instance_variable_set(:@battlers, (0..2).map { |index| BattlerTargetFixture.new(index, [move], false) })
def target_engine.singleBattle?; false; end
def target_engine.pbMoveCanTarget?(user, target, data)
  data.id == :NearAlly ? user != target && target.even? : target.odd?
end
move.target = OpenStruct.new(:id => :NearAlly, :num_targets => 1)
assert(target_engine.online_legal_targets(0, 0) == [2], "Ally move offered enemy/self target")
move.target = OpenStruct.new(:id => :NearFoe, :num_targets => 1)
assert(target_engine.online_legal_targets(2, 0) == [1], "Enemy move offered ally target")
target_engine.instance_variable_get(:@battlers)[1].down = true
assert(target_engine.online_legal_targets(2, 0) == [-1], "Absent legal target must use engine no-target failure, never a fainted explicit target")
move.target = OpenStruct.new(:id => :AllFoes, :num_targets => 2)
assert(target_engine.online_legal_targets(2, 0) == [-1], "Spread move bypassed engine target expansion")
assert(target_engine.online_legal_targets(2, -1).empty?, "Invalid move index accepted")

finished = battle_document("finished").merge("mode" => "coop_boss", "result" => {"coop_outcome" => "victory", "winner_ids" => ["host_id", "guest_id"], "abnormal" => false})
reward = {"id" => "medal_test", "kind" => "boss_medal", "battle_id" => finished["battle_id"], "owner_id" => "host_id"}
client = FakeClient.new([{"reward" => reward}, {"reward" => reward}])
session = KIFMultiplayer::BossSession.new(client, finished)
assert(session.result_decision == 1, "Shared victory reported as solo result")
assert(session.claim_medal == reward && session.claim_medal == reward, "Unique account medal not returned by claim endpoint")
assert(client.calls.all? { |call| call[1].end_with?("/claim") }, "Claim wrote main save or wrong endpoint")
dungeon_client = FakeClient.new([])
dungeon_session = KIFMultiplayer::BossSession.new(dungeon_client, finished.merge("dungeon_id" => "dungeon_test_0001"))
assert(dungeon_session.claim_medal.nil? && dungeon_client.calls.empty?, "Intermediate dungeon node attempted a separate Boss medal claim")
session.adopt({"battle" => finished.merge("result" => {"coop_outcome" => "defeat", "abnormal" => false})})
assert(session.result_decision == 2 && session.claim_medal.nil?, "Defeat issued medal")
session.adopt({"battle" => finished.merge("result" => {"coop_outcome" => "abnormal", "abnormal" => true})})
assert(session.result_decision == 0 && session.claim_medal.nil?, "Abnormal battle issued medal")
signal_client = FakeClient.new([KIFMultiplayer::UncertainRequest.new("lost signal response")])
signal_session = KIFMultiplayer::BossSession.new(signal_client, battle_document.merge("mode" => "coop_boss"))
assert(signal_session.send_signal("support").nil? && signal_client.calls.length == 1, "Lost optional signal aborted combat")
assert_raises(KIFMultiplayer::BattleError, "Invalid preset signal accepted") { signal_session.send_signal("free text") }

# Withdrawing changes the operation generation, so selecting the same move
# again cannot be answered by the server's cached old submission operation.
submitted = battle_document.merge("submitted" => ["host_id"])
client = FakeClient.new([{"battle" => submitted}, {"battle" => battle_document}, {"battle" => submitted}])
session = KIFMultiplayer::BattleSession.new(client, battle_document)
session.submit({"action" => "move", "move_index" => 0, "target" => -1})
session.withdraw
session.submit({"action" => "move", "move_index" => 0, "target" => -1})
assert(client.calls[0][2]["request_id"] != client.calls[2][2]["request_id"], "Resubmission replayed old operation after withdrawal")
session.adopt({"battle" => submitted.merge("deadline" => Time.now.to_f + 12, "reconnect_remaining" => {"host_id" => 15.5}, "disconnected" => ["guest_id"])})
assert(session.waiting_text.include?("15.5") && session.waiting_text.include?("断线") && session.waiting_text.include?("约"), "Waiting UI omitted reconnect allowance or command countdown")

module GameData
  class Status
    def self.exists?(value); %w[NONE POISON SLEEP].include?(value); end
  end
  class Item
    def self.exists?(value); %w[LEFTOVERS SITRUSBERRY].include?(value); end
  end
end
RuntimePokemonFixture = Struct.new(:hp, :totalhp, :status, :statusCount, :moves, :item) do
  def item_id; item; end
end
runtime_parties = 2.times.map do
  3.times.map { RuntimePokemonFixture.new(100, 100, :NONE, 0, [OpenStruct.new(:pp => 10, :total_pp => 10)], :SITRUSBERRY) }
end
runtime = %w[host_id guest_id].each_with_object({}) do |id, result|
  result[id] = 3.times.map { {"hp" => 48, "totalhp" => 100, "status" => "POISON", "status_count" => 2, "pp" => [3], "total_pp" => [10], "item" => nil} }
end
KIFMultiplayer.apply_boss_runtime(runtime_parties, %w[host_id guest_id], runtime)
assert(runtime_parties.flatten.all? { |pokemon| pokemon.hp == 48 && pokemon.moves[0].pp == 3 && pokemon.item.nil? }, "Dungeon runtime healed HP/PP or restored consumed item")
assert(KIFMultiplayer.boss_team_state(runtime_parties, %w[host_id guest_id]) == runtime, "Dungeon post-combat runtime lost a field")
bad_runtime = Marshal.load(Marshal.dump(runtime))
bad_runtime["guest_id"][2]["totalhp"] = 101
assert_raises(KIFMultiplayer::BattleError, "Mismatched HP capacity silently accepted") { KIFMultiplayer.apply_boss_runtime(runtime_parties, %w[host_id guest_id], bad_runtime) }
bad_runtime["guest_id"][2]["totalhp"] = 100
bad_runtime["guest_id"][2]["total_pp"] = [11]
assert_raises(KIFMultiplayer::BattleError, "Mismatched PP capacity silently accepted") { KIFMultiplayer.apply_boss_runtime(runtime_parties, %w[host_id guest_id], bad_runtime) }
bad_runtime["guest_id"][2]["total_pp"] = [10]
bad_runtime["guest_id"][2]["pp"] = [11]
assert_raises(KIFMultiplayer::BattleError, "PP exceeding frozen capacity accepted") { KIFMultiplayer.apply_boss_runtime(runtime_parties, %w[host_id guest_id], bad_runtime) }

class SetupBossEngineFixture < KIFMultiplayerBossBattle
  attr_reader :created
  def pbCreateBattler(index, pokemon, party_index)
    @battlers[index] = OpenStruct.new(:stages => {})
    (@created ||= []) << [index, pokemon.hp, party_index]
  end
end
setup_engine = SetupBossEngineFixture.allocate
party = 6.times.map { |index| OpenStruct.new(:hp => index < 3 ? 0 : 30) }
party.each { |pokemon| def pokemon.able?; hp > 0; end }
foe = OpenStruct.new(:hp => 100)
def foe.able?; hp > 0; end
setup_engine.instance_variable_set(:@party1, party)
setup_engine.instance_variable_set(:@party2, [foe])
setup_engine.instance_variable_set(:@player, [OpenStruct.new(:name => "Host"), OpenStruct.new(:name => "Guest")])
setup_engine.instance_variable_set(:@opponent, [Object.new])
setup_engine.instance_variable_set(:@battlers, [])
setup_engine.instance_variable_set(:@online_events, [])
setup_engine.instance_variable_set(:@online, OpenStruct.new(:battle => {"boss" => {"stat_stages" => {"ATTACK" => 1}}}))
setup_engine.pbEnsureParticipants
sent = setup_engine.pbSetUpSides
assert(sent == [[[], [2]], [[1]]], "Initially eliminated host sent out or took guest slot")
assert(setup_engine.created.include?([0, 0, 0]) && setup_engine.created.include?([2, 30, 3]), "Exhausted trainer placeholder revived or shifted ownership")
assert(party.first(3).all? { |pokemon| pokemon.hp == 0 }, "Setup resurrected an exhausted team")
assert(setup_engine.instance_variable_get(:@battlers)[1].stages[:ATTACK] == 1, "Initial watcher setup dropped Boss boosts")

runtime_engine = KIFMultiplayerBossBattle.allocate
runtime_engine.instance_variable_set(:@party1, runtime_parties.flatten)
runtime_engine.instance_variable_set(:@online, OpenStruct.new(:battle => {"players" => %w[host_id guest_id]}))
runtime_engine.instance_variable_set(:@battlers, [])
runtime_engine.instance_variable_set(:@field, OpenStruct.new(:weather => :None, :terrain => :None))
runtime_engine.instance_variable_set(:@turnCount, 4)
runtime_engine.instance_variable_set(:@online_events, [])
def runtime_engine.online_actions(*_args)
  {"moves" => [], "switches" => [], "can_switch" => false, "forced" => false}
end
runtime_state = runtime_engine.online_state("command", [])
assert(runtime_state["team_states"] == KIFMultiplayer.boss_team_states(runtime_parties, %w[host_id guest_id]), "Cooperative resolve omitted reserve runtime state")
assert(runtime_state["team_states"].values.all? { |party| party.length == 3 } && runtime_state["team_states"]["guest_id"][2]["item"].nil?, "Terminal resolve lost consumed reserve item or party member")

detached_battle = battle_document.merge("mode" => "coop_boss", "host_id" => "authority_id", "players" => ["authority_id", "host_id"])
detached_client = FakeClient.new([KIFMultiplayer::Error.new("local guest UI/connection failure", "diagnostic_detach")])
detached_profile = OpenStruct.new(:account => {})
def detached_profile.save; @saved = true; end
detached_client.define_singleton_method(:profile) { detached_profile }
assert_raises(KIFMultiplayer::Error, "Guest error was not surfaced for recovery") do
  KIFMultiplayer.run_boss(detached_client, {"code" => "BOSS123"}, detached_battle)
end
assert(detached_client.calls.all? { |call| call[0] == "GET" }, "Guest local failure aborted the authority's AI-controlled Boss session")
assert(detached_profile.account["boss_detached"]["battle_id"] == detached_battle["battle_id"] && detached_profile.account["boss_detached"]["room_code"] == "BOSS123", "Detached guest lost its recovery identity/room")
broken_authority = battle_document("initializing").merge("turn" => 0, "mode" => "coop_boss", "initial_teams" => {})
aborted_authority = broken_authority.merge("phase" => "finished", "result" => {"abnormal" => true})
authority_error_client = FakeClient.new([{"battle" => broken_authority}, {"battle" => aborted_authority}])
assert_raises(KIFMultiplayer::BattleError, "Broken authority initialization was not surfaced") do
  KIFMultiplayer.run_boss(authority_error_client, {"code" => "BOSS123"}, broken_authority)
end
assert(authority_error_client.calls.any? { |call| call[0] == "POST" && call[1].end_with?("/abort") && call[2]["reason"] == "authority_unrecoverable" }, "Unrecoverable authority stopped aborting its engine session")

puts "PASS: #{$checks} battle + cooperative Boss boundary checks (separate real-game acceptance required)"
