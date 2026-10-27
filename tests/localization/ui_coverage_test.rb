require "json"
require_relative "../../scripts/localization/import_zh"
Dir.chdir(ROOT)
def pbRgssOpen(path, mode, &block); File.open(path, mode, &block); end
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
MessageTypes.loadMessageFile("Data/messages_zh.dat")
translations = JSON.parse(File.read("Data/localization/zh-CN-ui.json", encoding: "UTF-8"))
translations.each do |english, chinese|
  check.call(ChineseLocalization.safe_translation?(english, chinese), "safe placeholders and controls: #{english}")
  check.call(_INTL(english) == chinese, "compiled UI translation: #{english}")
end
check.call(_INTL("You have P{1}", "12,345") == "持有金钱：¥12,345", "dynamic money is formatted after lookup")
check.call(_INTL("{1} Increment (0-{2})", "R", 400) == "R通道增量（0–400）", "dynamic channel and range are preserved")
check.call(_ISPRINTF("{1:s}\r\nID: {2:05d}   OT: {3:s}\\wtnp[0]", "TEST", 12, "PLAYER").include?("00012"), "formatted IDs remain usable")
MessageTypes.loadMessageFile("Data/messages.dat")
check.call(_INTL("You have P{1}", "12,345") == "You have P12,345", "English restores dynamic text")
puts "UI_COVERAGE_PASS checks=#{checks} translations=#{translations.length}"
