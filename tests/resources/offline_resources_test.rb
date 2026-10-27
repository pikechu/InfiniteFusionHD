# Offline regression: all writes live in a disposable directory; HTTP is stubbed.
require "json"
require "fileutils"
require "tmpdir"
require "zlib"
require "digest/sha2"
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
  def self.get(*); raise "Unexpected native HTTP"; end
end
module Settings
  NB_POKEMON = 501
  CUSTOM_DEX_ENTRIES_PATH = "Data/pokedex/dex.json"
  OFFLINE_RESOURCES_URL = "https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/Data/offline-resources.json"
end
%w[000_Platform.rb 054_Multiplayer/001_Client.rb 052_AddOns/SpriteAssets.rb
   052_AddOns/SpriteSheets.rb 052_AddOns/PokedexEntries.rb
   053_OfflineResources/001_OfflineResources.rb].each { |name| load File.join(ROOT, "Data/Scripts", name) }
module Graphics
  def self.width; 512; end
  def self.update; end
end
module KIFMultiplayer
  def self.with_ui_fonts; yield; end
end
module Input
  B = 1
  class << self; attr_accessor :cancel; end
  def self.trigger?(*); !!cancel; end
  def self.update; end
end
class Window_UnformattedTextPokemon
  attr_accessor :text, :z
  def self.newWithSize(*); new; end
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
$PokemonSystem = Struct.new(:sprite_sheet_mode, :download_sprites).new(1, 0)
def pbMessage(*); end
def _INTL(text, *); text; end
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
reject = lambda do |name, &block|
  begin; block.call; rescue ArgumentError, IOError, KIFMultiplayer::Error; check.call(true, name); else; raise "FAIL accepted #{name}"; end
end
resources = KIF::OfflineResources
real = resources.parse(File.binread(File.join(ROOT, resources::MANIFEST)))
check.call(real["files"].length > 3800, "published pack includes the full three sheet sets and auxiliary data")
real["files"].select { |e| e["kind"] == "data" }.each do |entry|
  check.call(resources.valid_bytes?(entry, File.binread(File.join(ROOT, entry["path"]))), "bundled data matches manifest: #{entry['path']}")
end
bad = Marshal.load(Marshal.dump(real))
bad["files"][0]["path"] = "Data/Scripts/evil.rb"
reject.call("rejects executable destinations") { resources.parse(JSON.generate(bad)) }
bad["files"][0]["path"] = "Graphics/Battlers/Special/../evil.png"
reject.call("rejects path traversal") { resources.parse(JSON.generate(bad)) }
bad = Marshal.load(Marshal.dump(real)); bad["files"][0]["url"] = "https://evil.invalid/file"
reject.call("rejects untrusted resource hosts") { resources.parse(JSON.generate(bad)) }
bad = Marshal.load(Marshal.dump(real)); bad["files"] << bad["files"][0]
reject.call("rejects duplicate destinations") { resources.parse(JSON.generate(bad)) }

raw = "\0".b + ([10, 20, 30, 255].pack("C4") * 96)
chunk = lambda { |kind, data| [data.bytesize].pack("N") + kind + data + [Zlib.crc32(kind + data)].pack("N") }
png = KIF::SpriteImport::PNG + chunk.call("IHDR", [96, 96, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
  chunk.call("IDAT", Zlib::Deflate.deflate(raw * 96)) + chunk.call("IEND", "")
entry = {"path" => "Graphics/Battlers/Special/fixture.png", "kind" => "image", "size" => png.bytesize,
         "sha1" => Digest::SHA1.hexdigest("blob #{png.bytesize}\0".b + png),
         "url" => "https://raw.githubusercontent.com/infinitefusion/infinitefusion-e18/#{'a'*40}/Graphics/Battlers/Special/fixture.png"}
catalog = {"format" => 1, "revision" => "a" * 64, "files" => [entry]}
FileUtils.mkdir_p(File.join(ROOT, "temp"))
Dir.mktmpdir("offline-resources-", File.join(ROOT, "temp")) do |directory|
  Dir.chdir(directory) do
    FileUtils.mkdir_p("Data")
    File.write("Data/offline-resources.json", JSON.generate(catalog))
    resources.instance_variables.each { |name| resources.remove_instance_variable(name) }
    check.call(resources.valid_bytes?(entry, png), "verifies Git blob hash and image header")
    check.call(!resources.valid_bytes?(entry, png[0...-1]), "rejects truncated downloads")
    changed = png.dup; changed.setbyte(25, changed.getbyte(25) ^ 1)
    check.call(!resources.valid_bytes?(entry, changed), "rejects same-size corruption")
    resources.install(entry, png)
    check.call(resources.valid_file?(entry, true), "atomic install passes full file verification")
    reject.call("failed verification preserves the installed image") { resources.install(entry, changed) }
    check.call(File.binread(entry["path"]) == png, "bad download cannot overwrite the previous image")
    File.binwrite(entry["path"], changed)
    check.call(!resources.valid_file?(entry, true), "full verification detects on-disk corruption")
    check.call(Dir.glob("**/*.pending").empty?, "no pending install files remain")

    calls, failures, cancel_on_fetch = [], false, false
    resources.define_singleton_method(:fetch) do |url, *args, &pulse|
      calls << url
      Input.cancel = true if cancel_on_fetch
      pulse.call(1) if pulse
      raise IOError, "simulated offline" if failures
      url == Settings::OFFLINE_RESOURCES_URL ? JSON.generate(catalog) : png
    end
    result = resources.run
    check.call(result.empty? && resources.installed? && resources.complete?, "download repairs the corrupt file and marks completion only after success")
    check.call($PokemonSystem.sprite_sheet_mode == 1, "download selects local sheets")
    calls.clear
    check.call(resources.run.empty? && calls == [Settings::OFFLINE_RESOURCES_URL], "repeat download skips verified images")
    calls.clear
    strict_result = resources.run(true)
    raise "Integrity audit: #{strict_result.inspect} requests=#{calls.inspect}" unless strict_result.empty? && calls.empty?
    check.call(true, "full integrity verification needs no network")
    calls.clear
    File.delete(entry["path"])
    check.call(resources.missing(entry["path"]) && calls == [entry["url"]], "missing asset still downloads on demand after pack completion")
    check.call(!resources.missing(entry["path"]) && calls.length == 1, "installed asset never downloads again during play")
    File.delete(entry["path"])
    failures = true
    result = resources.run
    check.call(result.length == 1 && !resources.complete?, "interrupted download cannot claim a complete pack")
    failures = false
    check.call(resources.run.empty? && resources.complete?, "retry repairs missing assets and resumes completion")
    catalog = catalog.merge("revision" => "b" * 64)
    resources.refresh
    check.call(resources.menu_label == "Offline resources (new)", "new manifest revision displays the resource update badge")
    calls.clear
    resources.startup
    resources.startup
    check.call(calls.length == 1, "automatic resource checking runs only once at startup")
    File.delete(entry["path"])
    cancel_on_fetch = true
    check.call(resources.run.nil?, "cancel returns safely with verified files retained")
    Input.cancel = false
    cancel_on_fetch = false

    dex = [{"sprite"=>"1.1.png", "entry"=>"Published text", "author"=>"author"}]
    dex_bytes = JSON.generate(dex)
    dex_entry = {"path"=>"Data/pokedex/dex.json", "kind"=>"data", "size"=>dex_bytes.bytesize,
                 "sha256"=>Digest::SHA256.hexdigest(dex_bytes)}
    FileUtils.mkdir_p("Data/pokedex")
    local_entry = dex[0].merge("entry"=>"Local custom text")
    File.write(dex_entry["path"], JSON.generate([local_entry]))
    resources.install(dex_entry, dex_bytes)
    check.call(JSON.parse(File.read(dex_entry["path"])) == [local_entry, dex[0]], "auxiliary dex updates preserve locally authored entries")
    check.call(resources.valid_file?(dex_entry, true), "merged dex keeps an independently verifiable source copy")
    File.write(dex_entry["path"], JSON.generate([local_entry]))
    check.call(!resources.valid_file?(dex_entry, true), "full integrity check also detects published entries missing from the active merged dex")
    resources.instance_variable_set(:@manifest, nil)
    resources.atomic(resources::CACHE + '/manifest.json', 'corrupt cache')
    check.call(resources.manifest['revision'] == ('a' * 64), "corrupt manifest cache falls back to the bundled manifest")
  end
end
load File.join(ROOT, "Data/Scripts/052_AddOns/OnlineWondertrade.rb")
check.call(OnlineWondertrade.new.pbWonderTrade.nil?, "legacy map entry no longer performs a network trade")
check.call(File.read(File.join(ROOT, "Data/Scripts/052_AddOns/Wondertrade.rb")).include?("def pbWonderTrade(lvl"), "offline Wonder Trade implementation remains available")
puts "OFFLINE_RESOURCES_PASS checks=#{checks} real_network=false player_saves=false"
