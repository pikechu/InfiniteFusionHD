# Actual battle/move objects in the native runtime, without loading player saves.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  check = KIFMultiplayerFeatureTest.method(:check)
  scene = Object.new
  def scene.pbChangePokemon(*); end
  def scene.pbAnimation(*); end
  def scene.pbRefreshOne(*); end
  trainer = NPCTrainer.new("Hail fixture", $Trainer.trainer_type)
  attacker = Pokemon.new(:MEWTWO, 50, $Trainer)
  defender = Pokemon.new(:GLACEON, 50, trainer)
  trainer.party = [defender]
  battle = PokeBattle_Battle.new(scene, [attacker], [defender], $Trainer, trainer)
  battle.internalBattle = false
  battle.setBattleMode("single")
  battle.pbEnsureParticipants
  battle.pbSetUpSides
  battle.field.weather = :Hail
  user, target = battle.battlers.values_at(0, 1)
  $PokemonSystem.damage_variance = 0
  checks = 0
  [nil, 0, 1, 2].each do |mode|
    $PokemonSystem.modernhail = mode
    {TACKLE: [1.0, 1.5], PSYCHIC: [1.0, 1.0], PSYSHOCK: [1.0, 1.5],
     PSYSTRIKE: [1.0, 1.5], SECRETSWORD: [1.0, 1.5]}.each do |id, expected|
      move = PokeBattle_Move.from_pokemon_move(battle, Pokemon::Move.new(id))
      original = move.function.dup
      multipliers = {base_damage_multiplier: 1.0, attack_multiplier: 1.0,
        defense_multiplier: 1.0, final_damage_multiplier: 1.0}
      move.pbCalcDamageMultipliers(user, target, 1, move.type, move.baseDamage, multipliers)
      check.call(multipliers[:defense_multiplier] == expected[(mode == 1 || mode == 2) ? 1 : 0], "native #{id} hail defense mode=#{mode.inspect}")
      check.call(move.function == original, "native #{id} retains function #{original} mode=#{mode.inspect}")
      checks += 2
    end
  end
  KIFMultiplayerFeatureTest.log("HAIL_DAMAGE_NATIVE_PASS checks=#{checks} player_saves=false")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("HAIL_DAMAGE_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
