# Export existing game terminology; never modify species or source dex records.
require "json"
require_relative "import_zh"
load File.join(ROOT, "Data/Scripts/048_Fusion/SplitNames.rb")
english = ChineseLocalization.utf8(Marshal.load(File.binread(File.join(ROOT, "Data/messages.dat"))))
chinese = ChineseLocalization.utf8(Marshal.load(File.binread(File.join(ROOT, "Data/messages_zh.dat"))))
terms = {}
categories = {}
category_candidates = {}
{1 => "species", 5 => "moves", 7 => "items", 8 => "item_plurals",
 10 => "abilities", 12 => "types", 13 => "trainer_types", 18 => "regions",
 19 => "places", 21 => "maps"}.each do |section, category|
  categories[category] = {}
  category_candidates[category] = {}
  english[section].each_with_index do |text, id|
    next unless text.is_a?(String) && text.length >= 3
    translated = chinese[section]&.[](id)
    next unless translated.is_a?(String) && translated.match?(ChineseLocalization::CJK)
    categories[category][text] = translated
    (category_candidates[category][text] ||= []) << [id, translated]
    terms[text] = translated unless [8, 13].include?(section)
  end if english[section].is_a?(Array)
end
records = JSON.parse(File.read(File.join(ROOT, "Data/pokedex/dex.json"), encoding: "UTF-8"))
settings = File.read(File.join(ROOT, "Data/Scripts/001_Settings.rb"), encoding: "UTF-8")
species_count = Integer(settings[/^\s*NB_POKEMON\s*=\s*(\d+)/, 1])
pair_names = {}
name_candidates = {}
1.upto(species_count) do |head_id|
  1.upto(species_count) do |body_id|
    head = GameData::NAT_DEX_MAPPING[head_id] || head_id
    body = GameData::NAT_DEX_MAPPING[body_id] || body_id
    next unless GameData::SPLIT_NAMES[head] && GameData::SPLIT_NAMES[body]
    left, right = GameData::SPLIT_NAMES[head][0].dup, GameData::SPLIT_NAMES[body][1]
    left = left[0..-2] if left[-1] == right[0]
    en_name = left + right
    left, right = chinese[27][head].to_s, chinese[28][body].to_s
    next if left.empty? || right.empty?
    left = left[0..-2] if left.length > 1 && right.length > 1 && left[-1] == right[0]
    pair = "#{head_id}.#{body_id}"
    pair_names[pair] = [en_name, left + right]
    (name_candidates[en_name] ||= []) << [pair, left + right]
  end
end
fusions = {}
records.map { |row| row["sprite"] }.uniq.each do |sprite|
  next unless sprite =~ /\A(\d+)\.(\d+)/
  names = pair_names["#{$1}.#{$2}"]
  fusions[sprite] = names if names
end
path = File.join(ROOT, "temp/localization/game-glossary.json")
File.write(path + ".pending", JSON.pretty_generate({"terms" => terms, "categories" => categories,
  "category_candidates" => category_candidates,
  "fusions" => fusions, "fusion_name_candidates" => name_candidates}))
File.rename(path + ".pending", path)
puts "GAME_GLOSSARY terms=#{terms.length} fusions=#{fusions.length} candidates=#{pair_names.length} names=#{name_candidates.length}"
