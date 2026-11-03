require "tmpdir"
require "fileutils"

ROOT = File.expand_path("../..", __dir__)
Dir.chdir(ROOT)
class << File
  alias exists? exist? unless respond_to?(:exists?)
end
class Color
  def initialize(*); end
end
class Font
  def self.exist?(_name); true; end
end
class Window_DrawableCommand; end
module KIF
  module Platform
    def self.android?; false; end
  end
end
def pbRgssExists?(path); File.file?(path); end
def pbRgssOpen(path, mode, &block); File.open(path, mode, &block); end
load "Data/Scripts/001_Settings.rb"
load "Data/Scripts/001_Technical/003_Intl_Messages.rb"
load "Data/Scripts/001_Technical/004_Language.rb"
load "Data/Scripts/007_Objects and windows/002_MessageConfig.rb"
load "Data/Scripts/016_UI/015_UI_Options.rb"
load "Data/Scripts/019_Utilities/001_Utilities.rb"
$PokemonSystem = PokemonSystem.new
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }

check.call(GameLanguage.available[0, 2] == [0, 1], "bundled English and French are available")
check.call(GameLanguage.load(0) && pbGetMessage(MessageTypes::Species, 1) == "Bulbasaur", "real English pack")
check.call(GameLanguage.load(1) && pbGetMessage(MessageTypes::Species, 1) == "Bulbizarre", "real French pack")
french = Marshal.load(File.binread("Data/messages_fr.dat"))
french_sample = nil
french[0].each_with_index do |messages, id|
  next unless messages
  key = messages.keys.find do |text|
    text.is_a?(String) && !text.ascii_only? && text.dup.force_encoding(Encoding::UTF_8).valid_encoding? && messages[text].bytes != text.bytes
  end
  french_sample = [id,key,messages[key]] if key
  break if french_sample
end
check.call(!french_sample.nil?, "legacy French map sample exists")
id, key, value = french_sample
check.call(_MAPINTL(id, key) == value && _MAPINTL(id, key.dup.force_encoding(Encoding::UTF_8)) == value, "French binary keys retain translation from either text encoding")
check.call(GameLanguage.load(0) && pbGetMessage(MessageTypes::Species, 1) == "Bulbasaur", "switch back to English")
check.call(GameLanguage.available.include?(2) && GameLanguage.load(2), "production Chinese pack is installed")
check.call(pbGetMessage(MessageTypes::Species, 1) == "妙蛙种子", "production Chinese species names")
check.call(_INTL("Fight") == "战斗" && _INTL("Options") == "设置", "extracted production UI translations")
check.call(_INTL("Shiny Animation") == "异色动画" && _INTL("Recover consumable items after battle") == "战后恢复消耗掉的道具", "supplementary settings labels and descriptions are compiled")
check.call(_INTL("Load {1}", "MY_PRESET") == "读取MY_PRESET", "translated preset prompt preserves custom names")
check.call(GameLanguage.fusion_name(1, 4, "Bulbamander") == "妙蛙火龙", "original Chinese fusion fragments")
check.call(GameLanguage.message(MessageTypes::Species, 9_999_999, "KIF custom") == "KIF custom", "KIF-only species keep their own fallback names")
pack = Marshal.load(File.binread("Data/messages_zh.dat"))
map_id = pack[0].each_index.find { |id| pack[0][id] && !pack[0][id].empty? }
key = pack[0][map_id].keys.first
check.call(_MAPINTL(map_id, key) == pack[0][map_id][key], "production map text is reached through the game's map translation lookup")
check.call(GameLanguage.load(0) && GameLanguage.fusion_name(1, 4, "Bulbamander") == "Bulbamander", "switching language restores English fusion names")
check.call(_INTL("Shiny Animation") == "Shiny Animation" && _INTL("Load {1}", "MY_PRESET") == "Load MY_PRESET", "supplementary labels and prompts restore English")
MessageConfig.pbSetSystemFontName("Power Clear")

def pbShowCommands(_window, commands, cancel, default)
  raise "chooser must support cancellation" unless cancel == -1
  raise "chooser needs a Chinese font" unless MessageConfig.pbGetSystemFontName == "Noto Sans SC"
  $language_commands = commands
  $language_default = default
  raise "chooser test error" if $language_choice == :raise
  return $language_choice
end

Dir.mktmpdir("kif-language-") do |directory|
  Dir.chdir(directory) do
    FileUtils.mkdir_p("Data")
    english = []
    english[MessageTypes::ScriptTexts] = Messages.createHash(24, ["Options", "Language", "Hello {1}"])
    File.binwrite("Data/messages.dat", Marshal.dump(english))
    chinese = []
    chinese[MessageTypes::ScriptTexts] = OrderedHash.new
    chinese[MessageTypes::ScriptTexts]["Options"] = "设置"
    chinese[MessageTypes::ScriptTexts]["Language"] = "语言"
    chinese[MessageTypes::ScriptTexts]["Hello {1}"] = "你好，{1}"
    File.binwrite("Data/messages_zh.dat", Marshal.dump(chinese))

    check.call(GameLanguage.available == [0, 2], "missing packs hidden without changing saved indices")
    $language_choice = 1
    check.call(pbChooseLanguage == 2 && $language_commands == ["English", "简体中文"], "chooser maps visible rows to saved indices")
    check.call(GameLanguage.load(2) && _INTL("Options") == "设置", "Chinese fixture loads through the native message system")
    check.call(_INTL("Hello {1}", "训练师") == "你好，训练师", "translation placeholders preserved")
    check.call(_INTL("Untranslated KIF text") == "Untranslated KIF text", "untranslated scripts retain source text")
    check.call(MessageConfig.pbGetSmallFontName == "Noto Sans SC" && MessageConfig.pbGetNarrowFontName == "Noto Sans SC", "all message font variants support Chinese")
    MessageConfig.pbSetSystemFontName("Noto Sans SC")
    check.call(PokemonOption_Scene.new.pbGetOptions(true).first.name == "语言: 简体中文", "language setting is on the main options page")
    saved = Marshal.load(Marshal.dump($PokemonSystem))
    check.call(saved.language == 2, "language persists in the existing save object")
    $language_choice = -1
    check.call(pbChooseLanguage == 2 && $language_default == 1, "cancel retains the selected language")
    check.call(GameLanguage.load(0) && _INTL("Options") == "Options", "English selection clears the previous translation")
    check.call(MessageConfig.pbGetSystemFontName == "Power Clear", "English restores the font preference after a temporary multiplayer UI override")
    $language_choice = :raise
    begin
      pbChooseLanguage
    rescue RuntimeError => error
      raise unless error.message == "chooser test error"
    end
    check.call(GameLanguage.font_name.nil?, "chooser font override is restored after errors")
    File.binwrite("Data/messages_zh.dat", "not a language file")
    check.call(!GameLanguage.load(2) && $PokemonSystem.language == 0 && _INTL("Options") == "Options", "corrupt translation falls back to English")
    File.delete("Data/messages_zh.dat")
    [2, -1, nil, "2", 99].each do |index|
      GameLanguage.load(index)
      check.call($PokemonSystem.language == 0, "missing or invalid language #{index.inspect} falls back to English")
    end
    check.call(GameLanguage.available == [0], "only installed languages remain selectable")
  end
end
puts "LANGUAGE_TEST_PASS checks=#{checks}"
