require "tmpdir"
require "fileutils"
require_relative "../../scripts/localization/import_zh"
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
check.call(ChineseLocalization.safe_translation?("Hello {1}", "你好，{1}"), "keeps numbered placeholders")
check.call(!ChineseLocalization.safe_translation?("Hello {1}", "你好"), "rejects a missing argument")
check.call(!ChineseLocalization.safe_translation?("Hello {1:d}", "你好，{1}"), "preserves formatted argument types")
check.call(!ChineseLocalization.safe_translation?("\\PN, wait!", "等一下！"), "rejects a missing player control")
check.call(!ChineseLocalization.safe_translation?("Continue\1", "继续"), "preserves nonprinting message controls")
check.call(ChineseLocalization.safe_translation?("Seed Pokemon", "种子\\n宝可梦"), "permits translated line wrapping")
check.call(!ChineseLocalization.safe_translation?("Actor \\n[1]", "角色"), "actor-name controls are not treated as line wrapping")
english = 'class Example; def title; _INTL("Hello {1}\\n"); end; end'
chinese = 'class Example; def title; _INTL("你好，{1}\\n"); end; end'
left, left_quotes = ChineseLocalization.parse(english)
right, right_quotes = ChineseLocalization.parse(chinese)
check.call(ChineseLocalization.shape(left) == ChineseLocalization.shape(right), "translation-only ASTs match")
check.call(ChineseLocalization.strings(right, right_quotes) == ["你好，{1}\n"], "decodes UTF-8 literals without evaluating source")
changed, = ChineseLocalization.parse(chinese.sub("_INTL(", "pbMessage("))
check.call(ChineseLocalization.shape(left) != ChineseLocalization.shape(changed), "rejects changed code")
Dir.mktmpdir("kif-translation-") do |directory|
  FileUtils.mkdir_p(File.join(directory, "Data/Scripts"))
  File.write(File.join(directory, "Data/Scripts/example.rb"), chinese)
  translations, = ChineseLocalization.script_translations(directory, {"Data/Scripts/example.rb" => english}, directory)
  check.call(translations["Hello {1}"] == "你好，{1}\n", "extracts text from matching source structure: #{translations.inspect}")
  File.write(File.join(directory, "Data/Scripts/example.rb"), chinese.sub("_INTL(", "pbMessage("))
  translations, = ChineseLocalization.script_translations(directory, {"Data/Scripts/example.rb" => english}, directory)
  check.call(translations.empty?, "changed source code supplies no guessed translation")
end
Dir.mktmpdir("kif-statement-") do |directory|
  FileUtils.mkdir_p(File.join(directory, "Data/Scripts"))
  en = 'def menu; mode = 0; pbMessage(_INTL("Hello {1}")); end'
  zh = 'def menu; mode = 1; pbMessage(_INTL("你好，{1}")); end'
  File.write(File.join(directory, "Data/Scripts/menu.rb"), zh)
  translations, = ChineseLocalization.script_translations(directory, {"Data/Scripts/menu.rb" => en}, directory)
  check.call(translations["Hello {1}"] == "你好，{1}", "recovers an unchanged display statement despite unrelated code changes")
end
puts "IMPORT_TEST_PASS checks=#{checks}"
