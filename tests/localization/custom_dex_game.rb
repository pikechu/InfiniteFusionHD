# Exercise the real JSON parser, font metrics, pagination and native rendering.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  Graphics.resize_screen(Settings::SCREEN_WIDTH, Settings::SCREEN_HEIGHT)
  check = KIFMultiplayerFeatureTest.method(:check)
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  source_path = Settings::CUSTOM_DEX_ENTRIES_PATH
  source_hash = Digest::SHA256.hexdigest(File.binread(source_path))
  original = KIF::PokedexEntries.parse(File.binread(source_path))
  chinese = KIF::PokedexEntries.parse(File.binread(KIF::PokedexEntries::CHINESE_PATH))
  translated_sources = chinese.to_h { |row| [row["source"],true] }
  expected = original.select { |row| translated_sources.key?(row["entry"]) }
  check.call(original.length >= 15_005 && chinese.length == expected.length, "reviewed corpus maps to every matching upstream record")
  expected.zip(chinese).each_with_index do |(en,zh), index|
    raise "Record identity changed #{index}" unless en["sprite"] == zh["sprite"] && en["author"] == zh["author"] && en["entry"] == zh["source"]
    raise "Missing Chinese #{index}" unless zh["entry"].match?(/[\u3400-\u9fff]/)
    raise "English remains #{index}" if zh["entry"].gsub("POKENAME", "").gsub("DNA", "").match?(/[A-Za-z]{3}/)
  end
  english_index = original.group_by { |row| row["sprite"] }.transform_values { |rows| rows.map { |row| row["entry"] } }
  translations = chinese.to_h { |row| [[row["sprite"],row["source"],row["author"]],row["entry"]] }
  chinese_index = original.group_by { |row| row["sprite"] }.transform_values { |rows| rows.map { |row| translations[[row["sprite"],row["entry"],row["author"]]] || row["entry"] } }
  [0,2,0].each do |language|
    GameLanguage.load(language)
    index = language == 2 ? chinese_index : english_index
    index.each do |sprite,entries|
      raise "Wrong display language #{language}/#{sprite}" unless KIF::PokedexEntries.entries_for(sprite) == entries
    end
  end
  GameLanguage.load(2)
  species = :B1H1
  $Trainer.pokedex.set_seen(species)
  $Trainer.pokedex.set_owned(species)
  scene = PokemonPokedexInfo_Scene.new
  # Pick a bundled community record deterministically, without requiring a
  # download of its artist sprite in this isolated test profile.
  scene.define_singleton_method(:getCustomEntryText) do |data|
    getCustomDexEntry("1.1.png").first.gsub(Settings::CUSTOM_ENTRIES_NAME_PLACEHOLDER, data.name)
  end
  scene.pbStartSceneBrief(species)
  background = scene.instance_variable_get(:@sprites)["background"]
  $kif_test_log.call("DEX_RENDER width=#{Graphics.width} height=#{Graphics.height} background=#{background.instance_variable_get(:@name)} resolved=#{GameLanguage.bitmap_path(background.instance_variable_get(:@name))} cache=#{RPG::Cache.instance_variable_get(:@cache).keys.grep(/bg_info/).inspect}")
  Graphics.update
  Graphics.screenshot(File.join(directory,"custom-dex-zh.png"))
  bitmap = scene.instance_variable_get(:@sprites)["overlay"].bitmap
  total_pages = 0
  chinese.each_with_index do |row,index|
    text = row["entry"].gsub("POKENAME", "妙蛙种子")
    pages = scene.splitTextIntoPages(text,150)
    raise "Truncated entry #{index}" unless pages.join.delete("\n") == text.delete("\n")
    pages.each do |page|
      chunks = getLineBrokenChunks(bitmap,page,Graphics.width-80,nil,true)
      raise "Hidden fifth line #{index}" unless chunks.all? { |chunk| chunk[2] < 128 }
      raise "Overflowing line #{index}" unless chunks.all? { |chunk| chunk[1]+chunk[3] <= Graphics.width-80 }
    end
    total_pages += pages.length
  end
  longest = chinese.max_by { |row| row["entry"].length }
  scene.define_singleton_method(:getCustomEntryText) { |data| (longest["entry"] * 3).gsub("POKENAME",data.name) }
  scene.instance_variable_set(:@entry_page,0)
  scene.reloadDexEntry
  count = scene.instance_variable_get(:@entryPageCount)
  check.call(count > 2, "long Chinese uses at least three pages")
  count.times do |page|
    Graphics.update
    Graphics.screenshot(File.join(directory,"long-custom-dex-#{page+1}.png"))
    scene.changeEntryPage
  end
  check.call(scene.instance_variable_get(:@entry_page) == 0, "page navigation cycles all pages")
  scene.pbEndScene
  check.call(Digest::SHA256.hexdigest(File.binread(source_path)) == source_hash,"source descriptions and author credits stay unchanged")
  KIFMultiplayerFeatureTest.log("CUSTOM_DEX_NATIVE_PASS entries=#{original.length} translated=#{chinese.length} sprites=#{chinese_index.length} pages=#{total_pages} language_rounds=3 normal_player_saves=false")
  passed = true
rescue Exception => error
  $kif_test_log.call("CUSTOM_DEX_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
