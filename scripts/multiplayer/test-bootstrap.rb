# Shared initialized production game runtime for explicit isolated diagnostics.
source_root = ENV.fetch("KIF_TEST_SOURCE_ROOT", ".")
load File.join(source_root, "scripts/multiplayer/runtime-preload.rb")
require "digest/sha2"
$kif_test_directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
$kif_test_log = lambda do |message|
  File.open(File.join($kif_test_directory, "feature-smoke.log"), "a") do |file|
    file.puts("#{Time.now.utc} #{message}")
    file.flush
  end
end
$kif_test_log.call("BEGIN pid=#{Process.pid} profile=#{ENV['KIF_MULTIPLAYER_PROFILE']} ruby=#{RUBY_VERSION}")
loaded = []
loader = lambda do |path|
  entries = Dir.entries(path).reject { |name| name == "." || name == ".." }
  files, directories = entries.partition { |name| !File.directory?(File.join(path, name)) }
  files.sort.each do |name|
    full = File.join(path, name)
    eval(File.read(full), TOPLEVEL_BINDING, full)
    loaded << full
  end
  directories.sort.each do |name|
    next if File.basename(path) == "Scripts" && name == "999_Main"
    loader.call(File.join(path, name))
  end
end
loader.call(File.join(source_root, "Data/Scripts"))
$kif_test_log.call("SOURCE_LOADED count=#{loaded.length} modules=#{loaded.grep(%r{054_Multiplayer/}).join(',')}")
$POKEMONDATA_QUEUEING = []
MessageTypes.loadMessageFile("Data/messages.dat")
PluginManager.runPlugins
Dir[File.join(source_root, "Mods/*.rb")].sort.each { |file| load File.expand_path(file) }
Game.initialize
SaveData.initialize_bootup_values
SaveData.load_new_game_values
$scene = Object.new
$MapFactory = PokemonMapFactory.new($data_system.start_map_id)
$game_player.moveto($data_system.start_x, $data_system.start_y)
$PokemonEncounters = PokemonEncounters.new
$PokemonEncounters.setup($game_map.map_id)
$Trainer.name = ENV.fetch("KIF_MULTIPLAYER_PROFILE")[0, 24]
$PokemonSystem.shiny_cache = 2
$PokemonSystem.download_sprites = 1
$PokemonSystem.battlescene = 1
$PokemonSystem.textspeed = 2
$GameSpeed = 4
module KIFMultiplayerFeatureTest
  def self.log(message); $kif_test_log.call(message); end
  def self.check(condition, name)
    raise "FEATURE_ASSERTION_FAILED #{name}" unless condition
    log("PASS #{name}")
  end
  def self.wait(client, name, seconds = 180)
    deadline = Time.now + seconds
    loop do
      value = yield
      return value if value
      raise "FEATURE_WAIT_TIMEOUT #{name}" if Time.now >= deadline
      until_time = Time.now + 0.25
      client.pump while Time.now < until_time
    end
  end
  def self.pokemon(species, moves, item = :LEFTOVERS)
    pokemon = Pokemon.new(species, 31, $Trainer)
    pokemon.moves.clear
    moves.each { |move| pokemon.learn_move(move) }
    pokemon.item = item
    pokemon.calc_stats
    pokemon.heal
    pokemon
  end
  def self.globals
    [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables]
  end
  def self.digest(objects = globals); Digest::SHA256.hexdigest(Marshal.dump(objects)); end
  def self.marker(path, value)
    File.write(path + ".pending", KIFMultiplayer::WireJSON.dump(value))
    File.rename(path + ".pending", path)
  end
  def self.read(path)
    File.file?(path) ? KIFMultiplayer::WireJSON.parse(File.read(path)) : nil
  end
end
