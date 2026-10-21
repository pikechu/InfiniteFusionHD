passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test, directory = KIFMultiplayerFeatureTest, ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  old_system, old_palette = $PokemonSystem, $PokemonSystem.shinyadvanced
  actual = nil
  KIFMultiplayer::BattleIsolation.with do
    pokemon = Pokemon.new(:PIKACHU, 50, nil, false, false)
    pokemon.shiny = true
    pokemon.instance_variable_set(:@shinyR, 24)
    pokemon.instance_variable_set(:@shinyG, 23)
    pokemon.instance_variable_set(:@shinyB, 22)
    actual = [pokemon.shinyR?, pokemon.shinyG?, pokemon.shinyB?]
    test.log("NATIVE_SHINY_CHANNELS expected=24,23,22 actual=#{actual.join(',')} temporary_palette=#{$PokemonSystem.shinyadvanced}")
    test.check(actual == [24, 23, 22], "expanded public shiny-channel getters preserve all validated fields")
  end
  test.check($PokemonSystem.equal?(old_system) && $PokemonSystem.shinyadvanced == old_palette, "original shiny options restored")
  File.write(File.join(directory, "shiny-palette-evidence.json"), KIFMultiplayer::WireJSON.dump({"pid" => Process.pid,
    "channels" => actual, "original_palette" => old_palette, "finished" => true}))
  test.log("SHINY_PALETTE_NATIVE_PASS")
  passed = true
rescue Exception => error
  $kif_test_log.call("SHINY_PALETTE_NATIVE_FAIL #{error.class}: #{error.message}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
