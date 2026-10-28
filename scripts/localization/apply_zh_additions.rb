# Apply reviewed text additions without rebuilding the historical translation pack.
require_relative "import_zh" unless defined?(ChineseLocalization)

module ChineseLocalization
  def self.apply_additions(pack, english, additions)
    counts = Hash.new(0)
    put = lambda do |table, source, translation|
      raise "Unsafe translation: #{source}" unless safe_translation?(source, translation)
      table[Messages.stringToKey(source)] = translation
    end
    pack[24] ||= OrderedHash.new
    additions.fetch("script_texts", {}).each do |source, translation|
      put.call(pack[24], source, translation)
      counts["script_texts"] += 1
    end
    additions.fetch("map_texts", {}).each do |map_id, texts|
      map_id = Integer(map_id)
      source_path = File.join(ROOT, map_id == 0 ? "Data/CommonEvents.rxdata" : "Data/Map%03d.rxdata" % map_id)
      reviewed_hash = additions.fetch("map_source_sha256", {})[map_id.to_s]
      source_verified = reviewed_hash && File.file?(source_path) && Digest::SHA256.file(source_path).hexdigest == reviewed_hash
      raise "Changed reviewed map: #{map_id}" if reviewed_hash && !source_verified
      pack[0] ||= []
      pack[0][map_id] ||= OrderedHash.new
      texts.each do |source, translation|
        key = Messages.stringToKey(source)
        raise "Changed map source: #{map_id}/#{source}" unless source_verified || english.dig(0, map_id)&.key?(key)
        put.call(pack[0][map_id], source, translation)
        counts["map_texts"] += 1
      end
    end
    additions.fetch("indexed_texts", []).each do |entry|
      section, id = entry.fetch("section"), entry.fetch("id")
      source, translation = entry.fetch("source"), entry.fetch("translation")
      raise "Changed indexed source: #{section}/#{id}" unless english.dig(section, id) == source
      raise "Unsafe indexed translation: #{source}" unless safe_translation?(source, translation)
      pack[section] ||= []
      pack[section][id] = translation
      counts["indexed_texts"] += 1
    end
    return counts
  end
end

if $PROGRAM_NAME == __FILE__
  output = File.join(ROOT, "Data/messages_zh.dat")
  pack = Marshal.load(File.binread(output))
  english = ChineseLocalization.utf8(Marshal.load(File.binread(File.join(ROOT, "Data/messages.dat"))))
  additions = JSON.parse(File.read(File.join(ROOT, "Data/localization/zh-CN-quest-dialogue.json"), encoding: "UTF-8"))
  counts = ChineseLocalization.apply_additions(pack, english, additions)
  File.binwrite(output + ".pending", Marshal.dump(pack))
  File.rename(output + ".pending", output)
  report_path = File.join(ROOT, "Data/localization/zh-CN-report.json")
  report = JSON.parse(File.read(report_path, encoding: "UTF-8"))
  report["pack_sha256"] = Digest::SHA256.file(output).hexdigest
  report["reviewed_quest_dialogue_additions"] = counts
  report["counts"]["script_texts"] = pack[24].length
  report["counts"]["map_texts"] = pack[0].compact.sum(&:length)
  report["translated_maps"] = pack[0].compact.length
  File.write(report_path, JSON.pretty_generate(report) + "\n")
  puts JSON.generate(counts)
end
