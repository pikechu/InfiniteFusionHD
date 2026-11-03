require "json"
require "ostruct"
require_relative "../../scripts/localization/apply_zh_additions"
Dir.chdir(ROOT)
def pbRgssOpen(path, mode, &block); File.open(path, mode, &block); end
class Color; def initialize(*args); @channels = args; end; end
class IconSprite; end
VAR_TYPE_EXPERTS_BEATEN = 1
TOTAL_NB_TYPE_EXPERTS = 12
def pbGet(_id); 3; end
load "Data/Scripts/052_AddOns/QuestLogScript.rb"
load "Data/Scripts/052_AddOns/TRQuests.rb"
load "Data/Scripts/050_Outfits/wrappers/001_Outfit.rb"
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
MessageTypes.loadMessageFile("Data/messages_zh.dat")
additions = JSON.parse(File.read("Data/localization/zh-CN-quest-dialogue.json", encoding: "UTF-8"))
additions.fetch("script_texts").each do |english, chinese|
  check.call(ChineseLocalization.safe_translation?(english, chinese), "safe translation #{english}")
  check.call(_INTL(english) == chinese, "compiled script #{english}")
end
additions.fetch("map_texts").each do |map_id, texts|
  texts.each { |english, chinese| check.call(_MAPINTL(map_id.to_i, english) == chinese, "compiled map #{map_id}: #{english}") }
end
additions.fetch("indexed_texts").each do |entry|
  check.call(MessageTypes.get(entry.fetch("section"), entry.fetch("id")) == entry.fetch("translation"), "compiled item #{entry}")
end
quests = QUESTS.values + TR_QUESTS.values
serialized = Marshal.dump(quests)
quests.each do |quest|
  [quest.name, quest.desc, quest.npc, quest.location].each do |text|
    check.call(pbQuestText(text).match?(ChineseLocalization::CJK), "quest field #{quest.id}: #{text}")
  end
end
check.call(pbQuestText(QUESTS.fetch("cerulean_2").desc).include?("3/12"), "old saved expert count is displayed unchanged")
check.call(Marshal.dump(quests) == serialized, "all77 stored quest definitions remain unchanged by display")
outfit = Outfit.new("bughakama", "Bug Hakama Dress", "A traditionnal looking hakama dress, that captures the essence of bug-type Pokémon, complete with a bug-catching net!")
stored = Marshal.dump(outfit)
check.call(outfit.name == "虫属性袴裙" && outfit.description.match?(ChineseLocalization::CJK), "outfit name and description use display translation")
check.call(outfit.id == "bughakama" && Marshal.dump(outfit) == stored, "outfit IDs and stored fields are unchanged")
# Verify the incremental merger preserves every unmentioned table/key.
english = ChineseLocalization.utf8(Marshal.load(File.binread("Data/messages.dat")))
pack = Marshal.load(File.binread("Data/messages_zh.dat"))
before = Marshal.load(Marshal.dump(pack))
ChineseLocalization.apply_additions(pack, english, additions)
check.call(pack == before, "reviewed pack merge is idempotent and loses no historical translations")
invalid = {"indexed_texts" => [{"section" => 9, "id" => 523, "source" => "Changed upstream text", "translation" => "不会应用"}]}
begin
  ChineseLocalization.apply_additions(pack, english, invalid)
  raise "FAIL source guard did not reject changed English"
rescue RuntimeError => error
  check.call(error.message.start_with?("Changed indexed source"), "changed English source is rejected")
end
MessageTypes.loadMessageFile("Data/messages.dat")
check.call(pbQuestText(QUESTS.fetch("cerulean_2").desc) == QUESTS.fetch("cerulean_2").desc, "English restores saved quest fields")
check.call(outfit.name == "Bug Hakama Dress", "English restores outfit labels immediately")
check.call(Marshal.dump(quests) == serialized && Marshal.dump(outfit) == stored, "language switching keeps saved data unchanged")
puts "QUEST_DIALOGUE_PASS checks=#{checks} quests=#{quests.length}"
