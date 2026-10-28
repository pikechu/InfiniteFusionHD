# Import text only. Never evaluate a source script or replace game databases/maps.
require "json"
require "ripper"
require "digest"
require "fileutils"
require "csv"
ROOT = File.expand_path("../..", __dir__) unless defined?(ROOT)
load File.join(ROOT, "Data/Scripts/001_Technical/003_Intl_Messages.rb") unless defined?(Messages)

module ChineseLocalization
  CJK = /[\u3400-\u9fff]/
  # Match the game's control codes before adjacent English words (e.g. \bHello).
  CONTROLS = /\\(?:[A-Za-z]+\[(?:[^\[\]]|\[[^\[\]]*\])*\]|\[[0-9a-f]{8}\]|pog|pn|pm|pg|tp|te|tn|tm|cn|pt|ft|hs|wd|wm|op|cl|wu|[mnbrg]|[1.!|^<>\\]|[A-Za-z]+)|[\x01-\x08\x0b-\x1f]/i

  def self.controls(text)
    text.scan(CONTROLS).filter_map do |token|
      next if token.downcase == "\\n"
      next "\x01" if token == "\\1"
      if token =~ /\A\\ch\[(.*)\]\z/i
        fields = CSV.parse_line($1, strip: true)
        return nil unless fields && fields.length >= 3 && fields[0].match?(/\A\d+\z/)
        # Labels are translated; variable, cancel behavior and option count stay.
        nested = controls(fields.drop(2).join(","))
        return nil unless nested
        next JSON.generate(["ch", fields[0], fields[1].downcase, fields.length - 2, nested])
      end
      token.sub(/\A\\[A-Za-z]+/) { |code| code.downcase }.gsub(/\\[vn]\[/i) { |code| code.downcase }
    end.sort
  rescue CSV::MalformedCSVError
    return nil
  end

  def self.utf8(value)
    case value
    when String then value.dup.force_encoding("UTF-8")
    when Array then value.map! { |item| utf8(item) }
    when Hash then value.each_with_object(value.class.new) { |(key, item), hash| hash[utf8(key)] = utf8(item) }
    else value
    end
  end

  def self.safe_translation?(english, chinese)
    return false unless english.is_a?(String) && chinese.is_a?(String) && english.valid_encoding? && chinese.valid_encoding? && chinese.match?(CJK)
    placeholders = /\{\d+(?::[^}]+)?\}/
    before, after = controls(english), controls(chinese)
    return english.scan(placeholders).sort == chinese.scan(placeholders).sort &&
           before && after && before == after
  end

  def self.shape(node)
    return node unless node.is_a?(Array)
    if node[0].is_a?(Symbol) && node[0].to_s.start_with?("@")
      return [node[0], node[0] == :@tstring_content ? :text : node[1]]
    end
    return node.map { |child| shape(child) }
  end

  def self.units(node, scope = [], found = Hash.new { |hash, key| hash[key] = [] })
    return found unless node.is_a?(Array)
    if [:class, :module].include?(node[0])
      scope = scope + [shape(node[1])]
    elsif node[0] == :def
      found[[scope, :def, node[1][1]]] << node
      scope = scope + [[:def, node[1][1]]]
    elsif node[0] == :defs
      found[[scope, :defs, shape(node[1]), node[3][1]]] << node
      scope = scope + [[:defs, shape(node[1]), node[3][1]]]
    elsif [:assign, :method_add_arg, :method_add_block, :if, :unless, :case].include?(node[0])
      # Unique, structurally identical statements can survive unrelated edits
      # elsewhere in the same method. Repeated shapes remain ambiguous.
      found[[scope, :statement, shape(node)]] << node
    end
    node.each { |child| units(child, scope, found) if child.is_a?(Array) }
    return found
  end

  def self.strings(node, quotes, found = [])
    return found unless node.is_a?(Array)
    if node[0] == :string_literal
      content = node[1]
      tokens = content.is_a?(Array) ? content.drop(1) : []
      if !tokens.empty? && tokens.all? { |token| token.is_a?(Array) && token[0] == :@tstring_content }
        raw = tokens.map { |token| token[1] }.join
        quote = quotes[tokens[0][2]]
        begin
          value = if quote == "'"
                    raw.gsub(/\\([\\'])/, '\\1')
                  elsif quote == '"'
                    ascii = raw.gsub(/[^\x00-\x7f]/) { |char| "\\u{#{char.ord.to_s(16)}}" }
                    ('"' + ascii + '"').undump.force_encoding("UTF-8")
                  end
          found << value
        rescue RuntimeError
          found << nil
        end
      end
      return found
    end
    node.each { |child| strings(child, quotes, found) if child.is_a?(Array) }
    return found
  end

  def self.parse(text)
    text = text.sub(/\A\uFEFF/, "")
    quotes, stack = {}, []
    Ripper.lex(text).each do |position, event, value, _state|
      stack << value if event == :on_tstring_beg
      quotes[position] = stack.last if event == :on_tstring_content
      stack.pop if event == :on_tstring_end
    end
    return Ripper.sexp(text), quotes
  end

  def self.assignment(node, name)
    return nil unless node.is_a?(Array)
    return node[2] if node[0] == :assign && node.dig(1, 1, 1) == name
    node.each do |child|
      found = assignment(child, name) if child.is_a?(Array)
      return found if found
    end
    return nil
  end

  def self.script_translations(source, references, target)
    source, target = File.realpath(source).tr("\\", "/"), File.realpath(target).tr("\\", "/")
    candidates = Hash.new { |hash, key| hash[key] = [] }
    partial_candidates = Hash.new { |hash, key| hash[key] = [] }
    methods = 0
    Dir.glob("Data/Scripts/**/*.rb", base: source).sort.each do |relative|
      path = File.join(source, relative)
      local = File.join(target, relative)
      english = references[relative] || (File.read(local, encoding: "UTF-8") if File.file?(local))
      next unless english
      en_ast, en_quotes = parse(english)
      zh_ast, zh_quotes = parse(File.read(path, encoding: "UTF-8"))
      next unless en_ast && zh_ast
      pairs = []
      if shape(en_ast) == shape(zh_ast)
        pairs << [en_ast, zh_ast, false]
      else
        en_units, zh_units = units(en_ast), units(zh_ast)
        en_units.each do |key, values|
          other = zh_units[key]
          next unless values.length == 1 && other.length == 1 && shape(values[0]) == shape(other[0])
          pairs << [values[0], other[0], key[1] == :statement]
        end
      end
      pairs.each do |en_node, zh_node, partial|
        left, right = strings(en_node, en_quotes), strings(zh_node, zh_quotes)
        next unless left.length == right.length
        methods += 1
        left.zip(right).each do |before, after|
          next unless safe_translation?(before, after)
          key = Messages.stringToKey(before)
          pool = partial ? partial_candidates : candidates
          pool[key] << after unless pool[key].include?(after)
        end
      end
    end
    partial_candidates.each { |key, values| candidates[key] = values unless candidates.key?(key) }
    translations = candidates.select { |_key, values| values.length == 1 }.transform_values(&:first)
    return translations, {"matched_code_units" => methods, "ambiguous_strings_skipped" => candidates.count { |_key, values| values.length > 1 }}
  end

  def self.build(source, references, target = ROOT)
    chinese = utf8(Marshal.load(File.binread(File.join(source, "Data/Chinese.dat"))))
    original = utf8(Marshal.load(File.binread(File.join(source, "Data/messages.dat"))))
    english = utf8(Marshal.load(File.binread(File.join(target, "Data/messages.dat"))))
    result, counts, rejected = [], Hash.new(0), Hash.new(0)
    add = lambda do |section, key, before, after|
      if safe_translation?(before, after)
        result[section] ||= english[section].is_a?(Hash) ? OrderedHash.new : []
        result[section][key] = after
        counts[section.to_s] += 1
      elsif after.is_a?(String) && after.match?(CJK)
        rejected[section.to_s] += 1
      end
    end
    # Symbol IDs are the compatibility boundary; the source's numeric slots are not.
    groups = {"species" => [1, 2, 3, 4], "moves" => [5, 6], "items" => [7, 8, 9],
              "abilities" => [10, 11], "types" => [12], "trainer_types" => [13], "ribbons" => [25, 26]}
    module_names = %w[Species Move Item Ability Type TrainerType Ribbon]
    Object.const_set(:GameData, Module.new) unless defined?(GameData)
    module_names.each { |name| GameData.const_set(name, Class.new) unless GameData.const_defined?(name, false) }
    remapped = {}
    groups.each do |file, sections|
      before = Marshal.load(File.binread(File.join(source, "Data/#{file}.dat")))
      after = Marshal.load(File.binread(File.join(target, "Data/#{file}.dat")))
      moved, matched = 0, 0
      before.each do |symbol, entry|
        next unless symbol.is_a?(Symbol) && after[symbol]
        old_id, new_id = entry.instance_variable_get(:@id_number), after[symbol].instance_variable_get(:@id_number)
        next unless old_id.is_a?(Integer) && new_id.is_a?(Integer)
        matched += 1
        moved += 1 if old_id != new_id
        sections.each { |section| add.call(section, new_id, original[section]&.[](old_id), chinese[section]&.[](old_id)) }
      end
      remapped[file] = {"matched_ids" => matched, "changed_numeric_slots" => moved}
    end
    [14, 15, 16, 17, 19, 20, 22, 23].each do |section|
      next unless chinese[section].is_a?(Hash) && english[section].is_a?(Hash)
      chinese[section].each { |key, value| add.call(section, key, key, value) if english[section].key?(key) }
    end
    [18, 21].each do |section|
      chinese[section].each_with_index do |value, index|
        add.call(section, index, original[section][index], value) if original[section][index] == english[section][index]
      end
    end
    result[0] = []
    chinese[0].each_with_index do |messages, map_id|
      next unless messages.is_a?(Hash) && english[0][map_id].is_a?(Hash)
      next unless map_id == 0 || original[21][map_id] == english[21][map_id]
      translated = OrderedHash.new
      messages.each do |key, value|
        next unless english[0][map_id].key?(key)
        if safe_translation?(key, value)
          translated[key] = value
          counts["map_texts"] += 1
        elsif value.is_a?(String) && value.match?(CJK)
          rejected["map_texts"] += 1
        end
      end
      result[0][map_id] = translated unless translated.empty?
    end
    story = JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-story.json"), encoding: "UTF-8"))
    result[0][0] ||= OrderedHash.new
    story.each do |key, value|
      raise "Invalid story translation: #{key}" unless safe_translation?(key, value)
      key = Messages.stringToKey(key)
      result[0].compact.each { |messages| messages[key] = value if messages.key?(key) }
      result[0][0][key] = value
    end
    counts["map_texts"] = result[0].compact.sum(&:length)
    counts["story_overrides"] = story.length
    scripts, details = script_translations(source, references, target)
    overrides = JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-overrides.json"), encoding: "UTF-8"))
    overrides.merge!(JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-settings.json"), encoding: "UTF-8")))
    overrides.merge!(JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-offline-resources.json"), encoding: "UTF-8")))
    overrides.merge!(JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-ui.json"), encoding: "UTF-8")))
    overrides.merge!(JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-content.json"), encoding: "UTF-8")))
    overrides.merge!(JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-trainer-dialogue.json"), encoding: "UTF-8")))
    overrides.each do |key, value|
      raise "Invalid translation: #{key}" unless safe_translation?(key, value)
    end
    [2, 3, 4, 7, 8, 9, 21].each do |section|
      english[section].each_with_index do |text, id|
        next unless text.is_a?(String) && overrides[text]
        result[section] ||= []
        result[section][id] = overrides[text]
      end
      counts[section.to_s] = (result[section] || []).compact.count { |text| !text.empty? }
    end
    species_overrides = JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-species.json"), encoding: "UTF-8"))
    species_data = Marshal.load(File.binread(File.join(target, "Data/species.dat")))
    species_overrides.each do |symbol, fields|
      record = species_data.fetch(symbol.to_sym)
      id = record.instance_variable_get(:@id_number)
      fields.each do |field, translated|
        section = {"entry" => 3, "form" => 4}.fetch(field)
        raise "Invalid species translation: #{symbol}/#{field}" unless safe_translation?(english[section][id], translated)
        result[section] ||= []
        result[section][id] = translated
      end
    end
    [3, 4].each { |section| counts[section.to_s] = (result[section] || []).compact.count { |text| !text.empty? } }
    counts["species_overrides"] = species_overrides.length
    [16, 17, 22].each do |section|
      result[section] ||= OrderedHash.new
      english[section].each_key do |text|
        result[section][text] = overrides[text] if overrides[text]
      end
      counts[section.to_s] = result[section].length
    end
    result[24] = OrderedHash.new
    scripts.merge(overrides).sort.each { |key, value| result[24][Messages.stringToKey(key)] = value if safe_translation?(key, value) }
    counts["script_texts"] = result[24].length
    # The Chinese edition also translates the fusion name fragments. Read their
    # literal AST values, keeping the game's English constants and cached data.
    name_source = File.read(File.join(source, "Data/Scripts/048_Fusion/SplitNames.rb"), encoding: "UTF-8")
    name_ast, name_quotes = parse(name_source)
    names = assignment(name_ast, "SPLIT_NAMES")
    raise "Expected a literal fusion name table" unless names && names[0] == :array
    result[27], result[28] = [], []
    names[1].each_with_index do |row, index|
      parts = strings(row, name_quotes)
      next unless parts.length == 2 && parts.all? { |value| value.is_a?(String) }
      result[27][index], result[28][index] = parts
    end
    counts["fusion_name_pairs"] = result[27].count { |value| value && !value.empty? }
    report = {"source_version" => "6.4.6", "source_chinese_sha256" => Digest::SHA256.file(File.join(source, "Data/Chinese.dat")).hexdigest,
              "counts" => counts, "rejected_control_or_placeholder_mismatches" => rejected,
              "id_mapping" => remapped, "scripts" => details,
              "translated_maps" => result[0].compact.length, "overrides" => overrides.length}
    require_relative "apply_zh_additions"
    additions = JSON.parse(File.read(File.join(target, "Data/localization/zh-CN-quest-dialogue.json"), encoding: "UTF-8"))
    report["reviewed_quest_dialogue_additions"] = apply_additions(result, english, additions)
    counts["script_texts"] = result[24].length
    counts["map_texts"] = result[0].compact.sum(&:length)
    report["translated_maps"] = result[0].compact.length
    return result, report
  end
end

if $PROGRAM_NAME == __FILE__
  source = File.expand_path(ARGV.fetch(0)).tr("\\", "/")
  references = JSON.parse(File.read(ARGV.fetch(1), encoding: "UTF-8"))
  pack, report = ChineseLocalization.build(source, references)
  output = File.join(ROOT, "Data/messages_zh.dat")
  File.binwrite(output + ".pending", Marshal.dump(pack))
  File.rename(output + ".pending", output)
  report["pack_sha256"] = Digest::SHA256.file(output).hexdigest
  report["english_reference_sha256"] = Digest::SHA256.file(ARGV[1]).hexdigest
  File.write(File.join(ROOT, "Data/localization/zh-CN-report.json"), JSON.pretty_generate(report) + "\n")
  puts JSON.generate(report)
end
