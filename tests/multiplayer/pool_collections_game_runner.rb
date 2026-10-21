# Isolated real-game runner for pool_collections_game_test.rb. The explicit
# source loader matches the existing game integration harness and skips Main's
# interactive title/save picker. It never loads a player's normal save.
success = false
begin
  load "scripts/multiplayer/runtime-preload.rb"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  log_file = File.join(directory, "pool-collections-native.log")
  log = lambda { |message| File.open(log_file, "a") { |file| file.puts("#{Time.now.utc} #{message}"); file.flush } }
  log.call("BEGIN pid=#{Process.pid} ruby=#{RUBY_VERSION}")
  loader = lambda do |path|
    entries = Dir.entries(path).reject { |name| name == "." || name == ".." }
    files, folders = entries.partition { |name| !File.directory?(File.join(path, name)) }
    files.sort.each { |name| full = File.join(path, name); eval(File.read(full), TOPLEVEL_BINDING, full) }
    folders.sort.each do |name|
      next if path == "Data/Scripts" && name == "999_Main"
      loader.call(File.join(path, name))
    end
  end
  loader.call("Data/Scripts")
  $POKEMONDATA_QUEUEING = []
  MessageTypes.loadMessageFile("Data/messages.dat")
  PluginManager.runPlugins
  Dir["Mods/*.rb"].sort.each { |file| load File.expand_path(file) }
  Game.initialize
  SaveData.initialize_bootup_values
  SaveData.load_new_game_values
  $scene = Object.new
  $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
  $game_player.moveto($data_system.start_x, $data_system.start_y)
  $PokemonEncounters = PokemonEncounters.new
  $PokemonEncounters.setup($game_map.map_id)
  $Trainer.name = "Pool Native Test"
  $PokemonSystem.shiny_cache = 2
  $PokemonSystem.download_sprites = 1
  # Exercise the same display scope as the real menu with deliberately
  # different persisted options. Temporary UI getters must not leak to saves.
  preloaded = false
  if ENV["KIF_POOL_GAME_TEST"] == "restart"
    load "tests/multiplayer/pool_restart_game_test.rb"
    preloaded = KIFMultiplayerPoolRestartGameTest.prepare_restart(log)
  end
  unless preloaded
    $PokemonSystem.download_sprites = 0
    $PokemonSystem.shinyadvanced = 1
  end
  KIFMultiplayer.with_ui_fonts do
    if ENV["KIF_POOL_GAME_TEST"] == "restart"
      KIFMultiplayerPoolRestartGameTest.run(log)
    else
      load "tests/multiplayer/pool_collections_game_test.rb"
      KIFMultiplayerPoolCollectionsGameTest.run(log)
    end
  end
  raise "UI scope changed original system options" unless $PokemonSystem.download_sprites == 0 && $PokemonSystem.shinyadvanced == 1
  log.call("POOL_COLLECTIONS_NATIVE_PASS")
  success = true
rescue Exception => error
  log.call("POOL_COLLECTIONS_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if defined?(log) && log
ensure
  exit!(success ? 0 : 1)
end
