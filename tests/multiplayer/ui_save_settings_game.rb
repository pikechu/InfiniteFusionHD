# Native SaveData regression for temporary online presentation preferences.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  $Trainer.party = [test.pokemon(:PIKACHU, [:TACKLE])]
  $Trainer.save_slot = "UI settings review"
  $PokemonSystem.download_sprites = 0
  $PokemonSystem.shinyadvanced = 1
  original_system = $PokemonSystem
  original_bytes = Marshal.dump(original_system)
  writer = KIFMultiplayer::TradeSave.new
  KIFMultiplayer.with_ui_fonts do
    test.check($PokemonSystem.download_sprites == 1 && $PokemonSystem.shinyadvanced == 2, "online presentation getters use safe downloads and expanded colors")
    test.check(writer.persist, "actual complete registered SaveData written in online scope")
    saved = SaveData.get_data_from_file(writer.path)
    systems = saved.values.select { |value| value.is_a?(PokemonSystem) }
    test.check(!systems.empty?, "actual registered save contains PokemonSystem")
    raw = systems.map { |system| [system.instance_variable_get(:@download_sprites), system.instance_variable_get(:@shinyadvanced)] }
    test.log("UI_SETTINGS_SAVED_RAW #{KIFMultiplayer::WireJSON.dump(raw)}")
    test.check(raw.all? { |entry| entry == [0, 1] }, "temporary online settings never overwrite original preferences on disk")
    test.check($PokemonSystem.equal?(original_system) && Marshal.dump(original_system) == original_bytes, "original settings object and bytes remain unchanged inside scope")
  end
  test.check($PokemonSystem.equal?(original_system) && $PokemonSystem.download_sprites == 0 && $PokemonSystem.shinyadvanced == 1 && Marshal.dump(original_system) == original_bytes, "original single-player preferences restored after scope")
  test.log("UI_SAVE_SETTINGS_NATIVE_PASS")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("UI_SAVE_SETTINGS_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
