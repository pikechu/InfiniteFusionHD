# Real initialized Game probe. No connection or player save is read/written.
# Generic Snapshot.export deliberately retains single-player presentation;
# battle candidate snapshots must use the separate standard-rules exporter.
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  checks = 0
  verify = lambda do |condition, name|
    test.check(condition, name)
    checks += 1
  end
  snapshot = KIFMultiplayer::Snapshot
  verify.call(snapshot.respond_to?(:export_for_battle), "dedicated standard-rules team exporter is loaded from production source")
  pokemon = Pokemon.new(:B1H4, 75, $Trainer, false, false)
  pokemon.moves = [Pokemon::Move.new(:TACKLE)]
  pokemon.personalID = 1
  pokemon.instance_variable_set(:@ability, nil)
  pokemon.instance_variable_set(:@ability_index, 1)
  pokemon.instance_variable_set(:@ability2, nil)
  pokemon.instance_variable_set(:@ability2_index, nil)
  original_bytes = Marshal.dump(pokemon)
  original_globals = [$PokemonSystem, $game_switches, $game_variables]
  generic, standard = [], []
  begin
    [false, true].each do |no_levels|
      [false, true].each do |double|
        [[0, 0], [1, 0], [3, 1], [3, 2]].each do |cap, behavior|
          $game_switches[SWITCH_NO_LEVELS_MODE] = no_levels
          $game_switches[SWITCH_DOUBLE_ABILITIES] = double
          $PokemonSystem.kuraylevelcap = cap
          $PokemonSystem.levelcapbehavior = behavior
          refs = [$PokemonSystem, $game_switches, $game_variables]
          bytes = refs.map { |value| Marshal.dump(value) }
          observed = snapshot.export(pokemon)
          normalized = snapshot.export_for_battle(pokemon)
          generic << observed
          standard << normalized
          tag = "no_levels=#{no_levels} double=#{double} cap=#{cap}/#{behavior}"
          test.log("SNAPSHOT_RULES_CASE #{tag} generic_level=#{observed['level']} generic_ability=#{observed['ability']} generic_ability2=#{observed['ability2'].inspect} standard_level=#{normalized['level']} standard_ability=#{normalized['ability']} standard_ability2=#{normalized['ability2'].inspect}")
          verify.call(Marshal.dump(pokemon) == original_bytes, "original Pokemon raw fields unchanged #{tag}")
          restored = [$PokemonSystem, $game_switches, $game_variables]
          verify.call(restored.each_with_index.all? { |value, index| value.equal?(refs[index]) } && restored.map { |value| Marshal.dump(value) } == bytes,
            "standard team export restores settings/switches/variables identity and bytes #{tag}")
          verify.call(normalized == standard.first, "standard team snapshot is identical #{tag}")
        end
      end
    end
    verify.call(generic.map { |value| value["ability"] }.uniq.sort == %w[BLAZE OVERGROW], "generic shared export reproduces local NO_LEVELS primary ability variation")
    verify.call(generic.map { |value| value["ability2"] }.uniq.length > 1, "generic shared export reproduces local DOUBLE_ABILITIES variation")
    verify.call(generic.map { |value| value["level"] }.uniq.length > 1, "generic shared export reproduces local level-cap variation")
    verify.call(standard.first["level"] == 75 && standard.first["ability"] == "BLAZE" && standard.first["ability2"].nil?, "standard team export uses uncapped ordinary inherited primary and single-ability rules")
    invalid = pokemon.clone
    invalid.instance_variable_set(:@steps_to_hatch, 1)
    refs = [$PokemonSystem, $game_switches, $game_variables]
    bytes = refs.map { |value| Marshal.dump(value) }
    error = nil
    begin; snapshot.export_for_battle(invalid); rescue KIFMultiplayer::Error => failure; error = failure; end
    verify.call(error && error.code == "invalid_pokemon", "invalid battle Pokemon is rejected through the real validator")
    restored = [$PokemonSystem, $game_switches, $game_variables]
    verify.call(restored.each_with_index.all? { |value, index| value.equal?(refs[index]) } && restored.map { |value| Marshal.dump(value) } == bytes,
      "exception restores all three original globals and their bytes")
    verify.call(Marshal.dump(pokemon) == original_bytes, "exception leaves original individual unchanged")
  ensure
    $PokemonSystem, $game_switches, $game_variables = original_globals
  end
  test.log("SNAPSHOT_RULES_NATIVE_PASS checks=#{checks} ruby=#{RUBY_VERSION}")
  exit!(0)
rescue Exception => error
  KIFMultiplayerFeatureTest.log("SNAPSHOT_RULES_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join('\n')}") if defined?(KIFMultiplayerFeatureTest)
  exit!(1)
end
