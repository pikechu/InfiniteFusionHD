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
check.call(Messages.stringToKey("  Frozen  text  ".freeze) == "Frozen text", "normalizes frozen translation keys")
check.call(ChineseLocalization.safe_translation?("\\bHello, \\PN!\\nWelcome!", "\\b你好，\\PN！\\n欢迎！"), "English words next to controls are not control names")
check.call(ChineseLocalization.safe_translation?("\\GWelcome!", "\\G欢迎！"), "gold window before English text remains translatable")
check.call(ChineseLocalization.safe_translation?("Letter\\nWe are ready.", "信件：我们准备好了。"), "line wrapping can change without swallowing English words")
check.call(!ChineseLocalization.safe_translation?("\\rRed text", "红色文字"), "red text control must not be dropped as a line break")
check.call(!ChineseLocalization.safe_translation?("\\bHello, \\PN!", "\\b你好！"), "player name is still mandatory next to English text")
check.call(ChineseLocalization.safe_translation?("Pick\\ch[1,2,Yes,No]", "请选择\\ch[1,2,是,否]"), "choice labels can be translated")
check.call(!ChineseLocalization.safe_translation?("Pick\\ch[1,2,Yes,No]", "请选择\\ch[2,2,是,否]"), "choice variable is preserved")
check.call(!ChineseLocalization.safe_translation?("Pick\\ch[1,2,Yes,No]", "请选择\\ch[1,0,是,否]"), "choice cancellation is preserved")
check.call(!ChineseLocalization.safe_translation?("Pick\\ch[1,2,Yes,No]", "请选择\\ch[1,2,是]"), "choice count is preserved")
check.call(!ChineseLocalization.safe_translation?("Continue\\1", "继续"), "escaped pause control is preserved")
check.call(ChineseLocalization.safe_translation?("Pick\\ch[5,\\V[3],\\V[20]Never mind]", "请选择\\ch[5,\\V[3],\\V[20]算了]"), "dynamic choice parameters are preserved")
check.call(!ChineseLocalization.safe_translation?("Pick\\ch[5,\\V[3],\\V[20]Never mind]", "请选择\\ch[5,\\V[3],\\V[21]算了]"), "variables inside choice labels cannot change")
check.call(ChineseLocalization.safe_translation?("\\f[\\v[2]]By \\V[259]", "\\f[\\V[2]]来自\\V[259]"), "nested face variables follow the runtime's case insensitive lookup")
check.call(ChineseLocalization.safe_translation?("Hi\\mMy \\TP won!", "你好\\m我的\\TP赢了！"), "phone page separators do not swallow English words")
check.call(!ChineseLocalization.safe_translation?("Hi\\mMy \\TP won!", "你好\\m我的\\TE赢了！"), "phone Pokemon references cannot change")
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
