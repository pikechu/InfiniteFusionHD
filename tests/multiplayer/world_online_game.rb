# Actual independent Game.exe processes, production startup hooks, HTTP and map
# sprites. UI choices are scripted; human touch/keyboard acceptance is separate.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  config = KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  role = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("restore") ? "restore" : (ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host") ? "host" : "guest")
  username = "native_#{config['run_id']}_#{role == 'restore' ? 'host' : role}"
  $online_fixture_username = username
  $online_fixture_restore = role == "restore"
  module OnlineStartupFixture
    def choose(title, choices)
      return 0 if title == "选择游戏模式"
      return $online_fixture_restore ? 0 : 1 if title.start_with?("在线模式\n")
      super
    end
    def enter(title, *args)
      return $online_fixture_username if title.start_with?("账号")
      return $online_fixture_username.end_with?("host") ? "在线主机" : "在线客机" if title == "昵称"
      super
    end
  end
  module OnlinePasswordFixture
    def pbMessageFreeText(message, *args)
      return "NativeFixturePassword8" if message.include?("密码")
      super
    end
  end
  KIFMultiplayer::UI.prepend(OnlineStartupFixture)
  Object.prepend(OnlinePasswordFixture)
  offline_path = SaveData.get_full_path("File A")
  screen = PokemonLoadScreen.new(PokemonLoad_Scene.new)
  cloud = KIFMultiplayer::OnlineMode.cloud
  world = KIFMultiplayer::OnlineMode.world
  test.check(KIFMultiplayer::OnlineMode.active? && cloud.client.profile.account["username"] == username, "startup online choice authenticates before load screen or character creation")
  test.check(SaveData.get_full_path("File A") != offline_path, "online save path is separate from offline save")
  directory = config["directory"]
  wait = lambda do |name, seconds = 35, &block|
    deadline = Time.now + seconds
    loop do
      Graphics.update
      Input.update
      $scene.updateSpritesets if $scene.is_a?(Scene_Map) && $scene.map_renderer
      break if block.call
      raise "timeout #{name}: world=#{world.error && world.error.message} cloud=#{cloud.error && cloud.error.message}" if Time.now > deadline
    end
    test.log("PASS #{name}")
  end
  marker = lambda { |name| File.join(directory, name + ".json") }
  if role == "restore"
    slot = SaveData.get_newest_save_slot
    test.check(slot == "File A", "fresh device discovers remote character")
    data = SaveData.read_from_file(SaveData.get_full_path(slot))
    SaveData.mark_values_as_unloaded
    Game.load(data)
    test.check($Trainer.name == "在线主机" && $Trainer.party[0].name == "云端伙伴", "fresh device restores remote trainer and Pokemon")
    test.check($game_switches[42] && $game_variables[43] == 4099, "fresh device restores remote story progress")
    test.check($PokemonBag.pbQuantity(:POTION) == 7, "fresh device restores remote inventory")
    $scene.createSpritesets
    10.times { Graphics.update; $scene.updateSpritesets }
    previous_file = SaveData.get_full_path("File A")
    previous_hash = KIFMultiplayer.file_digest(previous_file)
    $scene.disposeSpritesets
    SaveData.mark_values_as_unloaded
    Game.start_new
    $Trainer.name = "新在线角色"
    test.check(cloud.capture, "new online character can autosave")
    test.check($Trainer.save_slot == "File B", "new character autosave selects empty slot instead of overwriting existing character")
    test.check(KIFMultiplayer.file_digest(previous_file) == previous_hash, "new character keeps previous character cache unchanged")
    test.check(cloud.flush, "second online character uploads to its own slot")
    test.marker(marker.call("restore-pass"), {"passed" => true, "pid" => Process.pid})
  else
    Game.start_new
    $MapFactory.setup(1)
    $game_player.moveto(20, 20)
    $Trainer.name = role == "host" ? "在线主机" : "在线客机"
    {:@clothes => STARTING_OUTFIT, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
     :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each { |key, value| $Trainer.instance_variable_set(key, value) }
    $Trainer.party << test.pokemon(:PIKACHU, [:TACKLE, :THUNDERBOLT])
    $Trainer.party[0].name = "云端伙伴"
    $PokemonBag.pbStoreItem(:POTION, 7)
    $game_switches[42] = true
    $game_variables[43] = 4099
    $game_player.moveto([[$game_player.x + (role == "host" ? -1 : 1), 1].max, $game_map.width - 2].min, $game_player.y)
    $scene.createSpritesets
    wait.call("same-map peer visible") { world.players.length == 1 && world.map_key }
    test.check(!$game_map.events.values.any? { |event| event.is_a?(KIFMultiplayer::RemoteCharacter) }, "remote players never enter collision/event collection")
    world.send_chat("map", role + " 地图你好😀")
    world.send_chat("world", role + " 世界你好")
    wait.call("map and world messages arrive from other client") do
      other = role == "host" ? "guest" : "host"
      world.messages.any? { |m| m["text"] == other + " 地图你好😀" } && world.messages.any? { |m| m["text"] == other + " 世界你好" }
    end
    if role == "host"
      $game_player.moveto([[$game_player.x + 1, 0].max, $game_map.width - 1].min, $game_player.y)
      $game_player.direction = 6
      test.marker(marker.call("movement"), {"x" => $game_player.x, "direction" => 6})
      wait.call("guest observed host movement") { File.file?(marker.call("movement-seen")) }
    else
      wait.call("remote movement and facing synchronized") do
        state = test.read(marker.call("movement"))
        state && world.players.any? { |p| p["x"] == state["x"] && p["direction"] == 6 }
      end
      test.marker(marker.call("movement-seen"), {"passed" => true})
    end
    layer = $scene.spriteset.instance_variable_get(:@usersprites).find { |sprite| sprite.is_a?(KIFMultiplayer::WorldSprites) }
    wait.call("remote avatar rendered in real map spriteset") { layer && layer.avatars.length == 1 }
    bitmap = Graphics.snap_to_bitmap
    bitmap.to_file(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "world-map.png"))
    bitmap.dispose
    chat_viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    chat_viewport.z = 99999
    chat_canvas = BitmapSprite.new(Graphics.width, Graphics.height, chat_viewport)
    chat_canvas.bitmap.font.name = "Noto Sans SC"
    chat_canvas.bitmap.font.size = 18
    chat = KIFMultiplayer::ChatScene.new(world)
    chat.instance_variable_set(:@canvas, chat_canvas)
    chat.draw
    Graphics.update
    bitmap = Graphics.snap_to_bitmap
    bitmap.to_file(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "world-chat.png"))
    bitmap.dispose
    chat_canvas.dispose
    chat_viewport.dispose
    test.marker(marker.call(role + "-render"), {"passed" => true, "pid" => Process.pid})
    if role == "guest"
      wait.call("host rendered before transfer") { File.file?(marker.call("host-render")) }
      $scene.disposeSpritesets
      $MapFactory.setup($game_map.map_id == 2 ? 1 : 2)
      $game_player.moveto(1, 1)
      $scene.createSpritesets
      wait.call("new map isolated") { world.map_key && world.players.empty? }
      world.send_chat("map", "other_map_private")
      world.send_chat("world", "cross_map_world")
      wait.call("cross map messages submitted") { world.pending_messages == 0 }
      test.marker(marker.call("guest-transfer"), {"passed" => true})
      wait.call("host checked channel isolation") { File.file?(marker.call("host-isolation")) }
    else
      wait.call("cross-map world delivery and old avatar removal") do
        File.file?(marker.call("guest-transfer")) && world.players.empty? && world.messages.any? { |m| m["text"] == "cross_map_world" }
      end
      test.check(!world.messages.any? { |m| m["text"] == "other_map_private" }, "map chat never leaks to another map")
      test.marker(marker.call("host-isolation"), {"passed" => true})
    end
    test.check(Game.save("File A"), "manual online save creates local recovery cache")
    test.check(cloud.flush, "manual online save reaches remote server")
    # Exercise the periodic scheduler without a minute-long test delay.
    $game_variables[44] = 8080
    cloud.instance_variable_set(:@next_save, KIFMultiplayer.monotonic - 1)
    previous = $game_system.save_count
    wait.call("periodic scheduler captures save") { $game_system.save_count > previous }
    test.check(cloud.flush, "periodic save reaches remote server")
    test.marker(marker.call(role + "-pass"), {"passed" => true, "pid" => Process.pid})
  end
  KIFMultiplayer::OnlineMode.stop
  test.log("ONLINE_WORLD_NATIVE_PASS role=#{role}")
  passed = true
rescue Exception => error
  $kif_test_log.call("ONLINE_WORLD_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
