# Loaded inside game_smoke.rb after the production runtime is initialized.
check = KIFMultiplayerFeatureTest.method(:check)
GameLanguage.load(2)
KIFMultiplayerFeatureTest.log("QUEST_PACK sha256=#{Digest::SHA256.hexdigest(File.binread("Data/messages_zh.dat"))}")
quests = QUESTS.values + TR_QUESTS.values
stored_quests = Marshal.dump(quests)
bitmap = Bitmap.new(318, 256)
pbSetSystemFont(bitmap)
quests.each do |quest|
  [quest.name, quest.desc, quest.npc, quest.location].each do |source|
    translated = pbQuestText(source)
    raise "Untranslated quest #{quest.id}: #{source}" unless translated.match?(/[\u3400-\u9fff]/)
  end
  text = pbQuestText(quest.desc)
  chunks = getLineBrokenChunks(bitmap, text, 318, nil, true)
  raise "Quest description clipped: #{quest.id}" unless chunks.all? { |chunk| chunk[2] < 256 && chunk[1] + chunk[3] <= 318 }
end
bitmap.dispose
check.call(Marshal.dump(quests) == stored_quests, "all77 native quest fields translated without changing saved definitions")
check.call(pbQuestText("Defeat all of the Type Experts scattered around the Kanto region (3/12)").include?("3/12"), "old saved expert progress is preserved")
original_quests = $Trainer.quests
$Trainer.quests = Marshal.load(Marshal.dump(QUESTS.values.first(8) + TR_QUESTS.values.first(1)))
$Trainer.quests.last.completed = true
quest_save = Marshal.dump($Trainer.quests)
class LocalizationQuestProbe < Questlog
  def pbUpdate
    directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
    Graphics.update
    Graphics.screenshot(File.join(directory, "quest-categories-zh.png"))
    pbList(0)
    Graphics.update
    Graphics.screenshot(File.join(directory, "quest-list-zh.png"))
    pbLoad(0)
    Graphics.update
    Graphics.screenshot(File.join(directory, "quest-description-zh.png"))
    pbList(1)
    pbLoad(0)
    Graphics.update
    Graphics.screenshot(File.join(directory, "rocket-quest-zh.png"))
  ensure
    pbDisposeSpriteHash(@sprites) if @sprites
    @viewport.dispose if @viewport && !@viewport.disposed?
  end
end
LocalizationQuestProbe.new
check.call(Marshal.dump($Trainer.quests) == quest_save, "actual quest UI leaves legacy saved English fields and progress unchanged")
$Trainer.quests = original_quests
outfit_fields = 0
%w[clothes hats hairstyles].each do |category|
  catalog = KIFMultiplayer::WireJSON.parse(File.binread("Data/outfits/#{category}_data.json"))
  catalog.each do |fields|
    id = fields.fetch("id")
    outfit = Outfit.new(id, fields["name"], fields["description"])
    serialized = Marshal.dump(outfit)
    [outfit.name, outfit.description].each do |text|
      next if !text || text.empty?
      raise "Untranslated #{category}/#{id}: #{text}" unless text.match?(/[\u3400-\u9fff]/)
      outfit_fields += 1
    end
    raise "Outfit saved data changed #{id}" unless Marshal.dump(outfit) == serialized && outfit.id == id
  end
end
check.call(GameData::Item.get(:REVEALGLASS).description == "可以追踪异常天气变化的装置。", "weather tracker description matches its source")
check.call(GameData::Item.get(:XATTACK6).name == "力量强化6", "six-stage item shows the correct rank")
check.call(GameData::Item.get(:HM08).name == "HM08", "standard HM code is preserved")
# Exercise the real shared raw-message boundary without waiting for player input.
original_display = Object.instance_method(:pbMessageDisplay)
captured_message = nil
Object.send(:define_method, :pbMessageDisplay) do |window, text, *arguments, &callback|
  captured_message = text
  original_display.bind(self).call(window, text, false)
  Graphics.update
  Graphics.screenshot(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "raw-dialogue-zh.png"))
end
begin
  pbMessage("Woah! A Pokémon jumped out!")
  check.call(captured_message == "哇！一只宝可梦跳了出来！", "raw event pbMessage reaches the Chinese table")
ensure
  Object.send(:define_method, :pbMessageDisplay, original_display)
end
commands = ["Yes".freeze, "No".freeze].freeze
help = ["Options".freeze, "Quest Log".freeze].freeze
serialized_choices = Marshal.dump([commands, help])
original_trigger = Input.method(:trigger?)
Input.define_singleton_method(:trigger?) { |key| key == Input::USE }
help_window = pbCreateMessageWindow
begin
  selected = pbShowCommands(help_window, commands, -1, 1)
  check.call(selected == 1, "translated shared commands retain their selected branch")
  selected = pbShowCommandsWithHelp(help_window, commands, help, -1, 1)
  check.call(selected == 1 && help_window.text == _INTL("Quest Log"), "direct help array uses translated text with the same branch")
  check.call(Marshal.dump([commands, help]) == serialized_choices, "shared menus preserve frozen source arrays")
ensure
  Input.define_singleton_method(:trigger?, original_trigger)
  pbDisposeMessageWindow(help_window)
end
hall = HallOfFame_Scene.allocate
check.call(hall.displayGameMode("Classic mode") == "经典模式", "saved Hall of Fame mode is localized only for display")
check.call(hall.displayGameMode("Bulbasaur mode") == "妙蛙种子模式", "single-species history uses the localized species name")
original_bag = $PokemonBag
quantities = { :DNASPLICERS => 4, :SUPERSPLICERS => 2, :INFINITESPLICERS => 1, :INFINITESPLICERS2 => 1 }
$PokemonBag = Object.new
$PokemonBag.define_singleton_method(:pbQuantity) { |item| quantities.fetch(item, 0) }
storage = PokemonStorageScreen.allocate
choice_index = 0
storage.define_singleton_method(:pbShowCommands) do |prompt, options|
  raise "Splicer labels not translated" unless prompt.match?(/[\u3400-\u9fff]/) && options.all? { |text| text.match?(/[\u3400-\u9fff]/) }
  choice_index
end
begin
  [:INFINITESPLICERS2, :SUPERSPLICERS, :DNASPLICERS].each_with_index do |item, index|
    choice_index = index
    check.call(storage.selectSplicer == item, "translated splicer label still returns #{item}")
  end
  quantities[:INFINITESPLICERS2] = 0
  choice_index = 0
  check.call(storage.selectSplicer == :INFINITESPLICERS, "original infinite splicer fallback is preserved")
ensure
  $PokemonBag = original_bag
end
credits = Scene_Credits.allocate
original_credits = Scene_Credits::CREDIT.dup
credit_lines = credits.credit_text_for_display.split("\n", -1)
credit_bitmap = Bitmap.new(512, 32)
pbSetSystemFont(credit_bitmap)
minimum_credit_size = credit_bitmap.font.size
Scene_Credits::CREDIT.split("\n", -1).zip(credit_lines).each do |source, translated|
  expected = Scene_Credits::LOCALIZABLE_CREDIT_LINES.include?(source) ? _INTL(source) : source
  raise "Credits author/prose mismatch #{source}" unless translated == expected
  segments = translated.split("<s>")
  width = segments.length > 1 ? Graphics.width / 2 - 20 : Graphics.width
  segments.each do |segment|
    size = credit_bitmap.font.size
    credit_bitmap.font.size -= 1 while credit_bitmap.text_size(segment).width > width - 4 && credit_bitmap.font.size > 10
    raise "Credits line clipped #{source}" if credit_bitmap.text_size(segment).width > width - 4
    minimum_credit_size = [minimum_credit_size, credit_bitmap.font.size].min
    credit_bitmap.font.size = size
  end
end
credit_bitmap.dispose
check.call(Scene_Credits::CREDIT == original_credits, "credits preserve original static author list")
KIFMultiplayerFeatureTest.log("CREDITS_LAYOUT_PASS min_font_size=#{minimum_credit_size}")
GameLanguage.load(0)
check.call(pbQuestText(quests.first.name) == quests.first.name, "native English quest labels restore immediately")
check.call(credits.credit_text_for_display == original_credits, "credits restore original English without cached Chinese")
GameLanguage.load(2)
check.call(Marshal.dump(quests) == stored_quests, "native language switches preserve all quest definitions")
KIFMultiplayerFeatureTest.log("QUEST_DIALOGUE_NATIVE_PASS quests=#{quests.length} outfit_fields=#{outfit_fields} normal_player_saves=false")
