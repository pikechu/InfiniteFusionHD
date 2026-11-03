# Exercise the production sprite lookup with missing downloads and isolated assets.
require "fileutils"
require "tmpdir"
ROOT = File.expand_path("../..", __dir__)
class MKXPError < Exception; end
module Settings
  NB_POKEMON = 501
  CUSTOM_BASE_SPRITES_FOLDER = CUSTOM_BASE_SPRITE_FOLDER = "Graphics/BaseSprites/"
  CUSTOM_BATTLERS_FOLDER = "Graphics/CustomBattlers/"
  CUSTOM_BATTLERS_FOLDER_INDEXED = "Graphics/CustomBattlers/indexed/"
  BATTLERS_FOLDER = "Graphics/Battlers/"
  DEFAULT_SPRITE_PATH = "Graphics/Battlers/Special/000.png"
  CUSTOM_SPRITES_FILE_PATH = "Data/sprites/CUSTOM_SPRITES"
  BASE_SPRITES_FILE_PATH = "Data/sprites/BASE_SPRITES"
  CREDITS_FILE_PATH = "Data/sprites/Sprite Credits.csv"
  NEWEST_SPRITEPACK_YEAR, NEWEST_SPRITEPACK_MONTH = 2024, 12
  CUSTOM_SPRITES_REPO_URL = "https://fixture.invalid/custom/"
  BASE_POKEMON_SPRITES_REPO_URL = "https://fixture.invalid/base/"
  BASE_POKEMON_ALT_SPRITES_REPO_URL = "https://fixture.invalid/base/"
  AUTOGEN_SPRITES_REPO_URL = ""
  CUSTOMSPRITES_RATE_LOG_FILE = "unused"
  CUSTOMSPRITES_ENTRIES_RATE_TIME_WINDOW = CUSTOMSPRITES_RATE_MAX_NB_REQUESTS = 6
end
NB_POKEMON = Settings::NB_POKEMON
module KIF
  module Platform
    class << self
      attr_accessor :requests, :response
      def android?; true; end
      def http_get(url); requests << url; response || { :status => 404 }; end
      def write_download(path, bytes)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        true
      end
    end
  end
end
def _INTL(text, *args); text.gsub(/\{(\d+)\}/) { args[$1.to_i - 1].to_s }; end
def pbResolveBitmap(path); path if path && File.file?(path); end
def downloadAllowed?; $PokemonSystem.download_sprites == 0; end
def requestRateExceeded?(*); false; end
def echoln(*); end
def getSpeciesIdForFusion(head, body); body * NB_POKEMON + head; end
def getDexNumberForSpecies(species); species; end
def getBodyID(id); (id - 1) / NB_POKEMON; end
def getHeadID(id, body); id - body * NB_POKEMON; end
%w[SpriteAssets SpriteSheets FusionSprites HttpCalls PokedexUtils].each do |name|
  load File.join(ROOT, "Data/Scripts/052_AddOns/#{name}.rb")
end
$PokemonSystem = Struct.new(:sprite_sheet_mode, :download_sprites).new(1, 0)
$PokemonTemp = PokemonTemp.new
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
write = lambda do |path, bytes = "fixture"|
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, bytes)
  path
end
Dir.mktmpdir("battle-sprites-", File.join(ROOT, "temp")) do |directory|
  Dir.chdir(directory) do
    FileUtils.mkdir_p(Settings::CUSTOM_BATTLERS_FOLDER_INDEXED)
    write.call(Settings::CUSTOM_SPRITES_FILE_PATH, "")
    write.call(Settings::BASE_SPRITES_FILE_PATH, "")
    write.call(Settings::CREDITS_FILE_PATH, "41,artist,main,\n41z,artist,main,\n41aa,artist,main\n410a,artist,main,\n")
    check.call(map_alt_sprite_letters_for_pokemon("41") == {"" => "main", "z" => "main", "aa" => "main"},
      "credits preserve multi-letter alternatives and do not mix species prefixes")
    KIF::Platform.requests = []
    base = write.call("Graphics/BaseSprites/41.png")
    # Force the same unavailable random alternative on every encounter.
    Object.send(:define_method, :get_random_alt_letter_for_unfused) { |*| "z" }
    check.call(get_unfused_sprite_path(41) == base && KIF::Platform.requests.empty?,
      "missing Zubat alternative uses installed main without waiting for HTTPS")
    check.call(get_unfused_sprite_path(41, 0) == base && KIF::Platform.requests.empty?,
      "default form zero uses the ordinary installed sprite")
    File.delete(base)
    base = write.call("Graphics/Battlers/41/41.png")
    check.call(get_unfused_sprite_path(41) == base && KIF::Platform.requests.empty?,
      "ordinary generated base also loads before missing alternative downloads")
    generated = write.call("Graphics/Battlers/41/41.74.png")
    check.call(get_fusion_sprite_path(41, 74) == generated && KIF::Platform.requests.empty?,
      "installed generated fusion loads before any custom download")
    $PokemonSystem.sprite_sheet_mode = 0
    check.call(get_fusion_sprite_path(41, 74, 0, 0) == generated && KIF::Platform.requests.empty?,
      "fusion default form zero uses local art even when sheets are disabled")
    $PokemonSystem.sprite_sheet_mode = 1
    $PokemonGlobal = Struct.new(:alt_sprite_substitutions, :autogen_sprites_cache).new({}, {})
    get_fusion_sprite_path(41, 74)
    File.delete(generated)
    check.call(get_fusion_sprite_path(41, 74) != generated,
      "deleted generated sprite cache cannot return a stale missing image")
    KIF::Platform.requests.clear
    KIF::Platform.response = { :status => 200, :body => "fixture png" }
    downloaded = download_unfused_main_sprite(74)
    check.call(downloaded == "Graphics/Battlers/74/74.png" && File.file?(downloaded),
      "base sprite download is saved in the same directory used by the loader")
    KIF::Platform.response = nil
    KIF::Platform.requests.clear
    2.times { download_unfused_main_sprite(75) }
    check.call(KIF::Platform.requests.length == 1, "legacy missing sprite request is not repeated in the same session")
    KIF::Platform.requests.clear
    $PokemonSystem.download_sprites = 1
    check.call(get_fusion_sprite_path(1, 2) == Settings::DEFAULT_SPRITE_PATH && KIF::Platform.requests.empty?,
      "disabled downloads retain the offline placeholder without HTTP")
  ensure
    KIF::SpriteSheets.clear
  end
end
puts "BATTLE_SPRITES_PASS checks=#{checks} real_network=false player_saves=false"
