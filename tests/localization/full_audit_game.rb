# Inspect the displayed runtime values, including dynamically registered KIF items.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  GameData.kurayeggs_loadsystem
  GameData.kuraychests_loadchests
  report = {}
  problems, checks = [], 0
  [0, 2, 0].each_with_index do |language, round|
    GameLanguage.load(language)
    $kif_test_log.call("AUDIT_LANGUAGE round=#{round} language=#{language} pack=#{Digest::SHA256.hexdigest(File.binread('Data/messages_zh.dat'))}")
    report[round.to_s] = {}
    {"items" => GameData::Item, "moves" => GameData::Move, "abilities" => GameData::Ability, "species" => GameData::Species}.each do |name, klass|
      rows = []
      klass.each do |record|
        row = {"id" => record.id.to_s, "slot" => record.id_number, "name" => record.name, "description" => record.respond_to?(:description) ? record.description : record.pokedex_entry}
        row["plural"] = record.name_plural if record.respond_to?(:name_plural)
        row.each do |field, text|
          next unless %w[name description plural].include?(field)
          checks += 1
          problems << "#{language}/#{name}/#{record.id}/#{field} is blank" if text.empty?
          next unless language == 2
          next if field != "description" && text.match?(/\A(?:TM|HM)\d+s?\z/)
          problems << "#{name}/#{record.id}/#{field}: #{text}" unless text.match?(/[\u3400-\u9fff]/)
        end
        rows << row
      end
      report[round.to_s][name] = rows
    end
    $scene = Scene_Map.allocate
    screens = [PokemonOption_Scene, KurayOptionsScene, SLOptionsScene, VanillaOptSc_1,
               KurayOptSc_1, KurayOptSc_2, KurayOptSc_3, KurayOptSc_4, KurayOptSc_5, KurayOptSc_6]
    report[round.to_s]["settings"] = screens.flat_map do |klass|
      scene = klass.new
      scene.pbAddOnOptions(scene.pbGetOptions(false)).flat_map do |option|
        values = [option.name]
        values.concat(option.values) if option.respond_to?(:values)
        values.concat(Array(option.description)) if option.respond_to?(:description)
        values.map { |text| {"screen" => klass.name, "text" => _INTL(text.to_s)} }
      end
    end
    report[round.to_s]["wallpapers"] = PokemonStorage.new(1).allWallpapers
    if language == 2
      source_messages = Marshal.load(File.binread("Data/messages.dat"))
      [16, 17, 22].each do |section|
        source_messages[section].each_key do |text|
          next unless text.match?(/[A-Za-z]{3}/)
          checks += 1
          problems << "dialogue/#{section}: #{text}" unless pbGetMessageFromHash(section, text).match?(/[\u3400-\u9fff]/)
        end
      end
      preserved = %w[DNA TCG FGM]
      report[round.to_s]["settings"].each do |row|
        text = row["text"]
        next unless text.match?(/[A-Za-z]{3}/) && !preserved.include?(text)
        checks += 1
        problems << "#{row['screen']}: #{text}" unless text.match?(/[\u3400-\u9fff]/)
      end
      SLOptionsScene.new.tap do |scene|
        before = $PokemonSystem.optionsnames[0]
        $PokemonSystem.optionsnames[0] = "Normal"
        raise "Custom preset name was translated" unless scene.createButtonsOption(0).name == "Normal"
        $PokemonSystem.optionsnames[0] = before
      end
      report[round.to_s]["wallpapers"].each do |text|
        checks += 1
        problems << "wallpaper: #{text}" unless text == "Windows XP" || text.match?(/[\u3400-\u9fff]/)
      end
      GameData.kurayeggs_loadsystem
      raise "Registering items overwrote Chinese descriptions" unless GameData::Item.get(:KURAYEGG_RANDOM).description.match?(/[\u3400-\u9fff]/)
      fusion = GameData::Species.get(:B4H1)
      original = Marshal.dump([fusion, fusion.body_pokemon, fusion.head_pokemon])
      raise "Generated fusion entry is still English" unless fusion.get_random_dex_entry.match?(/[\u3400-\u9fff]/)
      raise "Fusion translation mutated species data" unless Marshal.dump([fusion, fusion.body_pokemon, fusion.head_pokemon]) == original
      # Real bag and settings rendering, including their unformatted descriptions.
      $scene = Object.new
      $PokemonBag.pbStoreItem(:KURAYEGG_RANDOM, 1)
      $PokemonBag.lastpocket = GameData::Item.get(:KURAYEGG_RANDOM).pocket
      bag = PokemonBag_Scene.new
      bag.pbStartScene($PokemonBag)
      Graphics.update
      Graphics.screenshot(File.join($kif_test_directory, "kif-egg-bag-zh.png"))
      bag.pbEndScene
      options = SLOptionsScene.new
      options.pbStartScene(false)
      Graphics.update
      Graphics.screenshot(File.join($kif_test_directory, "preset-settings-zh.png"))
      options.pbEndScene
    end
  end
  File.write(File.join($kif_test_directory, "full-runtime-audit.json"), KIFMultiplayer::WireJSON.dump(report))
  raise problems.first(20).join("\n") unless problems.empty?
  raise "Language switch changed original item data" unless report["0"]["items"] == report["2"]["items"]
  $kif_test_log.call("FULL_RUNTIME_AUDIT_PASS checks=#{checks}")
  passed = true
rescue Exception => error
  $kif_test_log.call("FULL_RUNTIME_AUDIT_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
