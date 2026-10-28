# Native UI probe with the production Chinese pack and isolated save folder.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  check = KIFMultiplayerFeatureTest.method(:check)
  directory = File.expand_path(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")).tr("\\", "/")
  check.call(File.file?("Data/messages_zh.dat"), "production Chinese pack is installed")
  $PokemonSystem.language = 0
  $Trainer.name = "语言测试"
  pokemon = Pokemon.new(:BULBASAUR, 12, $Trainer)
  fusion = Pokemon.new(:B4H1, 12, $Trainer)
  nickname = Pokemon.new(:PIKACHU, 12, $Trainer)
  nickname.name = "Keepsake"
  original_names = [pokemon.name, fusion.name]
  serialized = Marshal.dump([pokemon, fusion, nickname, pokemon.species_data, fusion.species_data])
  check.call(Font.exist?("Noto Sans SC"), "bundled Chinese font is registered by Game.exe")
  scene = PokemonOption_Scene.new
  scene.pbStartScene(true)
  GameLanguage.define_singleton_method(:choose) { 2 }
  scene.chooseLanguage
  options = scene.instance_variable_get(:@PokemonOptions)
  check.call($PokemonSystem.language == 2 && options.first.name == "语言: 简体中文", "live settings switch to Chinese and refresh labels")
  check.call(scene.instance_variable_get(:@sprites)["option"].active, "rebuilt options remain interactive")
  check.call(pokemon.name == "妙蛙种子" && fusion.name == "妙蛙火龙", "base and fusion names use Chinese without replacing species data")
  check.call(nickname.name == "Keepsake", "player nicknames are preserved")
  check.call(GameData::Move.get(:TACKLE).name.match?(/[\u3400-\u9fff]/), "moves use the production Chinese table")
  check.call(GameData::Item.get(:POTION).name.match?(/[\u3400-\u9fff]/), "items use the production Chinese table")
  check.call(pokemon.species_data.pokedex_entry.match?(/[\u3400-\u9fff]/), "species entries use the production Chinese table")
  check.call(_INTL("What will {1} do?", "TEST").include?("TEST"), "battle prompt retains its argument")
  check.call(Marshal.dump([pokemon, fusion, nickname, pokemon.species_data, fusion.species_data]) == serialized, "language switches leave Pokemon, stats and cached species data unchanged")
  Graphics.update
  Graphics.screenshot(File.join(directory, "options-zh.png"))
  scene.pbEndScene
  summary = PokemonSummary_Scene.new
  summary.pbStartScene([pokemon, fusion], 0)
  Graphics.update
  Graphics.screenshot(File.join(directory, "summary-zh.png"))
  summary.pbEndScene
  saved = Marshal.load(Marshal.dump($PokemonSystem))
  $PokemonSystem.language = 0
  $PokemonSystem.load_bootup_data(saved)
  GameLanguage.load($PokemonSystem.language)
  check.call(_INTL("Options") == "设置" && MessageConfig.pbGetSystemFontName == "Noto Sans SC", "saved language and Chinese font restore together")
  remaining = []
  previous_scene = $scene
  $scene = Scene_Map.allocate # Build in-game options without running map events.
  [VanillaOptSc_1, KurayOptSc_1, KurayOptSc_2, KurayOptSc_3, KurayOptSc_4, KurayOptSc_5, KurayOptSc_6].each do |klass|
    screen = klass.new
    options = screen.pbGetOptions(false)
    options.each do |option|
      texts = [option.name]
      texts.concat(option.values) if option.respond_to?(:values)
      texts.concat(Array(option.description)) if option.respond_to?(:description)
      texts.each do |value|
        translated = _INTL(value.to_s)
        remaining << [klass.name, translated] if translated.match?(/[A-Za-z]/) && !translated.match?(/[\u3400-\u9fff]/)
      end
    end
  end
  $scene = previous_scene
  File.write(File.join(directory, "settings-remaining.json"), KIFMultiplayer::WireJSON.dump(remaining.uniq))
  check.call(KurayOptSc_1.new.pbGetOptions(false).any? { |option| option.name == "异色动画" }, "KIF settings use supplementary translations")
  check.call(_INTL("Load {1}", "CUSTOM") == "读取CUSTOM", "preset names remain untouched in translated prompts")
  shiny_scene = KurayOptSc_1.new
  shiny_scene.pbStartScene(false)
  Graphics.update
  Graphics.screenshot(File.join(directory, "settings-shiny-zh.png"))
  shiny_scene.pbEndScene
  $game_variables[12] = "小茂"
  dialogue_window = pbCreateMessageWindow
  [[43, "Oh yes, that's right! Well I'm sure that you and \\V[12] will have a ton of fun on your Pokémon journey together!", "mom"],
   [77, "You'll get one too, Blue. Be patient!", "oak"],
   [95, "I'll let you know if I find anything, \\PN. That is, if I haven't already taken down their whole organization by the next time I see you!", "rival"]].each do |map, text, name|
    translated = _MAPINTL(map, text)
    check.call(translated.match?(/[\u3400-\u9fff]/), "native #{name} dialogue uses Chinese")
    if name == "mom"
      layout = getFormattedText(dialogue_window.contents, 0, 0, 300, -1, "<b>" + translated + "</b>")
      check.call(layout.any? { |character| character[2] > 0 } && layout.all? { |character| character[0] == "\n" || character[1] + character[3] <= 302 }, "formatted Chinese dialogue wraps within its window")
    end
    pbMessageDisplay(dialogue_window, translated, false)
    Graphics.update
    Graphics.screenshot(File.join(directory, name + "-dialogue-zh.png"))
  end
  pbDisposeMessageWindow(dialogue_window)
  load "tests/localization/quest_dialogue_game.rb"
  GameLanguage.load(1)
  check.call(pbGetMessage(MessageTypes::Species, 1) == "Bulbizarre", "native French language data")
  scene = PokemonOption_Scene.new
  scene.pbStartScene(true)
  Graphics.update
  Graphics.screenshot(File.join(directory, "options-fr.png"))
  scene.pbEndScene
  GameLanguage.load(0)
  check.call(KurayOptSc_1.new.pbGetOptions(false).any? { |option| option.name == "Shiny Animation" }, "KIF settings restore original English labels")
  check.call([pokemon.name, fusion.name] == original_names, "English species and fusion names restore immediately")
  check.call(pbGetMessage(MessageTypes::Species, 1) == "Bulbasaur", "native English language data restored")
  scene = PokemonOption_Scene.new
  scene.pbStartScene(true)
  Graphics.update
  Graphics.screenshot(File.join(directory, "options-en.png"))
  scene.pbEndScene
  KIFMultiplayerFeatureTest.log("LANGUAGE_NATIVE_PASS normal_player_saves=false production_chinese_pack=true")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("LANGUAGE_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
