# Contract tests for the network adapter. Real engine/process checks are a
# separate acceptance test; these stubs do not claim to simulate Pokemon combat.
require "json"
require "digest"
require "ostruct"

class PokeBattle_Battle
  def pbCanShowCommands?(_index); true; end
  def pbCanChooseMove?(_index, move, _messages); move == 0; end
  def pbRegisterMove(index, move, _messages); @registered = [index, move]; true; end
  def pbRegisterTarget(index, target); @targets ||= {}; @targets[index] = target; end
  def pbCanShowFightMenu?(_index); true; end
  def pbRegisterSwitch(_index, party); party == 1; end
  def pbCanSwitchLax?(_index, party); party == 1; end
  def pbCanSwitch?(_index, party); party == 1; end
  def pbClearChoice(_index); end
  def pbEndOfBattle; raise "Unsafe base ending called"; end
end

class PokemonSystem
  attr_accessor :textspeed, :damage_variance, :custom_bst, :download_sprites, :shinyadvanced
  def initialize
    @textspeed, @damage_variance, @custom_bst, @download_sprites, @shinyadvanced = 1, 1, 0, 0, 1
  end
end

class TestState
  attr_accessor :data
  def initialize; @data = []; end
end

ROOT = File.expand_path("../..", __dir__)
load File.join(ROOT, "Data/Scripts/054_Multiplayer/001_Client.rb")
load File.join(ROOT, "Data/Scripts/054_Multiplayer/003_Battle.rb")

$checks = 0
def assert(condition, message)
  raise message unless condition
  $checks += 1
end
def assert_raises(klass, message)
  begin
    yield
  rescue klass
    $checks += 1
    return
  end
  raise message
end

class FakeClient
  attr_accessor :wait_update
  attr_reader :calls
  def initialize(responses)
    @responses = responses
    @calls = []
  end
  def player_id; "host_id"; end
  def pump; end
  def request(*args)
    @calls << args
    response = @responses.shift
    raise response if response.is_a?(Exception)
    raise "No fixture for #{args.inspect}" unless response
    response
  end
end

def battle_document(phase = "commands")
  {"battle_id" => "b_test_0001", "host_id" => "host_id", "players" => ["host_id", "guest_id"],
   "turn" => 1, "phase" => phase, "submitted" => [], "snapshot" => {}}
end

# Original object identity and contents survive both success and exceptions.
$Trainer, $PokemonBag, $PokemonGlobal = TestState.new, TestState.new, TestState.new
$PokemonSystem = PokemonSystem.new
$PokemonSystem.custom_bst = 7
$game_switches, $game_variables = TestState.new, TestState.new
originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
original_bytes = originals.map { |item| Marshal.dump(item) }
assert_raises(RuntimeError, "Expected intentional interruption") do
  KIFMultiplayer::BattleIsolation.with do
    assert(!$Trainer.equal?(originals[0]), "Original trainer was exposed")
    assert(!$PokemonBag.equal?(originals[1]), "Original bag was exposed")
    assert(!$PokemonGlobal.equal?(originals[2]), "Original global metadata was exposed")
    assert($PokemonSystem.custom_bst == 0, "Battle retained custom stat settings")
    assert($PokemonSystem.damage_variance == 1, "Standard random damage disabled")
    assert($PokemonSystem.download_sprites == 1, "Native sprite downloads remained enabled during isolated battle")
    assert($PokemonSystem.shinyadvanced == 2, "Validated expanded shiny channels may be randomized during presentation")
    $Trainer.data << :changed
    $PokemonBag.data << :consumed
    $PokemonGlobal.data << :world_progress
    $game_switches.data << :autosave
    $game_variables.data << :quest
    raise "intentional interruption"
  end
end
current = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
assert(current.each_with_index.all? { |value, i| value.equal?(originals[i]) }, "Global references not restored")
assert(current.map { |item| Marshal.dump(item) } == original_bytes, "Main save data changed")
assert($PokemonSystem.download_sprites == 0, "Original sprite-download preference was not restored after error")
assert($PokemonSystem.shinyadvanced == 1, "Original shiny palette option was not restored after error")
KIFMultiplayer::BattleIsolation.with do
  assert($PokemonSystem.download_sprites == 1, "Normal battle did not disable native sprite HTTP")
  assert($PokemonSystem.shinyadvanced == 2, "Normal battle can rewrite expanded shiny colors")
end
assert($PokemonSystem.equal?(originals[3]) && $PokemonSystem.download_sprites == 0, "Original settings were not restored after normal exit")

# Scene and map lifetime also survives exceptions; the generic game wrappers
# do not restore these fields themselves when their yielded block raises.
module Graphics
  def self.frame_reset; end
end
class Scene_Map
  attr_reader :hidden, :restored, :disposed_in_map_scene
  def disposeSpritesets; @hidden = true; @disposed_in_map_scene = $scene.equal?(self); end
  def createSpritesets; @restored = true; end
end
class FakeAudio
  attr_reader :resumed
  def getPlayingBGM; "overworld"; end
  def bgm_pause; end
  def bgm_resume(value); @resumed = value; end
end
class FakeDisposable
  attr_reader :disposed
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
$game_temp = OpenStruct.new(:in_battle => false)
$PokemonTemp = OpenStruct.new(:forced_alt_sprites => :original)
$game_system = FakeAudio.new
$scene = Scene_Map.new
original_map_scene = $scene
presentation_exposes_map = nil
presentation_scene = Object.new
viewport = FakeDisposable.new
sprite = FakeDisposable.new
presentation_scene.instance_variable_set(:@viewport, viewport)
presentation_scene.instance_variable_set(:@sprites, {"test" => sprite})
assert_raises(RuntimeError, "Scene test did not interrupt") do
  KIFMultiplayer::BattlePresentation.with(presentation_scene) do
    assert($game_temp.in_battle, "Battle flag was not set")
    presentation_exposes_map = $scene.is_a?(Scene_Map)
    raise "interrupted engine"
  end
end
assert(!$game_temp.in_battle && $PokemonTemp.forced_alt_sprites == :original, "Overworld flags were not restored")
assert($scene.hidden && $scene.restored, "Map sprites were not recreated")
assert(viewport.disposed && sprite.disposed, "Battle graphics leaked")
assert($game_system.resumed == "overworld", "Overworld audio not restored")
assert($scene.equal?(original_map_scene), "Original map scene identity was not restored")
assert(original_map_scene.disposed_in_map_scene, "Map disposal could not release its original renderer references")
assert(presentation_exposes_map == false, "Native confirmation windows can still update the original overworld")
normal_audio = $game_system
failing_audio = FakeAudio.new
def failing_audio.bgm_resume(_value); raise "intentional audio restore failure"; end
$game_system = failing_audio
$scene = failed_audio_scene = Scene_Map.new
assert_raises(RuntimeError, "Audio restoration failure was not reported") do
  KIFMultiplayer::BattlePresentation.with(presentation_scene) { nil }
end
assert($scene.equal?(failed_audio_scene) && failed_audio_scene.restored && !$game_temp.in_battle,
       "Audio failure prevented original scene/flag/sprites from being restored")
assert_raises(KIFMultiplayer::ServerTerminal, "Cleanup error replaced official terminal signal") do
  KIFMultiplayer::BattlePresentation.with(presentation_scene) { raise KIFMultiplayer::ServerTerminal }
end
assert($scene.equal?(failed_audio_scene) && failed_audio_scene.restored, "Terminal with failed cleanup leaked map scene")
$game_system = normal_audio
assert_raises(KIFMultiplayer::ServerTerminal, "Official terminal signal did not unwind isolated presentation") do
  KIFMultiplayer::BattleIsolation.with do
    KIFMultiplayer::BattlePresentation.with(presentation_scene) { raise KIFMultiplayer::ServerTerminal }
  end
end
assert(!$game_temp.in_battle && $PokemonTemp.forced_alt_sprites == :original, "Official terminal signal leaked presentation state")
assert([$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables].each_with_index.all? { |value, i| value.equal?(originals[i]) }, "Official terminal signal did not restore original globals")

# Guest sees only its own legal input list, and forced turns require no menu.
state = {"kind" => "command", "phase_owner_ids" => ["guest_id"], "actions" => {
  "guest_id" => {"moves" => [{"index" => 2, "name" => "Tackle", "pp" => 10, "total_pp" => 35}],
                  "switches" => [{"party_index" => 1, "name" => "Backup", "hp" => 50, "totalhp" => 80}], "forced" => false},
  "host_id" => {"moves" => [{"index" => 0, "name" => "SECRET", "pp" => 3, "total_pp" => 5}]}}}
options = KIFMultiplayer::BattleInput.choices(state, "guest_id")
assert(options.length == 3, "Move, switch and forfeit missing")
assert(options.none? { |entry| entry[0].include?("SECRET") }, "Input menu exposed opponent move")
assert(options[0][1] == {"action" => "move", "move_index" => 2, "target" => -1}, "Move structure changed")
assert(KIFMultiplayer::BattleInput.choices(state, "host_id")[0][1] == {"action" => "wait"}, "Non-owner may act")
state["actions"]["guest_id"]["moves"] = []
state["actions"]["guest_id"]["forced"] = true
assert(KIFMultiplayer::BattleInput.choices(state, "guest_id").any? { |entry| entry[1]["action"] == "forced" }, "Struggle/forced action unavailable")

# An uncertain POST first queries its recorded operation, and never submits a
# different request ID or operation assuming that timeout means failure.
locked = battle_document("locked").merge("submitted" => ["host_id", "guest_id"])
client = FakeClient.new([KIFMultiplayer::UncertainRequest.new("timeout"),
                        {"ok" => true, "response" => {"ok" => true, "battle" => locked}}])
session = KIFMultiplayer::BattleSession.new(client, battle_document)
session.submit({"action" => "move", "move_index" => 0, "target" => -1})
assert(client.calls.map { |call| call[0] } == ["POST", "GET"], "Uncertain POST was retried before operation query")
request_id = client.calls[0][2]["request_id"]
assert(request_id.match?(/\A[A-Za-z0-9_-]{8,100}\z/), "Operation ID is not an allowed wire identifier")
assert(client.calls[1][1] == "/v1/operations/#{request_id}", "Wrong recovery operation queried")
assert(session.battle["phase"] == "locked", "Committed command was not recovered")

# Duplicate local retries retain their operation ID.
client = FakeClient.new([{ "battle" => locked }, { "battle" => locked }])
session = KIFMultiplayer::BattleSession.new(client, battle_document)
2.times { session.submit({"action" => "wait"}) }
assert(client.calls[0][2]["request_id"] == client.calls[1][2]["request_id"], "Retry changed operation identity")

# Hash is a content digest, not Ruby's process-randomized Object#hash.
digest = KIFMultiplayer.battle_digest({"hp" => 10, "status" => "POISON"})
assert(digest == Digest::SHA256.hexdigest('{"hp":10,"status":"POISON"}'), "Incorrect content digest")
assert(digest != KIFMultiplayer.battle_digest({"hp" => 11, "status" => "POISON"}), "Digest ignores state change")
assert(KIFMultiplayer.battle_text('enemy\\wtnp[999999]<img=test>') == 'enemy＼wtnp[999999]＜img=test＞', "Remote text can execute RGSS formatting commands")

# Service settlement is read in the same host-oriented convention on both ends.
session.adopt({"battle" => battle_document("finished").merge("result" => {"winner_id" => "guest_id", "abnormal" => false})})
assert(session.result_decision == 2, "Guest victory was reported as host victory")
session.adopt({"battle" => battle_document("finished").merge("result" => {"winner_id" => nil, "abnormal" => true})})
assert(session.result_decision == 0, "Abnormal termination acquired a winner")
session.adopt({"battle" => battle_document("commands")})
assert(session.terminal?, "An older response rewound a finished battle")

# Server terminal state discovered by a scene heartbeat must immediately unwind
# animation/move internals, without being swallowed as a normal engine error.
official_win = battle_document("finished").merge("result" => {"winner_id" => "host_id", "abnormal" => false, "reason" => "disconnect_timeout"})
heartbeat_client = FakeClient.new([{"battle" => official_win}])
heartbeat_session = KIFMultiplayer::BattleSession.new(heartbeat_client, battle_document("locked"))
heartbeat_session.instance_variable_set(:@next_heartbeat, Time.now - 1)
assert_raises(KIFMultiplayer::ServerTerminal, "Heartbeat continued after official settlement") do
  begin
    heartbeat_session.heartbeat
  rescue StandardError
    raise "Official settlement was converted to a normal engine error"
  end
end
assert(heartbeat_session.result_decision == 1, "Heartbeat lost official winner")
def pbCreateMessageWindow
  $terminal_test_window = FakeDisposable.new
end
def pbMessageDisplay(*_args)
  raise KIFMultiplayer::ServerTerminal
end
def pbDisposeMessageWindow(window)
  window.dispose
end
assert_raises(KIFMultiplayer::ServerTerminal, "Battle-log terminal signal was swallowed") { heartbeat_session.message("test") }
assert($terminal_test_window.disposed, "Terminal heartbeat leaked the guest battle-log window")

# The top-level handler presents that same official result rather than aborting
# it or returning the obsolete local/guest decision.
terminal_input = official_win.merge("host_id" => "other_id", "players" => ["other_id", "host_id"],
                                  "result" => {"winner_id" => "other_id", "abnormal" => false})
terminal_client = FakeClient.new([KIFMultiplayer::ServerTerminal.new])
KIFMultiplayer.battle_controller = proc { |_state, _id| {"action" => "wait"} }
assert(KIFMultiplayer.run_battle(terminal_client, nil, terminal_input) == 1, "Top-level terminal handler returned a local result")
assert(terminal_client.calls.none? { |call| call[0] == "POST" }, "Already settled match was aborted or overwritten")
KIFMultiplayer.battle_controller = nil

# The engine validates locked external moves and replacements again. These
# assertions deliberately test the adapter boundary, not mocked battle damage.
class BoundaryEngine < KIFMultiplayerBattle
  attr_accessor :test_commands
  def online_boundary(*_args); @test_commands; end
  def online_legal_targets(_index, _move); [-1]; end
end
engine = BoundaryEngine.allocate
engine.instance_variable_set(:@online, OpenStruct.new(:battle => {"players" => ["host_id", "guest_id"]}))
engine.instance_variable_set(:@scene, OpenStruct.new)
def engine.scene_begin; end
scene = Object.new
def scene.pbBeginCommandPhase; end
def scene.pbEndBattle(decision); @ended = decision; end
def scene.ended; @ended; end
engine.instance_variable_set(:@scene, scene)
engine.instance_variable_set(:@battlers, [Object.new, Object.new])
engine.instance_variable_set(:@online_events, [])
engine.test_commands = {"host_id" => {"action" => "move", "move_index" => 0, "target" => -1},
                        "guest_id" => {"action" => "move", "move_index" => 3, "target" => -1}}
assert_raises(KIFMultiplayer::BattleError, "Illegal remote move accepted") { engine.pbCommandPhase }
engine.test_commands["guest_id"] = {"action" => "move", "move_index" => 0, "target" => 99}
assert_raises(KIFMultiplayer::BattleError, "Invalid remote target accepted") { engine.pbCommandPhase }
engine.test_commands["guest_id"] = {"action" => "switch", "party_index" => 2}
assert_raises(KIFMultiplayer::BattleInterrupted, "Illegal replacement accepted") { engine.pbSwitchInBetween(1, true) }
begin
  begin
    engine.pbSwitchInBetween(1, true)
  rescue StandardError
    raise "Engine inner error wrapper swallowed an online interruption"
  end
rescue KIFMultiplayer::BattleInterrupted => error
  assert(error.original.is_a?(KIFMultiplayer::BattleError), "Original rejection lost while unwinding engine")
end
engine.test_commands["guest_id"] = {"action" => "switch", "party_index" => 1}
assert(engine.pbSwitchInBetween(1, true) == 1, "Legal remote replacement rejected")
engine.test_commands["guest_id"] = {"action" => "forced"}
assert_raises(KIFMultiplayer::BattleError, "Forced command bypassed legal move") { engine.pbCommandPhase }

class FailingPhaseEngine < KIFMultiplayerBattle
  attr_reader :attacked
  def pbCommandPhase; raise KIFMultiplayer::BattleError, "desynchronized command"; end
  def pbAttackPhase; @attacked = true; end
end
failing_engine = FailingPhaseEngine.allocate
assert_raises(KIFMultiplayer::BattleError, "Phase failure was swallowed") { failing_engine.pbBattleLoop }
assert(!failing_engine.attacked, "Attack continued after rejected network command")

# No base ending means no base autosave, rewards or rematch mutation.
engine.instance_variable_set(:@online_pending, false)
engine.instance_variable_set(:@decision, 2)
engine.instance_variable_set(:@turnCount, 3)
assert(engine.pbEndOfBattle == 2 && scene.ended == 2, "Safe ending failed")

# A host finish attempt can discover an already committed opposite result or
# abnormal ending. Only the official result may reach the scene and caller.
[["host_id", false, 2, 1], ["guest_id", false, 1, 2], [nil, true, 1, 0]].each do |winner, abnormal, local, expected|
  document = battle_document("finished").merge("result" => {"winner_id" => winner, "abnormal" => abnormal})
  finish_client = FakeClient.new([{"battle" => document}])
  finish_session = KIFMultiplayer::BattleSession.new(finish_client, battle_document("locked"))
  engine.instance_variable_set(:@online, finish_session)
  engine.instance_variable_set(:@online_pending, true)
  engine.instance_variable_set(:@online_random, [])
  engine.instance_variable_set(:@decision, local)
  def engine.online_state(*_args); {}; end
  assert(engine.pbEndOfBattle == expected && scene.ended == expected, "Local finish overwrote official winner/abnormal result")
  before_count = finish_client.calls.length
  engine.instance_variable_set(:@online_pending, true)
  engine.instance_variable_set(:@decision, local)
  assert(engine.pbEndOfBattle == expected && finish_client.calls.length == before_count, "Repeated ending resubmitted official settlement")
end
engine.online_log("Hello\nworld\r\n")
assert(engine.instance_variable_get(:@online_events).last == "Hello world  ", "Control characters entered network events")

puts "PASS: #{$checks} multiplayer battle adapter checks (no game engine simulation)"
