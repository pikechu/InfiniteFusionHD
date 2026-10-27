# Native rendering/menu regression with isolated test saves and no HTTP.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  log = KIFMultiplayerFeatureTest.method(:log)
  check = KIFMultiplayerFeatureTest.method(:check)
  resources = KIF::OfflineResources
  catalog = resources.parse(File.binread(resources::MANIFEST))
  check.call(catalog["files"].length > 3800, "native parser loads complete resource manifest")
  resource_cache = File.join(directory, "resources")
  resources.send(:remove_const, :CACHE)
  resources.const_set(:CACHE, resource_cache)
  entry = catalog["files"].find { |row| row["kind"] == "image" && !row["path"].include?("spritesheets") && File.file?(row["path"]) }
  check.call(!entry.nil?, "native checksum fixture is a bundled sprite")
  resources.instance_variable_set(:@manifest, catalog.merge("files" => [entry]))
  resources.instance_variable_set(:@state, {})
  resources.define_singleton_method(:fetch) { |*| raise "Native rendering test must never contact the network" }
  GameLanguage.load(2)
  original_window = Window_UnformattedTextPokemon.method(:newWithSize)
  Window_UnformattedTextPokemon.define_singleton_method(:newWithSize) do |*args|
    window = original_window.call(*args)
    original_dispose = window.method(:dispose)
    window.define_singleton_method(:dispose) do
      Graphics.update
      image = Graphics.snap_to_bitmap
      image.save_to_png(File.join(directory, "resource-progress.png"))
      image.dispose
      original_dispose.call
    end
    window
  end
  failures = KIFMultiplayer.with_ui_fonts { resources.run(true) }
  Window_UnformattedTextPokemon.define_singleton_method(:newWithSize, original_window)
  check.call(failures.empty?, "native SHA1 checksum and integrity progress window pass")
  check.call(File.file?(File.join(resource_cache, "state.json")), "native resource receipt stays inside isolated test storage")
  check.call(resources.installed?, "native completed pack enables local-first loading")

  KIFMultiplayer::OnlineMode.instance_variable_set(:@mode, :offline)
  KIFMultiplayer::OnlineMode.instance_variable_set(:@selection_needed, false)
  resources.define_singleton_method(:startup) { nil }
  resources.instance_variable_set(:@manifest, catalog)
  Object.send(:define_method, :find_newer_available_version) { nil }
  Object.send(:define_method, :pbMessage) { |text, *| raise "Unexpected native menu prompt: #{text}" }
  $game_temp.unimportedSprites = nil
  $game_temp.nb_imported_sprites = nil
  $PokemonSystem.shiny_cache = 0
  log.call("RESOURCE_MENU_BEGIN")
  scene = PokemonLoad_Scene.new
  scene.define_singleton_method(:pbChoose) do |commands, *|
    expected = KIF::OfflineResources.menu_label
    raise "Resource entry missing from actual start menu" unless commands.count(expected) == 1
    Graphics.update
    image = Graphics.snap_to_bitmap
    image.save_to_png(File.join(directory, "resource-start-menu.png"))
    image.dispose
    commands.index(_INTL("Quit Game")) || raise("Quit entry missing")
  end
  screen = PokemonLoadScreen.new(scene)
  screen.define_singleton_method(:copyKeybindings) { nil }
  log.call("RESOURCE_MENU_CONSTRUCTED")
  screen.pbStartLoadScreen
  check.call($scene.nil?, "actual start menu renders resource entry and exits normally")
  check.call(Settings::VERSION_FILE_URL.start_with?("https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/"), "version check uses the maintained repository")
  check.call(Settings::MYSTERY_GIFT_KURAY_URL.start_with?("https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/"), "mystery gifts use the maintained repository")
  log.call("OFFLINE_RESOURCES_NATIVE_PASS no_network=true no_player_saves=true screenshots=true")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("OFFLINE_RESOURCES_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
