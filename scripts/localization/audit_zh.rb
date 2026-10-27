# Read-only inventory of translation lookups and compiled data; never evaluates scripts.
require_relative "import_zh"
Dir.chdir(ROOT)
english = ChineseLocalization.utf8(Marshal.load(File.binread("Data/messages.dat")))
chinese = ChineseLocalization.utf8(Marshal.load(File.binread("Data/messages_zh.dat")))
missing, raw, dynamic = {}, {}, []
checked_scripts, parse_failures = 0, []
Dir["Data/Scripts/**/*.rb"].sort.each do |path|
  next if path.match?(%r{/020_Debug/|/021_Compiler/})
  ast, quotes = ChineseLocalization.parse(File.read(path, encoding: "UTF-8"))
  checked_scripts += 1
  parse_failures << path unless ast
  walk = lambda do |node|
    next unless node.is_a?(Array)
    if node[0] == :method_add_arg
      call = node[1]
      name = call[0] == :fcall ? call.dig(1, 1) : (call[0] == :call ? call.dig(3, 1) : nil)
      argument = node.dig(2, 1, 1, 0)
      if %w[_INTL _ISPRINTF pbMessage pbDisplay pbConfirmMessage pbConfirmMessageSerious].include?(name)
        if argument && argument[0] == :string_literal
          value = ChineseLocalization.strings(argument, quotes).first
          if value && value.match?(/[A-Za-z]{3}/) && !value.match?(%r{\A(?:Graphics/|Audio/)|\.(?:png|gif|rxdata)\z}) && !value.match?(ChineseLocalization::CJK)
            key = Messages.stringToKey(value)
            target = %w[_INTL _ISPRINTF].include?(name) ? missing : raw
            (target[key] ||= []) << path if target.equal?(raw) || !chinese[24]&.[](key)
          end
        elsif %w[_INTL _ISPRINTF].include?(name) && argument && argument[0] != :var_ref && argument[0] != :method_add_arg
          token = argument.flatten(1).find { |value| value.is_a?(Array) && value[2].is_a?(Array) && value[2][0].is_a?(Integer) }
          dynamic << {"path" => path, "line" => token && token[2][0], "shape" => argument[0].to_s}
        end
      end
    end
    node.each { |child| walk.call(child) if child.is_a?(Array) }
  end
  walk.call(ast)
end
data = {}
%w[Species Move Item Ability Type TrainerType Ribbon].each do |name|
  Object.const_set(:GameData, Module.new) unless defined?(GameData)
  GameData.const_set(name, Class.new) unless GameData.const_defined?(name, false)
end
{"items" => [7, 8, 9], "moves" => [5, 6], "abilities" => [10, 11], "types" => [12], "species" => [1, 2, 3, 4]}.each do |name, sections|
  records = Marshal.load(File.binread("Data/#{name}.dat"))
  rows = []
  records.each do |symbol, record|
    next unless symbol.is_a?(Symbol)
    id = record.instance_variable_get(:@id_number)
    sections.each do |section|
      original = english[section]&.[](id)
      translated = chinese[section]&.[](id)
      next unless original.is_a?(String) && original.match?(/[A-Za-z]{3}/) && !translated.to_s.match?(ChineseLocalization::CJK)
      rows << {"id" => symbol.to_s, "slot" => id, "section" => section, "english" => original, "translation" => translated}
    end
  end
  data[name] = rows
end
result = {"data" => data, "script_missing" => missing.transform_values(&:uniq), "raw_ui" => raw.transform_values(&:uniq), "dynamic" => dynamic.uniq}
require_relative "../../server/multiplayer/native/rgss_data"
class Tone; def self._load(*); new; end; end
class Color; def self._load(*); new; end; end
story, event_scripts, map_files = [], {}, 0
scan_list = lambda do |list, map_id, event_id|
  list.each_with_index do |command, index|
    texts = []
    if command.code == 101
      text = command.parameters[0].dup.force_encoding("UTF-8")
      while list[index + 1]&.code == 401
        index += 1
        line = list[index].parameters[0].dup.force_encoding("UTF-8")
        text += " " if !line.empty? && text[-1] != " "
        text += line
      end
      texts << text
    elsif command.code == 102
      texts.concat(command.parameters[0].map { |text| text.dup.force_encoding("UTF-8") })
    elsif command.code == 355
      script = command.parameters[0].dup.force_encoding("UTF-8")
      while list[index + 1]&.code == 655
        index += 1
        script += "\n" + list[index].parameters[0].dup.force_encoding("UTF-8")
      end
      ast, quotes = ChineseLocalization.parse(script)
      visit = lambda do |node|
        next unless node.is_a?(Array)
        if node[0] == :method_add_arg && node.dig(1, 0) == :fcall && %w[pbMessage pbConfirmMessage pbConfirmMessageSerious _I _INTL].include?(node.dig(1, 1, 1))
          argument = node.dig(2, 1, 1, 0)
          text = ChineseLocalization.strings(argument, quotes).first if argument && argument[0] == :string_literal
          texts << text if text
        end
        node.each { |child| visit.call(child) if child.is_a?(Array) }
      end
      visit.call(ast)
    end
    texts.each do |text|
      next unless text.match?(/[A-Za-z]{3}/) && !text.match?(ChineseLocalization::CJK)
      key = Messages.stringToKey(text)
      next if chinese[0][map_id]&.[](key) || chinese[0][0]&.[](key) || chinese[24]&.[](key)
      row = {"map" => map_id, "event" => event_id, "text" => text}
      if command.code == 355
        (event_scripts[key] ||= []) << [map_id, event_id]
      else
        story << row
      end
    end
  end
end
Dir["Data/Map*.rxdata"].sort.each do |path|
  next unless path =~ /Map(\d+)\.rxdata/
  map_id = $1.to_i
  map_files += 1
  map = Marshal.load(File.binread(path))
  map.events.each_value { |event| event.pages.each { |page| scan_list.call(page.list, map_id, event.id) } }
end
common_events = Marshal.load(File.binread("Data/CommonEvents.rxdata")).compact
common_events.each { |event| scan_list.call(event.list, 0, event.id) }
result["story_missing"] = story.uniq
result["event_script_missing"] = event_scripts
result["dialogue_missing"] = {}
[15, 16, 17, 22, 23].each do |section|
  result["dialogue_missing"][section.to_s] = english[section].keys.select do |text|
    text.match?(/[A-Za-z]{3}/) && !(chinese[section]&.[](text) || chinese[24]&.[](Messages.stringToKey(text))).to_s.match?(ChineseLocalization::CJK)
  end
end
custom = JSON.parse(File.read("Data/pokedex/dex.json", encoding: "UTF-8"))
result["community_dex"] = {"records" => custom.length, "without_chinese" => custom.count { |row| !row["entry"].to_s.match?(ChineseLocalization::CJK) }}
result["preserved"] = ["DNA", "TCG", "FGM", "Windows XP"]
result["coverage"] = {"script_files" => checked_scripts, "parse_failures" => parse_failures, "map_files" => map_files, "common_events" => common_events.length}
raise "No game resources were audited" if checked_scripts == 0 || map_files == 0 || common_events.empty?
raise "Unparsed scripts: #{parse_failures.join(', ')}" unless parse_failures.empty?
output = ARGV[0] || "temp/localization/full-audit.json"
File.write(output, JSON.pretty_generate(result) + "\n")
puts JSON.generate({"output" => output, "data_missing" => data.transform_values(&:length), "script_missing" => missing.length, "raw_ui" => raw.length, "dynamic" => dynamic.length,
                    "story_missing" => story.length, "event_script_missing" => event_scripts.length, "dialogue_missing" => result["dialogue_missing"].transform_values(&:length), "community_dex" => result["community_dex"]})
