# Missing battle sheets use the verified manifest even before pack installation.
require "json"
require "fileutils"
require "tmpdir"
require "zlib"
require "digest/sha1"
ROOT = File.expand_path("../..", __dir__)
class MKXPError < Exception; end
module System
  def self.is_android?; false; end
end
module HTTPLite
  module JSON
    def self.parse(text); ::JSON.parse(text); end
    def self.stringify(value); ::JSON.generate(value); end
  end
end
module Settings
  NB_POKEMON = 501
  CUSTOM_SPRITES_FILE_PATH = "Data/sprites/CUSTOM_SPRITES"
  BASE_SPRITES_FILE_PATH = "Data/sprites/BASE_SPRITES"
  CUSTOM_BATTLERS_FOLDER = "Graphics/CustomBattlers/"
  BATTLERS_FOLDER = "Graphics/Battlers/"
  NEWEST_SPRITEPACK_YEAR, NEWEST_SPRITEPACK_MONTH = 2024, 12
end
%w[000_Platform.rb 054_Multiplayer/001_Client.rb 052_AddOns/SpriteAssets.rb
   052_AddOns/SpriteSheets.rb 053_OfflineResources/001_OfflineResources.rb].each do |name|
  load File.join(ROOT, "Data/Scripts", name)
end
$PokemonSystem = Struct.new(:sprite_sheet_mode, :download_sprites).new(1, 0)
def downloadAllowed?; $PokemonSystem.download_sprites == 0; end
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
chunk = lambda { |kind, bytes| [bytes.bytesize].pack("N") + kind + bytes + [Zlib.crc32(kind + bytes)].pack("N") }
png = KIF::SpriteImport::PNG + chunk.call("IHDR", [960, 96, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
  chunk.call("IDAT", Zlib::Deflate.deflate(("\0".b + [10, 20, 30, 255].pack("C4") * 960) * 96)) + chunk.call("IEND", "")
path = "Graphics/CustomBattlers/spritesheets/spritesheets_base/41.png"
entry = {"path" => path, "kind" => "image", "size" => png.bytesize,
  "sha1" => Digest::SHA1.hexdigest("blob #{png.bytesize}\0".b + png),
  "url" => "https://raw.githubusercontent.com/infinitefusion/infinitefusion-e18/#{'a' * 40}/#{path}"}
Dir.mktmpdir("battle-sheets-", File.join(ROOT, "temp")) do |directory|
  Dir.chdir(directory) do
    resources = KIF::OfflineResources
    resources.instance_variable_set(:@manifest, {"files" => [entry]})
    calls, fail_download = [], false
    resources.define_singleton_method(:fetch) do |url, *|
      calls << url
      raise IOError, "simulated offline" if fail_download
      png
    end
    check.call(!resources.installed?, "fixture is a fresh installation without the offline pack")
    check.call(KIF::SpriteSheets.sheet(:base, 41, "", false).nil? && calls.empty?, "local probing never starts a download")
    $PokemonSystem.download_sprites = 1
    check.call(KIF::SpriteSheets.sheet(:base, 41, "", true).nil? && calls.empty?, "missing sheet respects disabled downloads")
    $PokemonSystem.download_sprites = 0
    $PokemonSystem.sprite_sheet_mode = 0
    check.call(KIF::SpriteSheets.sheet(:base, 41, "", true).nil? && calls.empty?, "disabled sheets do not repair via the manifest")
    $PokemonSystem.sprite_sheet_mode = 1
    check.call(KIF::SpriteSheets.sheet(:base, 41, "", true) == path && calls == [entry["url"]], "missing sheet uses the pinned verified manifest before pack installation")
    check.call(resources.valid_file?(entry, true), "on-demand sheet passes the actual pack checksum")
    check.call(KIF::SpriteSheets.sheet(:base, 41, "", true) == path && calls.length == 1, "installed sheet is reused without another request")
    File.delete(path)
    fail_download = true
    resources.instance_variable_set(:@missing_attempts, {})
    3.times { KIF::SpriteSheets.sheet(:base, 41, "", true) }
    check.call(calls.length == 2, "unreachable sheet is attempted once per session")
    check.call(Dir.glob("**/*.pending").empty?, "failed downloads leave no partial images")
  ensure
    KIF::SpriteSheets.clear
  end
end
puts "BATTLE_SHEETS_PASS checks=#{checks} real_network=false player_saves=false"
