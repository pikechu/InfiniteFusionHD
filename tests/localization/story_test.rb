require "ostruct"
require_relative "../../server/multiplayer/native/rgss_data"
class Tone; def self._load(*); new; end; end
class Color; def self._load(*); new; end; end
Dir.chdir(File.expand_path("../..", __dir__))
def pbRgssOpen(path, mode, &block); File.open(path, mode, &block); end
load "Data/Scripts/001_Technical/003_Intl_Messages.rb"
load "Data/Scripts/003_Game processing/003_Interpreter.rb"
load "Data/Scripts/003_Game processing/004_Interpreter_Commands.rb"
module Input
  def self.update; end
end
$game_map = OpenStruct.new(map_id: 2)
def pbShowCommands(_window, choices, cancel)
  $shown_choices, $cancel_choice = choices, cancel
  1
end
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
MessageTypes.loadMessageFile("Data/messages_zh.dat")
require "json"
require_relative "../../scripts/localization/import_zh"
JSON.parse(File.read("Data/localization/zh-CN-story.json", encoding: "UTF-8")).each do |english, chinese|
  check.call(ChineseLocalization.safe_translation?(english, chinese), "story arguments and controls: #{english}")
  check.call(_MAPINTL(0, english) == chinese, "compiled story repair: #{english}")
end
# Every text/choice page in the opening area, including Mom, Oak and the rival.
opening_texts = 0
[42, 43, 48, 76, 77, 78, 80, 81].each do |map_id|
  map = Marshal.load(File.binread("Data/Map%03d.rxdata" % map_id))
  map.events.each_value do |event|
    event.pages.each do |page|
      page.list.each_with_index do |command, index|
        texts = []
        if command.code == 101
          text = command.parameters[0].dup
          while page.list[index + 1]&.code == 401
            index += 1
            line = page.list[index].parameters[0].dup
            text += " " if !line.empty? && text[-1] != " "
            text += line
          end
          texts << text
        elsif command.code == 102
          texts.concat(command.parameters[0].map(&:dup))
        end
        texts.each do |text|
          next unless text.match?(/[A-Za-z]{3}/)
          next if ["Mooooooooo!", "Sluuuuuurp!", "Graah!"].include?(text)
          expected_text = _MAPINTL(map_id, text.dup.force_encoding(Encoding::UTF_8))
          check.call(_MAPINTL(map_id, text) == expected_text && expected_text.match?(/[\u3400-\u9fff]/), "opening dialogue #{map_id}:#{event.id}: #{text}")
          opening_texts += 1
        end
      end
    end
  end
end
check.call(_MAPINTL(2, "\\bHello. You must be \\PN.") == "\\b你好啊，你一定是\\PN了。", "story text immediately following a color control is translated")
letter = "Dear \\PN, \\|\\nWe are pleased to announce that your Pokémon League application has been accepted."
check.call(_MAPINTL(43, letter).match?(/[\u3400-\u9fff]/), "opening letter translates after its line and wait controls")
legacy_letter = letter.b.freeze
legacy_bytes = legacy_letter.bytes
check.call(_MAPINTL(43, legacy_letter) == _MAPINTL(43, letter), "legacy binary letter reaches the same translation")
check.call(legacy_letter.encoding == Encoding::ASCII_8BIT && legacy_letter.bytes == legacy_bytes, "lookup does not rewrite stored map strings")
check.call(_INTL("Pokédex".b.freeze) == _INTL("Pokédex") && _INTL("Pokédex") != "Pokédex", "legacy binary script labels use the shared lookup")
invalid_text = "\xFF".b.freeze
check.call(Messages.stringToKey(invalid_text) == invalid_text && Messages.stringToKey(invalid_text).encoding == Encoding::ASCII_8BIT, "invalid UTF-8 bytes retain the original fallback")
check.call(_MAPINTL(12, "\\bYour \\v[3] and \\v[4] are doing just fine.").include?("\\v[4]"), "daycare dialogue preserves both Pokemon references")
check.call(_MAPINTL(0, "\\ch[1,0,Kanto,Johto,Hoenn,Sinnoh,Kalos,Custom]").include?("关东"), "embedded story choice labels are translated")
StoryCommand = Struct.new(:code, :indent, :parameters)
command = StoryCommand.new(102, 3, [["Yes", "No"], 2])
before = Marshal.dump(command)
interpreter = Interpreter.new
interpreter.setup([command], 1)
interpreter.command_102
check.call($shown_choices == ["是", "否"] && $cancel_choice == 2, "standalone choices use the map's translation table")
check.call(interpreter.instance_variable_get(:@branch)[3] == 1, "translated choice keeps the original branch index")
check.call(Marshal.dump(command) == before, "translation leaves the stored event commands unchanged")
MessageTypes.loadMessageFile("Data/messages.dat")
interpreter.command_102
check.call($shown_choices == ["Yes", "No"], "English choices restore immediately")
check.call(_MAPINTL(43, letter) == letter, "English story text restores immediately")
puts "STORY_TEST_PASS checks=#{checks} opening_texts=#{opening_texts}"
