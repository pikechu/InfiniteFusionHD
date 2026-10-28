# No game process/network/player saves: exercise shared shop catalog lookups.
require "json"
require "fileutils"
require "tmpdir"
ROOT = File.expand_path("../..", __dir__)
module HTTPLite
  module JSON
    class << self; attr_accessor :calls; end
    self.calls = 0
    def self.parse(text); self.calls += 1; ::JSON.parse(text); end
  end
end
load File.join(ROOT, "Data/Scripts/050_Outfits/wrappers/001_Outfit.rb")
%w[Hat Clothes Hairstyle].each { |name| load File.join(ROOT, "Data/Scripts/050_Outfits/wrappers/#{name}.rb") }
load File.join(ROOT, "Data/Scripts/050_Outfits/001_OutfitsMain/OutfitsGlobal.rb")
load File.join(ROOT, "Data/Scripts/050_Outfits/001_OutfitsMain/OutfitsSearch.rb")
load File.join(ROOT, "Data/Scripts/050_Outfits/001_OutfitsMain/OutfitSelector.rb")
# Catalog fixtures keep English labels; live language switching is tested separately.
def _INTL(text); text; end
class Trainer; end
load File.join(ROOT, "Data/Scripts/015_Trainers and player/004_Player.rb")
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
class SelectorFixture < OutfitSelector
  attr_reader :scans
  def parse_clothes_folder; (@scans ||= []) << :clothes; ["shirt"]; end
  def parse_hats_folder; (@scans ||= []) << :hats; ["cap"]; end
  def parse_hairstyles_folder; (@scans ||= []) << :hair_versions; ["1_cut"]; end
end
def echoln(*); end
selector = SelectorFixture.new
check.call(selector.scans.nil?, "creating a selector never probes hair versions or unrelated graphics")
check.call(selector.hats_list == ["cap"] && selector.scans == [:hats], "hat browsing scans only hats")
selector.hats_list
check.call(selector.scans == [:hats], "one selector reuses its requested directory list")
check.call(selector.clothes_list == ["shirt"] && !selector.scans.include?(:hair_versions), "clothes browsing does not scan hairstyles")
check.call(selector.hairstyles_list == ["1_cut"] && selector.scans.count(:hair_versions) == 1, "hair version enumeration remains available on demand")
$Trainer = Struct.new(:clothes,:clothes_color,:hat,:hat_color,:hair,:hair_color,:unlocked_clothes,:unlocked_hats,:unlocked_hairstyles).new(nil,0,nil,0,nil,0,[],[],[])
selector = SelectorFixture.new
selector.define_singleton_method(:selectNextOutfit) { |current, delta, available, *| raise "Missing lazy list" unless available.is_a?(Array); available.first }
selector.changeToNextClothes(1,true)
check.call($Trainer.clothes == "shirt", "clothes cycling resolves its lazy list before selection")
selector.changeToNextHat(1,true)
check.call($Trainer.hat == "cap", "hat cycling resolves its lazy list before selection")
selector.changeToNextHairstyle(1,true)
check.call($Trainer.hair == "1_cut", "hair cycling resolves its lazy list before selection")
FileUtils.mkdir_p(File.join(ROOT, "temp"))
Dir.mktmpdir("outfit-catalog-", File.join(ROOT, "temp")) do |directory|
  raise "Unsafe fixture directory" unless File.expand_path(directory).start_with?(File.join(ROOT,"temp")+"/")
  module Settings; end
  {HATS_DATA_PATH:"hats.json",HAIRSTYLE_DATA_PATH:"hair.json",CLOTHES_DATA_PATH:"clothes.json"}.each do |key,name|
    path = File.join(directory,name)
    Settings.const_set(key,path)
    File.write(path, JSON.generate([{id:"fixture",name:name,description:"test",price:10,tags:"pewter"}]))
  end
  $PokemonGlobal = PokemonGlobalMetadata.new
  HTTPLite::JSON.calls = 0
  hat, clothes, hair = get_hat_by_id("fixture"), get_clothes_by_id("fixture"), get_hair_by_id("fixture")
  check.call(HTTPLite::JSON.calls == 3, "three item lookups parse each source catalog once")
  check.call((1..100).all? { get_hat_by_id("fixture").equal?(hat) }, "unchanged catalog objects are reused across repeated lookups")
  check.call(HTTPLite::JSON.calls == 3, "repeated stock lookups never reparse unchanged JSON")
  player = Player.allocate
  calls = HTTPLite::JSON.calls
  3.times do
    player.unlock_clothes("fixture",true)
    player.unlock_hat("fixture",true)
    player.unlock_hair("fixture",true)
  end
  check.call(HTTPLite::JSON.calls == calls, "outfit rewards and starting grants reuse the same validated catalogs")
  check.call(player.unlocked_clothes == ["fixture"] && player.unlocked_hats == ["fixture"] && player.unlocked_hairstyles == ["fixture"], "cached grants preserve each category and prevent duplicate unlocks")
  check.call($PokemonGlobal.instance_variables.sort == [:@hats_data,:@hairstyles_data,:@clothes_data].sort, "cache adds no fields to player metadata")
  File.write(Settings::HATS_DATA_PATH, JSON.generate([{id:"new-hat",name:"updated",description:"test",price:20,tags:"pewter"}]))
  check.call(get_hat_by_id("new-hat").name == "updated", "changing a catalog refreshes the shared data")
  old_calls = HTTPLite::JSON.calls
  $PokemonGlobal = PokemonGlobalMetadata.new
  check.call(get_hat_by_id("new-hat").name == "updated" && HTTPLite::JSON.calls == old_calls+3, "switching local saves initializes that save's catalogs")
  File.write(Settings::HATS_DATA_PATH, "broken JSON")
  begin
    get_hat_by_id("new-hat")
    raise "Corrupt catalog was silently accepted"
  rescue JSON::ParserError
    check.call(true, "invalid changed data remains a visible error")
  end
end
puts "OUTFIT_CATALOG_PASS checks=#{checks} network=false player_saves=false"
