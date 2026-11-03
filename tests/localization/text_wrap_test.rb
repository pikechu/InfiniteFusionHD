require "ostruct"
load File.expand_path("../../Data/Scripts/007_Objects and windows/010_DrawText.rb", __dir__)
class Font
  def self.exist?(*); true; end
end
class WrapBitmap
  attr_reader :font
  def initialize
    @font = OpenStruct.new(bold: false, italic: false, color: Object.new, name: "Test", size: 20)
  end
  def text_size(text); OpenStruct.new(width: text.length * 10, height: 32); end
  def disposed?; false; end
end
bitmap = WrapBitmap.new
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
text = "我相信你和小茂一定会在宝可梦之旅中玩得很开心！"
layout = getFormattedTextFast(bitmap, 0, 0, 102, -1, text, 32)
check.call(layout.map(&:first).join.delete("\n") == text, "CJK wrapping retains every character")
check.call(layout.any? { |char| char[2] >= 32 }, "unspaced Chinese wraps to another line")
check.call(layout.all? { |char| char[0] == "\n" || char[1] + char[3] <= 102 }, "Chinese glyphs fit within the text box")
punctuation = getFormattedTextFast(bitmap, 0, 0, 52, -1, "甲乙丙丁，甲乙（丙丁）甲乙。", 32)
punctuation.reject { |char| char[0] == "\n" }.group_by { |char| char[2] }.each_value do |line|
  check.call(!"，。！？）》】」』".include?(line.first[0]), "closing punctuation stays with the preceding character")
  check.call(!"（《【「『".include?(line.last[0]), "opening punctuation stays with the following character")
end
english = getFormattedTextFast(bitmap, 0, 0, 102, -1, "Hello world", 32)
check.call(english.select { |char| char[2] == 32 }.map(&:first).join == "world", "English words retain their original wrapping")
explicit = getFormattedTextFast(bitmap, 0, 0, 52, -1, text, 32, true, true)
check.call(explicit.none? { |char| char[0] == "\n" }, "explicit-break-only layouts stay unchanged")
class Font
  def self.default_color; Object.new; end
end
chunks = getLineBrokenChunks(bitmap, text, 102, nil, true)
check.call(chunks.map(&:first).join == text && chunks.any? { |chunk| chunk[2] > 0 }, "unformatted item descriptions wrap without dropping characters")
check.call(chunks.all? { |chunk| chunk[1] + chunk[3] <= 102 }, "unformatted item descriptions fit their width")
layout = getLineBrokenText(bitmap, text, 102, nil)
actual = layout.reject { |chunk| chunk[0].empty? || chunk[0] == "\n" }
check.call(actual.map(&:first).join == text && actual.any? { |chunk| chunk[2] > 0 }, "Chinese text entry layout also wraps")
check.call(actual.all? { |chunk| text[chunk[6], chunk[8]] == chunk[0] }, "wrapped Chinese text keeps cursor positions")
puts "TEXT_WRAP_PASS checks=#{checks}"
