require_relative "../../scripts/localization/import_zh"
Dir.chdir(ROOT)
def pbRgssOpen(path, mode, &block); File.open(path, mode, &block); end
check_count = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; check_count += 1 }
MessageTypes.loadMessageFile("Data/messages_zh.dat")
%w[content trainer-dialogue].each do |name|
  JSON.parse(File.read("Data/localization/zh-CN-#{name}.json", encoding: "UTF-8")).each do |source, translated|
    check.call(ChineseLocalization.safe_translation?(source, translated), "preserves controls: #{source}")
    check.call(_INTL(source) == translated, "compiled content: #{source}")
  end
end
check.call(_MAPINTL(209, "Do you have a fossil for us to\nrevive?") == "有需要我们复活的化石吗？", "map scripts reuse shared translations")
check.call(_INTL("Slot {1}", 12) == "栏位 12", "default preset slot is translated")
check.call(_INTL("Egg with FIRE-type Pokémon. 10x shiny odds.").include?("火属性"), "dynamic item type is translated")
check.call(_INTL("Next style") == "下一个发型" && _INTL("24 hours") == "24小时", "outfit and sleeping bag menu choices are translated")
english = ChineseLocalization.utf8(Marshal.load(File.binread("Data/messages.dat")))
chinese = ChineseLocalization.utf8(Marshal.load(File.binread("Data/messages_zh.dat")))
[16, 17, 22].each do |section|
  english[section].each_key do |text|
    next unless text.match?(/[A-Za-z]{3}/)
    check.call(pbGetMessageFromHash(section, text).match?(ChineseLocalization::CJK), "complete trainer/phone dialogue #{section}: #{text}")
  end
end
module GameData; class Species; end; end
records = Marshal.load(File.binread("Data/species.dat"))
JSON.parse(File.read("Data/localization/zh-CN-species.json", encoding: "UTF-8")).each do |symbol, fields|
  id = records.fetch(symbol.to_sym).instance_variable_get(:@id_number)
  fields.each do |field, text|
    check.call(chinese[field == "entry" ? 3 : 4][id] == text, "symbol-matched species text: #{symbol}/#{field}")
  end
end
MessageTypes.loadMessageFile("Data/messages.dat")
check.call(_INTL("Slot {1}", 12) == "Slot 12", "English preset text restores")
puts "CONTENT_TEST_PASS checks=#{check_count}"
