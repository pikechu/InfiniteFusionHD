# frozen_string_literal: true
# Portable, non-graphical host for the installed game's rules. This is a trusted
# server program, never a loader for client scripts or client Marshal objects.
require "json"
require "digest"
require "zlib"
require "stringio"
require_relative "rgss_data"
$VERBOSE = nil
class << File
  alias exists? exist? unless respond_to?(:exists?)
end
class << Dir
  alias exists? exist? unless respond_to?(:exists?)
end

module KIFNative
  ROOT = File.expand_path("../../..", __dir__)
  @sources = []
  @source_globals = []
  @data_paths = []
  def self.register_data_path(path); @data_paths |= [path]; end
  CONTEXT_GLOBALS = %w[$Trainer $PokemonBag $PokemonGlobal $PokemonStorage $game_switches $game_variables
    $PokemonTemp $game_temp $game_system $MapFactory $game_map $game_player $game_screen
    $PokemonMap $PokemonEncounters $game_self_switches].freeze
  SYSTEM_GLOBALS = %w[$LOAD_PATH $LOADED_FEATURES $PROGRAM_NAME $FILENAME $ARGV $stdin $stdout $stderr $VERBOSE $DEBUG $SAFE].freeze
  RESOURCE_GLOBALS = %w[$scene $data_system $data_tilesets $data_common_events $game_map].freeze
  def self.game_global_names
    (@source_globals + CONTEXT_GLOBALS).uniq - SYSTEM_GLOBALS
  end
  def self.register_global_references(code)
    @source_globals |= code.scan(/\$[a-zA-Z][a-zA-Z0-9_]*/)
  end
  def self.read_globals(names = game_global_names)
    names.to_h { |name| [name, TOPLEVEL_BINDING.eval(name)] }
  end
  def self.write_globals(values)
    values.each do |name, value|
      raise "invalid_native_global" unless name.match?(/\A\$[a-zA-Z][a-zA-Z0-9_]*\z/) && !SYSTEM_GLOBALS.include?(name)
      @source_globals |= [name]
      TOPLEVEL_BINDING.local_variable_set(:native_restored_value, value)
      TOPLEVEL_BINDING.eval("#{name} = native_restored_value")
    end
  ensure
    TOPLEVEL_BINDING.local_variable_set(:native_restored_value, nil)
  end
  def self.capture_global_baseline
    @resource_names = GameData.constants(false).select do |name|
      value = GameData.const_get(name)
      value.is_a?(Module) && value.const_defined?(:DATA, false) && value.const_defined?(:DATA_FILENAME, false)
    end.map(&:to_s).sort
    @resource_names << "root:QUESTS" if Object.const_defined?(:QUESTS, false)
    @resource_baseline = resource_values.transform_values { |value| Marshal.dump(value) }
    @global_baseline = Marshal.dump(read_globals)
  end
  def self.resource_values
    (@resource_names || []).to_h { |name| [name, resource_data(name)] }
  end
  def self.resource_data(name)
    name == "root:QUESTS" ? Object.const_get(:QUESTS) : GameData.const_get(name)::DATA
  end
  def self.resource_changes
    resource_values.reject { |name, value| name != "root:QUESTS" && Marshal.dump(value) == @resource_baseline[name] }
  end
  def self.restore_resource_changes(values)
    values.each do |name, data|
      raise ArgumentError, "unknown_native_resource" unless @resource_names&.include?(name)
      resource_data(name).replace(data)
    end
  end
  def self.reset_resource_baseline
    (@resource_baseline || {}).each { |name, raw| resource_data(name).replace(Marshal.load(raw)) }
  end
  def self.virtual_data; @virtual_data ||= {}; end
  def self.restore_virtual_data(values); @virtual_data = values; end
  def self.reset_global_baseline
    raise "native_baseline_missing" unless @global_baseline
    baseline = Marshal.load(@global_baseline)
    reset_resource_baseline
    @virtual_data = {}
    write_globals(game_global_names.to_h { |name| [name, nil] }.merge(baseline))
    $DEBUG = false
    self.scene = nil if respond_to?(:scene=)
    self.clock = nil if respond_to?(:clock=)
    self.active_battle = nil if respond_to?(:active_battle=)
    self.storage_screen = nil if respond_to?(:storage_screen=)
    self.purify_scene = nil if respond_to?(:purify_scene=)
    self.fishing_input = nil if respond_to?(:fishing_input=)
    self.input_elapsed = nil if respond_to?(:input_elapsed=)
    self.quiz_picture = nil if respond_to?(:quiz_picture=)
    self.minigame = nil if respond_to?(:minigame=)
    self.checkpoint_exists = nil if respond_to?(:checkpoint_exists=)
    self.identity_seed, self.identity_counter, self.original_objects = nil, 0, nil if respond_to?(:identity_seed=)
    self.reseed_counter = 0 if respond_to?(:reseed_counter=)
  end
  def self.source(relative)
    path = File.join(ROOT, "Data/Scripts", relative)
    @sources << path
    register_global_references(File.read(path))
    load path
  end
  def self.directory(relative)
    path = File.join(ROOT, "Data/Scripts", relative)
    Dir.children(path).sort.each do |name|
      child = File.join(relative, name)
      File.directory?(File.join(path, name)) ? directory(child) : source(child) if name.end_with?(".rb") || File.directory?(File.join(path, name))
    end
  end
  def self.source_hash
    data = %w[VERSION abilities.dat moves.dat items.dat berry_plants.dat species.dat ribbons.dat
      encounters.dat encounters_remix.dat encounters_randomized.dat trainer_types.dat
      trainers.dat trainers_remix.dat trainers_expert.dat trainers_challenge.dat metadata.dat map_metadata.dat messages.dat regional_dexes.dat
      map_connections.dat connections.dat shadow_movesets.dat phone.dat town_map.dat trainer_lists.dat]
    paths = @sources + @data_paths + data.map { |name| File.join(ROOT, "Data", name) } + Dir[File.join(__dir__, "*.rb")] + Dir[File.join(__dir__, "*.json")]
    if @sources.any? { |path| path.end_with?("003_Game processing/003_Interpreter.rb") }
      paths += Dir[File.join(ROOT, "Data", "Map*.rxdata")].select { |path| File.basename(path).match?(/\AMap(?:\d+|Infos)\.rxdata\z/) } + %w[System.rxdata Tilesets.rxdata CommonEvents.rxdata].map { |name| File.join(ROOT, "Data", name) }
      paths += Dir[File.join(ROOT, "Data/outfits/*.json")]
    end
    Digest::SHA256.hexdigest(paths.uniq.sort.map { |path| "#{path.delete_prefix(ROOT + '/')}\0#{Digest::SHA256.file(path).hexdigest}" }.join("\n"))
  end
end

# The worker clock is a trusted server timestamp. Native constructors also use
# Time.new directly; both forms must be stable when replaying an accepted turn.
class << Time
  alias native_system_now now
  alias native_system_new new
  def now
    if KIFNative.respond_to?(:clock) && !KIFNative.clock.nil?
      at(KIFNative.clock).getlocal("+08:00")
    else
      native_system_now
    end
  end
  def new(*arguments, **keywords)
    return now if arguments.empty? && keywords.empty? && KIFNative.respond_to?(:clock) && !KIFNative.clock.nil?
    native_system_new(*arguments, **keywords)
  end
end

# Presentation-only RGSS primitives needed when defining the native classes.
# There is deliberately no catch-all method_missing for rules or scenes.
class Font; end
class Bitmap
  def draw_text(*); raise "graphics_unavailable_on_server"; end
end
class Window_DrawableCommand; end
class Window_CommandPokemon
  def initialize(*); raise "graphics_unavailable_on_server"; end
end
class SpriteWrapper
  def initialize(*); raise "graphics_unavailable_on_server"; end
end
class SpriteWindow_Base
  def initialize(*); raise "graphics_unavailable_on_server"; end
end
class IconSprite < SpriteWrapper; end
class PokemonSprite < SpriteWrapper; end
class BitmapSprite; end
class Tone
  attr_accessor :red, :green, :blue, :gray
  def initialize(red = 0, green = 0, blue = 0, gray = 0)
    @red, @green, @blue, @gray = red, green, blue, gray
  end
  def self._load(raw); new(*raw.unpack("E4")); end
  def _dump(*); [@red, @green, @blue, @gray].pack("E4"); end
  def set(red, green, blue, gray = 0); @red, @green, @blue, @gray = red, green, blue, gray; end
end
class Color
  attr_accessor :red, :green, :blue, :alpha
  def initialize(red = 0, green = 0, blue = 0, alpha = 255)
    @red, @green, @blue, @alpha = red, green, blue, alpha
  end
  def self._load(raw); new(*raw.unpack("E4")); end
  def _dump(*); [@red, @green, @blue, @alpha].pack("E4"); end
  def set(red, green, blue, alpha = 255); @red, @green, @blue, @alpha = red, green, blue, alpha; end
end
module Graphics
  class << self; attr_accessor :frame_rate; end
end
module System
  def self.user_language; "en"; end
end
def load_data(path)
  absolute = File.expand_path(path, KIFNative::ROOT)
  raise "untrusted_data_path" unless absolute.start_with?(KIFNative::ROOT + "/Data/")
  virtual = KIFNative.virtual_data[absolute.delete_prefix(KIFNative::ROOT + "/")]
  KIFNative.register_data_path(absolute) unless virtual
  data = Marshal.load(virtual || File.binread(absolute))
  lists = if File.basename(absolute).match?(/\AMap\d+\.rxdata\z/)
            data.events.values.flat_map { |event| event.pages.map(&:list) }
          elsif File.basename(absolute) == "CommonEvents.rxdata"
            data.compact.map(&:list)
          else []
          end
  lists.each do |list|
    list.each do |command|
      command.parameters.each { |value| KIFNative.register_global_references(value) if value.is_a?(String) }
    end
  end
  data
end

def save_data(value, path)
  absolute = File.expand_path(path, KIFNative::ROOT)
  raise "untrusted_data_path" unless absolute.start_with?(KIFNative::ROOT + "/Data/") && %w[.dat .rxdata].include?(File.extname(absolute))
  # Original randomizer/dungeon writers use a role-owned virtual file. Never
  # overwrite a compiled data file shared by other players or the release.
  KIFNative.virtual_data[absolute.delete_prefix(KIFNative::ROOT + "/")] = Marshal.dump(value)
  nil
end
def pbRgssOpen(path, mode = "rb", &block)
  absolute = File.expand_path(path, KIFNative::ROOT)
  raise "untrusted_data_path" unless absolute.start_with?(KIFNative::ROOT + "/Data/") && %w[r rb].include?(mode)
  virtual = KIFNative.virtual_data[absolute.delete_prefix(KIFNative::ROOT + "/")]
  return File.open(absolute, mode, &block) unless virtual
  stream = StringIO.new(virtual, mode)
  return stream unless block
  begin
    block.call(stream)
  ensure
    stream.close
  end
end
def pbRgssExists?(path)
  absolute = File.expand_path(path, KIFNative::ROOT)
  absolute.start_with?(KIFNative::ROOT + "/Data/") && (KIFNative.virtual_data.key?(absolute.delete_prefix(KIFNative::ROOT + "/")) || File.file?(absolute))
end
def _INTL(text, *args)
  args.each_with_index { |value, index| text = text.gsub("{#{index + 1}}", value.to_s) }
  text
end
def _ISPRINTF(text, *args); _INTL(text, *args); end
def echoln(*); end
def echo(*); end
def pbGetLanguage; 2; end

native_file_methods = %i[pbRgssOpen pbRgssExists?].to_h { |name| [name, Object.instance_method(name)] }
Dir.chdir(KIFNative::ROOT) do
  JSON.parse(File.read(File.join(__dir__, "source-files.json"))).each { |file| KIFNative.source(file) }
end
native_file_methods.each do |name, implementation|
  Object.define_method(name, implementation)
  Object.send(:private, name)
end

Dir.chdir(KIFNative::ROOT) do
  $POKEMONDATA_QUEUEING = []
  GameData.load_all
  raise "native_messages_unavailable" unless MessageTypes.loadMessageFile("Data/messages.dat")
end

# RGSS XP messages store UTF-8 bytes as binary strings. Keep the native lookup
# and placeholder semantics while reconciling them with JSON's UTF-8 inputs.
module KIFNativeMessageEncoding
  %i[get getOriginal getFromHash getFromMapHash].each do |name|
    define_method(name) do |*arguments|
      value = super(*arguments)
      value.is_a?(String) ? value.dup.force_encoding(Encoding::UTF_8) : value
    end
  end
end
MessageTypes.singleton_class.prepend(KIFNativeMessageEncoding)
def _INTL(*arguments)
  text = MessageTypes.getFromHash(MessageTypes::ScriptTexts, arguments[0]).dup.force_encoding(Encoding::UTF_8)
  arguments.drop(1).each_with_index do |value, index|
    text.gsub!("{#{index + 1}}", value.to_s.dup.force_encoding(Encoding::UTF_8))
  end
  text
end


module KIFNative
  class AudioContext
    def getPlayingBGM; nil; end
  end
  def self.reset(time: nil, seed: nil)
    reset_resource_baseline
    self.scene = nil if respond_to?(:scene=)
    self.active_battle = nil if respond_to?(:active_battle=)
    self.storage_screen = nil if respond_to?(:storage_screen=)
    self.purify_scene = nil if respond_to?(:purify_scene=)
    self.fishing_input = nil if respond_to?(:fishing_input=)
    self.input_elapsed = nil if respond_to?(:input_elapsed=)
    self.quiz_picture = nil if respond_to?(:quiz_picture=)
    $MapFactory = $game_map = $game_player = $game_screen = $PokemonMap = $PokemonEncounters = nil
    $scene = nil
    @virtual_data = {}
    self.identity_seed, self.identity_counter, self.original_objects = nil, 0, nil if respond_to?(:identity_seed=)
    self.clock = time if respond_to?(:clock=)
    QUESTS.each_value { |quest| quest.time = Time.now } if time && Object.const_defined?(:QUESTS, false)
    srand(seed) unless seed.nil?
    $PokemonSystem = PokemonSystem.new
    $PokemonSystem.debugfeature = 1 if $PokemonSystem.respond_to?(:debugfeature=)
    $game_switches = Hash.new(false)
    $game_variables = Hash.new(0)
    $PokemonTemp = PokemonTemp.new
    $game_temp = Game_Temp.new
    $game_system = AudioContext.new
    $PokemonGlobal = PokemonGlobalMetadata.new
    $Trainer = Player.new("Online", :POKEMONTRAINER_Red)
    $PokemonBag = PokemonBag.new
    $PokemonStorage = PokemonStorage.new
  end
end

# Native PBDebug.logonerr normally logs and suppresses exceptions for the GUI.
# Server requests must instead fail and roll back their enclosing transaction.
module PBDebug
  def self.logonerr; yield; end
end

def kurayGetCustomSprite(*)
  nil # Sprite files belong to the client and must not alter server RNG draws.
end

if $PROGRAM_NAME == __FILE__
  puts JSON.generate({"ok" => true, "source_hash" => KIFNative.source_hash})
end
