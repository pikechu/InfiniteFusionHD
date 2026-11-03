begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  success = false
  baseline = test.digest
  client = KIFMultiplayer::Client.new
  client.authenticate("register", "adv_#{Process.pid}_#{Time.now.to_i}", "AdventureNativeFixture123", "主线原生验证")
  assets = KIFMultiplayer::ControlledClient.new(client).refresh
  character = assets.create("服务器主线")
  model = KIFMultiplayer::ControlledAdventureClient.new(client, character["id"]).refresh
  model.act("starter", {"species" => "BULBASAUR"})
  monster = model.state["monsters"].first
  native = Pokemon.new(:BULBASAUR, 5, $Trainer)
  native.nature = :HARDY
  monster["iv"].each { |stat, value| native.iv[stat.to_sym] = value }
  monster["ev"].each { |stat, value| native.ev[stat.to_sym] = value }
  native.calc_stats
  test.check(native.totalhp == monster["stats"]["HP"] && native.attack == monster["stats"]["ATTACK"], "ADVENTURE_NATIVE_BASE_STATS_MATCH")
  model.act("train", {"monster_id" => monster["id"], "stat" => "ATTACK", "amount" => 1})
  test.check(model.character["wallet"]["balance"] == 980, "ADVENTURE_NATIVE_TRAINING_COST")
  model.act("start", {"kind" => "trainer", "entry" => "chapter-0"})
  settled = nil
  40.times do
    battle = model.state["battle"]
    break unless battle
    active = battle["party"][battle["active"]]
    selected = active["moves"].each_with_index.select { |move, _| move["pp"] > 0 }.max_by { |move, _| model.catalog["moves"][move["id"]]["base_damage"] }
    result = model.turn({"kind" => "move", "slot" => selected ? selected[1] : -1})
    settled = result["settled_battle"]
  end
  test.check(settled && settled["outcome"] == "win", "ADVENTURE_NATIVE_SERVER_VICTORY")
  test.check(model.state["progress"]["chapter"] == 1 && model.character["wallet"]["balance"] == 1180, "ADVENTURE_NATIVE_REWARD_AND_CHAPTER")
  ball = assets.catalog["items"].find { |item| item["id"] == "POKEBALL" }
  assets.trade(assets.character(character["id"]), "buy", ball, 1)
  model.refresh
  until_time = Time.now + 1.1
  client.pump while Time.now < until_time
  region = model.catalog["regions"].min_by { |entry| entry["min_level"] }
  model.act("start", {"kind" => "wild", "entry" => region["id"]})
  result = model.turn({"kind" => "catch", "item" => "POKEBALL"})
  test.check(result["settled_battle"]["outcome"] == "captured" && model.state["monsters"].length == 2, "ADVENTURE_NATIVE_SERVER_CAPTURE")
  test.check(model.character["inventory"].empty?, "ADVENTURE_NATIVE_CAPTURE_BALL_CONSUMED")
  assets.daily(assets.character(character["id"]))
  model.refresh
  original_ids = model.state["monsters"].map { |entry| entry["id"] }.sort
  result = model.act("fuse", {"parents" => original_ids})
  test.check(model.state["monsters"].length == 1, "ADVENTURE_NATIVE_FUSION_LOCKS_PARENTS")
  model.act("split", {"monster_id" => result["monster_id"]})
  test.check(model.state["monsters"].map { |entry| entry["id"] }.sort == original_ids, "ADVENTURE_NATIVE_SPLIT_RESTORES_IDENTITIES")
  model.act("heal")
  test.check(model.state["monsters"].all? { |entry| entry["hp"] == entry["stats"]["HP"] }, "ADVENTURE_NATIVE_HEALING")
  test.check(test.digest == baseline, "ADVENTURE_NATIVE_LEGACY_ASSETS_UNCHANGED")
  canvas = BitmapSprite.new(Graphics.width, Graphics.height)
  canvas.bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(19, 43, 61))
  canvas.bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
  canvas.bitmap.font.color = Color.new(230, 244, 248)
  canvas.bitmap.font.size = 19
  ["受控主线 · 服务器结算验证", "章节胜利 / 奖励 / 捕获：通过", "训练 / 融合 / 分离 / 恢复：通过", "精灵编号唯一，旧存档资产未改变", "规则 v1：关闭特性、携带物与天气", "当前 GOLD：#{model.character['wallet']['balance']}"] .each_with_index do |line, index|
    canvas.bitmap.draw_text(14, 16 + index * 40, Graphics.width - 28, 34, line)
  end
  8.times { Graphics.update }
  picture = Graphics.snap_to_bitmap
  picture.to_file(File.join($kif_test_directory, "controlled-adventure.png"))
  picture.dispose
  canvas.dispose
  test.log("CONTROLLED_ADVENTURE_GAME_PASS checks=10 gold=#{model.character['wallet']['balance']} rules=#{model.catalog['hash']}")
  success = true
rescue Exception => error
  $kif_test_log.call("CONTROLLED_ADVENTURE_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(success ? 0 : 1)
end
