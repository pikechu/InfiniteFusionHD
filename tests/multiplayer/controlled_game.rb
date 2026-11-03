begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  success = false
  baseline = test.digest
  real_save = SaveData.compile_save_hash
  File.write(File.join($kif_test_directory, "native-cloud-save.json"), KIFMultiplayer::WireJSON.dump(KIFMultiplayer::CloudCodec.pack(real_save)))
  test.log("CONTROLLED_NATIVE_SAVE_EXPORTED money=#{$Trainer.money} party=#{$Trainer.party.length} kuray=#{real_save.key?(:kuray_player)}")
  client = KIFMultiplayer::Client.new
  client.authenticate("register", "ctrl_#{Process.pid}_#{Time.now.to_i}", "ControlledRuntimeFixture123", "受控角色原生测试")
  model = KIFMultiplayer::ControlledClient.new(client).refresh
  character = model.create("原生受控角色")
  test.check(character["wallet"]["balance"] == 1000, "CONTROLLED_INITIAL_GOLD")
  item = model.catalog["items"].first
  character = model.trade(character, "buy", item, 1)
  test.check(character["wallet"]["balance"] == 800 && character["inventory"].first["quantity"] == 1, "CONTROLLED_NPC_PURCHASE")
  character = model.trade(character, "sell", item, 1)
  test.check(character["wallet"]["balance"] == 900 && character["inventory"].empty?, "CONTROLLED_NPC_SALE")
  test.check(model.daily(character) == 100, "CONTROLLED_DAILY_GOLD")
  character = model.character(character["id"])
  test.check(model.daily(character) == 0, "CONTROLLED_NO_DUPLICATE_DAILY")
  character = model.character(character["id"])
  test.check(test.digest == baseline, "CONTROLLED_LEGACY_SAVE_UNCHANGED")
  test.check(PokemonPauseMenu_Scene.ancestors.include?(KIFMultiplayer::ControlledPauseEntry), "CONTROLLED_NATIVE_MENU_HOOK")
  canvas = BitmapSprite.new(Graphics.width, Graphics.height)
  canvas.bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(19, 43, 61))
  canvas.bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
  canvas.bitmap.font.color = Color.new(230, 244, 248)
  canvas.bitmap.font.size = 20
  lines = ["受控在线角色 · 原生运行时验证", character["name"],
           "GOLD：#{character['wallet']['balance']}", "初始发放 / NPC 买卖 / 签到：通过",
           "旧主线金币和背包：未导入、未修改", "服务端角色版本：#{character['revision']}"]
  lines.each_with_index { |line, index| canvas.bitmap.draw_text(18, 22 + index * 42, Graphics.width - 36, 34, line) }
  8.times { Graphics.update }
  picture = Graphics.snap_to_bitmap
  picture.to_file(File.join($kif_test_directory, "controlled-assets.png"))
  picture.dispose
  canvas.dispose
  test.log("CONTROLLED_GAME_PASS character=#{character['id']} gold=#{character['wallet']['balance']}")
  success = true
rescue Exception => error
  $kif_test_log.call("CONTROLLED_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(success ? 0 : 1)
end
