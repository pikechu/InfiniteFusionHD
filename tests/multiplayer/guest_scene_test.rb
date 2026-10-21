load File.expand_path("boss_test.rb", __dir__)
class PokeBattle_Scene; end
NB_POKEMON = 500 unless defined?(NB_POKEMON)
module GameData
  class Species
    DATA = {:PIKACHU => true, :BLASTOISE => true}
  end
  class Move
    def self.exists?(value); %w[TACKLE SURF].include?(value); end
  end
end
load File.join(ROOT, "Data/Scripts/054_Multiplayer/014_GuestScene.rb")
public_pokemon = OpenStruct.new(:species => :PIKACHU, :form => 0, :gender => 0)
def public_pokemon.shiny?; false; end
public_pokemon.instance_variable_set(:@owner, "HIDDEN_OWNER")
public_pokemon.instance_variable_set(:@iv, "HIDDEN_IV")
battler = OpenStruct.new(:index => 1, :displayPokemon => public_pokemon, :level => 50,
  :name => "Public Pokemon", :hp => 43, :totalhp => 100, :status => :NONE, :pokemonIndex => 2)
engine = OpenStruct.new(:battlers => [nil, battler])
visual_pokemon = KIFMultiplayer::BattleVisuals.public_pokemon(engine, battler)
assert(visual_pokemon.keys.sort == KIFMultiplayer::BattleVisuals::PUBLIC_KEYS.sort, "Visual Pokemon leaked fields")
assert(!KIFMultiplayer::WireJSON.dump(visual_pokemon).include?("HIDDEN"), "Visual serialization disclosed owner or IV")
KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "move", "move_id" => "TACKLE", "user" => 1, "targets" => [1], "hit" => 0})
visuals = KIFMultiplayer::BattleVisuals.snapshot(engine)
state = {"battlers" => [{"index" => 1}]}
assert(KIFMultiplayer::BattleVisuals.validate(visuals, state)["seq"] == 1, "Public visual batch failed validation")
assert(KIFMultiplayer::BattleVisuals.snapshot(engine)["seq"] == 2, "Visual sequence did not advance per input boundary")
bad = Marshal.load(Marshal.dump(visuals))
bad["events"][0]["targets"] = [2]
assert_raises(KIFMultiplayer::BattleError, "Visual move targeted an unknown slot") { KIFMultiplayer::BattleVisuals.validate(bad, state) }
bad = Marshal.load(Marshal.dump(visuals))
bad["events"][0]["move_id"] = "EXECUTE_ARBITRARY"
assert_raises(KIFMultiplayer::Error, "Unknown visual move accepted") { KIFMultiplayer::BattleVisuals.validate(bad, state) }
bad = Marshal.load(Marshal.dump(visuals))
bad["battlers"][0]["owner"] = "private"
assert_raises(KIFMultiplayer::BattleError, "Hidden Pokemon field accepted") { KIFMultiplayer::BattleVisuals.validate(bad, state) }
bad = Marshal.load(Marshal.dump(visuals))
bad["battlers"][0]["status"] = 99
assert_raises(KIFMultiplayer::BattleError, "Unknown numeric status entered registry fallback") { KIFMultiplayer::BattleVisuals.validate(bad, state) }
129.times { KIFMultiplayer::BattleVisuals.record(engine, {"kind" => "recall", "slot" => 1}) }
overflow = KIFMultiplayer::BattleVisuals.snapshot(engine)
assert(overflow["events"].length == 128 && !overflow["complete"], "Oversized visual batch silently claimed complete animations")
KIFMultiplayer::BattleVisuals.clear(engine)
assert(KIFMultiplayer::BattleVisuals.snapshot(engine)["events"].empty?, "Visual phase repeated previous events")
authority_scene = Object.new
def authority_scene.pbHitAndHPLossAnimation(targets); @actual_hits = targets.length; end
authority_engine = OpenStruct.new(:scene => authority_scene, :battlers => [nil, battler])
KIFMultiplayer::BattleVisuals.attach(authority_engine)
authority_scene.pbHitAndHPLossAnimation([[battler, 100, 4]])
damage_events = authority_engine.instance_variable_get(:@online_visual_events)
assert(damage_events == [{"kind" => "hp", "slot" => 1, "from" => 100, "to" => 43, "totalhp" => 100}], "Direct attack HP animation was omitted from timeline")
assert(authority_scene.instance_variable_get(:@actual_hits) == 1, "Visual recording changed authority scene execution")
public_pokemon.instance_variable_set(:@sprite_scale, "unsupported cosmetic")
base_state = {"battlers" => [{"index" => 1}], "events" => ["legal combat result"]}
assert(KIFMultiplayer::BattleVisuals.merge_state(engine, base_state) == base_state, "Cosmetic serialization failure aborted authority state")
public_pokemon.instance_variable_set(:@sprite_scale, nil)
scaffold = KIFMultiplayer::VisualBattleScaffold.allocate
assert_raises(KIFMultiplayer::BattleError, "Observer executed damage") { scaffold.pbAttackPhase }
assert_raises(KIFMultiplayer::BattleError, "Observer executed move effects") { scaffold.pbEndOfRoundPhase }
display_pokemon = KIFMultiplayer::PublicVisualPokemon.new
display_pokemon.freeze_visual_capacity({"level" => 50, "totalhp" => 372, "hp" => 61})
3.times { display_pokemon.calc_stats }
assert(display_pokemon.hp == 61 && display_pokemon.totalhp == 372, "Local public Pokemon stat recalculation replaced authoritative HP")
animation_scene = KIFMultiplayer::GuestNativeScene.allocate
def animation_scene.pbFindMoveAnimation(*_args); [0, false]; end
def animation_scene.pbLoadBattleAnimations; [nil]; end
assert(!animation_scene.visual_animation_available?(:TACKLE, 0, 0), "Missing animation DB entry was reported as native playback")

client = FakeClient.new([])
old_update = proc { raise "Disposed/overworld update must not run inside observer" }
client.wait_update = old_update
session = KIFMultiplayer::BattleSession.new(client, battle_document)
references = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
bytes = Marshal.dump(references)
old_scene = $scene
assert_raises(RuntimeError, "Observer exception not propagated") do
  KIFMultiplayer::GuestBattlePresenter.with(session) do
    assert(!$Trainer.equal?(references[0]), "Observer retained main trainer object")
    $Trainer.data << :visual_mutation
    $PokemonGlobal.data << :cosmetic_clock
    assert(!$scene.equal?(old_scene), "Observer allowed main-map miniupdate")
    raise "abort visual playback"
  end
end
assert(Marshal.dump(references) == bytes && $scene.equal?(old_scene), "Observer modified main globals or map scene")
assert(client.wait_update.equal?(old_update) && session.presenter.nil?, "Observer leaked its scene callback")
wait_scene = Object.new
def wait_scene.pbGraphicsUpdate; @graphics = (@graphics || 0) + 1; end
def wait_scene.pbFrameUpdate; @frames = (@frames || 0) + 1; end
def wait_scene.pbUpdate; raise "Full scene input update must not run in network pump"; end
wait_session = Object.new
def wait_session.heartbeat; @beats = (@beats || 0) + 1; end
KIFMultiplayer.battle_wait_update(wait_scene, wait_session).call
assert(wait_scene.instance_variable_get(:@graphics) == 1 && wait_scene.instance_variable_get(:@frames) == 1 && wait_session.instance_variable_get(:@beats) == 1, "Network scene pumping swallowed input or lost heartbeat")
puts "PASS: #{$checks} battle/Boss/native-guest contract checks; real native rendering is separate"
