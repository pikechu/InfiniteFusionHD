require "json"
require "tmpdir"
require "fileutils"
require "ostruct"
Dir.chdir(File.expand_path("../..", __dir__))
class MKXPError < Exception; end
module HTTPLite
  module JSON
    def self.parse(text); ::JSON.parse(text); end
  end
end
module Settings; end
$PokemonSystem = OpenStruct.new(language: 2)
load "Data/Scripts/052_AddOns/PokedexEntries.rb"
checks = 0
check = lambda { |value, label| raise "FAIL #{label}" unless value; checks += 1 }
FileUtils.mkdir_p("temp/localization")
Dir.mktmpdir("dex-", "temp/localization") do |folder|
  source, localized = ["dex.json", "dex_zh.json"].map { |name| File.join(folder, name) }
  Settings.const_set(:CUSTOM_DEX_ENTRIES_PATH, source)
  KIF::PokedexEntries.send(:remove_const, :CHINESE_PATH)
  KIF::PokedexEntries.const_set(:CHINESE_PATH, localized)
  rows = [{"sprite"=>"1.2.png", "entry"=>"First source.", "author"=>"Artist A"},
          {"sprite"=>"1.2.png", "entry"=>"Second source.", "author"=>9000}]
  translated = rows.each_with_index.map { |row, i| row.merge("source"=>row["entry"], "entry"=>"中文描述#{i}") }
  File.write(source, JSON.generate(rows)); File.write(localized, JSON.generate(translated))
  original = File.binread(source)
  check.call(KIF::PokedexEntries.entries_for("1.2.png") == ["中文描述0", "中文描述1"], "same sprite retains distinct entries and numeric author")
  first = KIF::PokedexEntries.entries_for("1.2.png")
  check.call(first.equal?(KIF::PokedexEntries.entries_for("1.2.png")), "repeated lookup reuses cached index")
  $PokemonSystem.language = 0
  check.call(KIF::PokedexEntries.entries_for("1.2.png") == rows.map { |r| r["entry"] }, "switching to English restores originals")
  $PokemonSystem.language = 2
  rows << rows.first.merge("entry"=>"Upstream added a different entry.")
  File.write(source, JSON.generate(rows))
  check.call(KIF::PokedexEntries.entries_for("1.2.png") == ["中文描述0", "中文描述1", rows.last["entry"]], "update does not attach stale Chinese to new English")
  check.call(KIF::PokedexEntries.entries_for("none.png").nil?, "unknown sprite returns no entry")
  File.write(localized, "broken json")
  check.call(KIF::PokedexEntries.entries_for("1.2.png") == rows.map { |r| r["entry"] }, "corrupt optional pack falls back safely")
  File.write(source, original)
  File.write(localized, JSON.generate(translated))
  KIF::PokedexEntries.entries_for("1.2.png")
  check.call(File.binread(source) == original, "viewing translated dex never changes source or credits")
end
load "Data/Scripts/007_Objects and windows/010_DrawText.rb"
load "Data/Scripts/016_UI/004_UI_Pokedex_Entry.rb"
module Graphics
  def self.width; 512; end
end
class Font
  def self.default_color; Object.new; end
end
bitmap = Object.new
def bitmap.disposed?; false; end
def bitmap.text_size(text); OpenStruct.new(width: text.length * 22, height: 32); end
scene = PokemonPokedexInfo_Scene.new
scene.instance_variable_set(:@sprites, {"overlay" => OpenStruct.new(bitmap: bitmap)})
text = "它的翅膀能将阳光转化为能量，遇到危险时会保护森林。" * 12
pages = scene.splitTextIntoPages(text, 150)
check.call(pages.length > 2, "long Chinese can have more than two pages")
check.call(pages.join.delete("\n") == text, "pagination retains every Chinese character")
check.call(pages.all? { |page| page.split("\n").length <= 4 }, "pages fit the actual four-line area")
check.call(pages.flat_map { |page| page.split("\n") }.all? { |line| bitmap.text_size(line).width <= 432 }, "Chinese lines fit actual text width")
def scene.reloadDexEntry; end
def pbSEPlay(*); end
scene.instance_variable_set(:@entryPageCount, pages.length)
scene.instance_variable_set(:@entry_page, 0)
pages.length.times do |index|
  scene.changeEntryPage
  check.call(scene.instance_variable_get(:@entry_page) == (index+1)%pages.length, "page navigation reaches all pages and wraps")
end
puts "CUSTOM_DEX_PASS checks=#{checks}"
