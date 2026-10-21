begin
  load "scripts/multiplayer/runtime-preload.rb"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  log_file = File.join(directory, "cards-game.log")
  log = lambda { |message| File.open(log_file, "a") { |file| file.puts("#{Time.now.utc} #{message}"); file.flush } }
  log.call("BEGIN pid=#{Process.pid} ruby=#{RUBY_VERSION}")
  loader = lambda do |path|
    entries = Dir.entries(path).reject { |name| name == "." || name == ".." }
    files, folders = entries.partition { |name| !File.directory?(File.join(path, name)) }
    files.sort.each { |name| full = File.join(path, name); eval(File.read(full), TOPLEVEL_BINDING, full) }
    folders.sort.each { |name| loader.call(File.join(path, name)) unless path == "Data/Scripts" && name == "999_Main" }
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
  $Trainer.name = "Cards Native Test"
  $PokemonSystem.shiny_cache = 2
  $PokemonSystem.download_sprites = 1
  load "tests/multiplayer/cards_game_test.rb"
  KIFMultiplayer.with_ui_fonts { KIFMultiplayerCardsGameTest.run(log) }
  log.call("CARDS_NATIVE_PASS")
rescue Exception => error
  log.call("CARDS_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if defined?(log) && log
ensure
  exit!
end
