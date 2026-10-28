# Inspect trusted map scripts as data; never execute NPC events or set story flags.
require "json"
require "ripper"
require "fileutils"
require_relative "../../server/multiplayer/native/rgss_data"
class Tone; def self._load(*); new; end; end
class Color; def self._load(*); new; end; end
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
infos = Marshal.load(File.binread("Data/MapInfos.rxdata"))
pattern = /\b(?:clothesShop|hatShop|hairShop|pokemart_clothes_shop|pokemart_hat_shop|genericOutfitsShopMenu|openSelectOutfitMenu|changeClothesMenu|changeHatMenu|changeOutfit|selectClothes|selectHat|selectHairstyle|selectHairColor|selectHatColor|selectClothesColor|OutfitSelector)\b/
entries, blocks, maps = [], 0, 0
scan = lambda do |list, location|
  index = 0
  while index < list.length
    command = list[index]
    if command.code == 355
      script = command.parameters[0].to_s.dup.force_encoding("UTF-8")
      index += 1
      while index < list.length && list[index].code == 655
        script += "\n" + list[index].parameters[0].to_s.dup.force_encoding("UTF-8")
        index += 1
      end
      blocks += 1
      calls = script.scan(pattern).uniq
      entries << location.merge("calls"=>calls, "script"=>script) unless calls.empty?
    else
      index += 1
    end
  end
end
Dir.glob("Data/Map[0-9]*.rxdata").sort.each do |path|
  id = path[/Map(\d+)/,1].to_i
  map = Marshal.load(File.binread(path)); maps += 1
  ancestry, node = [], id
  20.times do
    break unless infos[node]
    ancestry << infos[node].name.dup.force_encoding("UTF-8")
    node = infos[node].parent_id
  end
  map.events.each do |event_id,event|
    event.pages.each_with_index do |page, page_id|
      scan.call(page.list, {"map"=>id,"area"=>ancestry.reverse.join(" / "),"event"=>event_id,"page"=>page_id+1})
    end
  end
end
common = Marshal.load(File.binread("Data/CommonEvents.rxdata")).compact
common.each { |event| scan.call(event.list, {"common_event"=>event.id,"name"=>event.name.dup.force_encoding("UTF-8")}) }
literal = lambda do |node|
  raise "Nonliteral expression" unless node.is_a?(Array)
  case node[0]
  when :program then literal.call(node[1][0])
  when :array then (node[1] || []).map { |value| literal.call(value) }
  when :string_literal
    (node[1][1..-1] || []).map { |part| raise "Interpolated string" unless part[0] == :@tstring_content; part[1] }.join
  when :var_ref
    token = node[1]
    token[0] == :@const ? {"constant"=>token[1]} : {"true"=>true,"false"=>false,"nil"=>nil}.fetch(token[1])
  else raise "Nonliteral expression"
  end
end
profiles, dynamic = [], []
entries.each do |entry|
  entry["script"].scan(/generate_(clothes|hats|hairstyle)_choice\s*\((.*?)\)/m).each do |kind,args|
    begin
      values = {}
      args.scan(/(baseOptions|additionalIds|additionalTags|filterOutTags)\s*=\s*(\[[^\]]*\]|true|false)/m).each do |name,value|
        values[name] = literal.call(Ripper.sexp(value))
      end
      raise "Dynamic or named arguments" unless values.length == 4
      profiles << {"kind"=>kind,"args"=>%w[baseOptions additionalIds additionalTags filterOutTags].map { |name| values[name] },"map"=>entry["map"],"event"=>entry["event"]}
    rescue StandardError => error
      dynamic << {"map"=>entry["map"],"event"=>entry["event"],"reason"=>error.message}
    end
  end
end
profiles.uniq! { |profile| [profile["kind"],profile["args"]] }
source = File.read("Data/Scripts/052_AddOns/GameplayUtils.rb", encoding:"UTF-8")
mart = source[/pokemart_entrances\s*=\s*\{(.*?)\n\s*\}/m,1]
cities = mart.scan(/:([A-Z][A-Z_]*)\s*=>/).flatten
report = {"maps_scanned"=>maps,"common_events_scanned"=>common.length,"script_blocks_scanned"=>blocks,
          "entry_blocks"=>entries.length,"maps_with_entries"=>entries.filter_map { |entry| entry["map"] }.uniq.length,
          "common_events_with_entries"=>entries.filter_map { |entry| entry["common_event"] }.uniq,
          "calls"=>entries.flat_map { |entry| entry["calls"] }.tally,"shared_mart_cities"=>cities,
          "generator_profiles"=>profiles,"dynamic_profiles"=>dynamic,"entries"=>entries}
output = ARGV[0] || "temp/outfit-entrypoints.json"
FileUtils.mkdir_p(File.dirname(output))
File.write(output, JSON.pretty_generate(report), encoding:"UTF-8")
puts JSON.generate(report.reject { |key,_| %w[entries generator_profiles dynamic_profiles].include?(key) })
puts "OUTFIT_ENTRYPOINTS_AUDIT_PASS profiles=#{profiles.length} dynamic=#{dynamic.length} report=#{output}"
