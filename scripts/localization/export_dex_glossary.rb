# Export existing game terminology; never modify species or source dex records.
require "json"
require_relative "import_zh"
load File.join(ROOT, "Data/Scripts/048_Fusion/SplitNames.rb")
english = ChineseLocalization.utf8(Marshal.load(File.binread(File.join(ROOT, "Data/messages.dat"))))
chinese = ChineseLocalization.utf8(Marshal.load(File.binread(File.join(ROOT, "Data/messages_zh.dat"))))
terms = {}
[1, 5, 7, 10, 12, 18, 19, 21].each do |section|
  english[section].each_with_index do |text, id|
    next unless text.is_a?(String) && text.length >= 3
    translated = chinese[section]&.[](id)
    terms[text] = translated if translated.is_a?(String) && translated.match?(ChineseLocalization::CJK)
  end if english[section].is_a?(Array)
end
records = JSON.parse(File.read(File.join(ROOT, "Data/pokedex/dex.json"), encoding: "UTF-8"))
fusions = {}
records.map { |row| row["sprite"] }.uniq.each do |sprite|
  next unless sprite =~ /\A(\d+)\.(\d+)/
  head, body = $1.to_i, $2.to_i
  head = GameData::NAT_DEX_MAPPING[head] || head
  body = GameData::NAT_DEX_MAPPING[body] || body
  next unless GameData::SPLIT_NAMES[head] && GameData::SPLIT_NAMES[body]
  left, right = GameData::SPLIT_NAMES[head][0].dup, GameData::SPLIT_NAMES[body][1]
  left = left[0..-2] if left[-1] == right[0]
  en_name = left + right
  left, right = chinese[27][head].to_s, chinese[28][body].to_s
  next if left.empty? || right.empty?
  left = left[0..-2] if left.length > 1 && right.length > 1 && left[-1] == right[0]
  fusions[sprite] = [en_name, left + right]
end
File.write(File.join(ROOT, "temp/localization/game-glossary.json"), JSON.pretty_generate({"terms" => terms, "fusions" => fusions}))
puts "GAME_GLOSSARY terms=#{terms.length} fusions=#{fusions.length}"
