# Full production game classes, network and renderer on Windows and Android.
# Only UI choices are scripted. Coordination is a separate loopback test route.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  module MixedSocketDiagnostics
    def call(*args, **kwargs)
      super
    rescue StandardError => error
      KIFMultiplayerFeatureTest.log("TRANSPORT #{error.class}: #{error.message} code=#{error.respond_to?(:code) && error.code}")
      raise
    end
  end
  KIFMultiplayer::SocketHTTP.prepend(MixedSocketDiagnostics)
  config = KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  role = config.fetch("role")
  $mixed_username = config.fetch("username")
  $mixed_restore = role.start_with?("restore")
  module MixedStartupChoices
    def choose(title, choices)
      return 0 if title == "选择游戏模式"
      return $mixed_restore ? 0 : 1 if title.start_with?("在线模式\n")
      super
    end
    def enter(title, *args)
      return $mixed_username if title.start_with?("账号")
      return $mixed_username.end_with?("host") ? "Windows玩家" : "Android玩家" if title == "昵称"
      super
    end
  end
  module MixedPasswords
    def pbMessageFreeText(message, *args)
      return "MixedFixturePassword8" if message.include?("密码")
      super
    end
  end
  KIFMultiplayer::UI.prepend(MixedStartupChoices)
  Object.prepend(MixedPasswords)
  offline_path = SaveData.get_full_path("File A")
  PokemonLoadScreen.new(PokemonLoad_Scene.new)
  cloud = KIFMultiplayer::OnlineMode.cloud
  world = KIFMultiplayer::OnlineMode.world
  test.check(KIFMultiplayer::OnlineMode.active? && cloud.client.profile.account["username"] == $mixed_username,
             "#{role}: production mode selection and registration/login before character flow")
  test.check(offline_path != SaveData.get_full_path("File A"), "#{role}: offline saves isolated")
  wait = lambda do |name, seconds = 100, &block|
    deadline = Time.now + seconds
    loop do
      Graphics.update
      Input.update
      $scene.updateSpritesets if $scene.is_a?(Scene_Map) && $scene.map_renderer
      break if block.call
      raise "timeout #{name}: world=#{world.error && world.error.message} cloud=#{cloud.error && cloud.error.message}" if Time.now > deadline
    end
    test.log("PASS #{role}: #{name}")
  end
  mark = lambda { |name, value| cloud.client.raw_request("POST", "/fixture/" + name, value) }
  read = lambda { |name| cloud.client.raw_request("GET", "/fixture/" + name)["value"] }
  snapshot = lambda do |name|
    bitmap = Graphics.snap_to_bitmap
    bitmap.to_file(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), name + ".png"))
    bitmap.dispose
  end
  if $mixed_restore
    test.check(SaveData.get_newest_save_slot == "File A", "#{role}: empty client cache discovers cloud character")
    data = SaveData.read_from_file(SaveData.get_full_path("File A"))
    SaveData.mark_values_as_unloaded
    Game.load(data)
    test.check($Trainer.name == ($mixed_username.end_with?("host") ? "Windows玩家" : "Android玩家"), "#{role}: trainer restored")
    test.check($Trainer.party[0].name == (role == "restore-roundtrip" ? "安卓接力" : "云端伙伴"), "#{role}: Pokemon restored")
    test.check($game_switches[42] && $game_variables[43] == 4099 && $game_variables[44] == 8080, "#{role}: story and periodic save restored")
    test.check($PokemonBag.pbQuantity(:POTION) == 7, "#{role}: inventory restored")
    $scene.createSpritesets
    8.times { Graphics.update; Input.update; $scene.updateSpritesets }
    snapshot.call(role)
    if role == "restore-windows"
      $Trainer.party[0].name = "安卓接力"
      $game_variables[45] = 9090
      test.check(Game.save("File A") && cloud.flush, "Android continues Windows character and uploads remote revision")
    elsif role == "restore-roundtrip"
      test.check($game_variables[45] == 9090, "Windows restores Android continuation of Windows save")
    end
  else
    Game.start_new
    $MapFactory.setup(1)
    $game_player.moveto(role == "host" ? 19 : 21, 20)
    $Trainer.name = role == "host" ? "Windows玩家" : "Android玩家"
    {:@clothes => STARTING_OUTFIT, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
     :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each { |key, value| $Trainer.instance_variable_set(key, value) }
    $Trainer.party << test.pokemon(:PIKACHU, [:TACKLE, :THUNDERBOLT])
    $Trainer.party[0].name = "云端伙伴"
    $PokemonBag.pbStoreItem(:POTION, 7)
    $game_switches[42] = true
    $game_variables[43] = 4099
    $scene.createSpritesets
    wait.call("same map peer received") { world.players.length == 1 && world.map_key }
    world.send_chat("map", role + " 地图你好😀")
    world.send_chat("world", role + " 世界你好")
    other = role == "host" ? "guest" : "host"
    wait.call("both chat channels deliver Unicode across platforms") do
      world.messages.any? { |m| m["text"] == other + " 地图你好😀" } && world.messages.any? { |m| m["text"] == other + " 世界你好" }
    end
    if role == "host"
      $game_player.moveto(20, 20)
      $game_player.direction = 6
      mark.call("movement", {"x" => 20, "direction" => 6})
      wait.call("Android observed Windows movement") { read.call("movement-seen") }
    else
      wait.call("Windows position and facing received by Android") { world.players.any? { |p| p["x"] == 20 && p["direction"] == 6 } }
      mark.call("movement-seen", {"passed" => true})
    end
    layer = $scene.spriteset.instance_variable_get(:@usersprites).find { |sprite| sprite.is_a?(KIFMultiplayer::WorldSprites) }
    wait.call("peer avatar rendered by real map spriteset") { layer && layer.avatars.length == 1 }
    test.check(!$game_map.events.values.any? { |event| event.is_a?(KIFMultiplayer::RemoteCharacter) }, "remote avatar does not become collision event")
    snapshot.call("world-map")
    viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    viewport.z = 99999
    canvas = BitmapSprite.new(Graphics.width, Graphics.height, viewport)
    canvas.bitmap.font.name = "Noto Sans SC"
    canvas.bitmap.font.size = 18
    chat = KIFMultiplayer::ChatScene.new(world)
    chat.instance_variable_set(:@canvas, canvas)
    chat.draw
    Graphics.update
    snapshot.call("world-chat")
    canvas.dispose
    viewport.dispose
    mark.call(role + "-render", {"passed" => true, "map_key" => world.map_key, "ruby" => RUBY_VERSION})
    if role == "guest"
      wait.call("Windows rendered") { read.call("host-render") }
      $scene.disposeSpritesets
      $MapFactory.setup(2)
      $game_player.moveto(1, 1)
      $scene.createSpritesets
      wait.call("map transfer isolates avatars") { world.map_key && world.players.empty? }
      world.send_chat("map", "other_map_private")
      world.send_chat("world", "cross_map_world")
      wait.call("cross map chat submitted") { world.pending_messages == 0 }
      mark.call("guest-transfer", {"passed" => true})
      wait.call("Windows checked channel isolation") { read.call("host-isolation") }
    else
      wait.call("world chat crosses maps and departed avatar disappears") do
        world.players.empty? && world.messages.any? { |m| m["text"] == "cross_map_world" }
      end
      test.check(!world.messages.any? { |m| m["text"] == "other_map_private" }, "map chat never leaks to Windows on another map")
      mark.call("host-isolation", {"passed" => true})
    end
    test.check(Game.save("File A") && cloud.flush, "#{role}: manual save reaches server")
    $game_variables[44] = 8080
    previous_count = $game_system.save_count
    wait.call("real 60-second scheduled save captures progress") { $game_system.save_count > previous_count }
    test.check(cloud.flush, "#{role}: periodic save reaches server")
  end
  KIFMultiplayer::OnlineMode.stop
  mark.call(role + "-pass", {"passed" => true, "ruby" => RUBY_VERSION})
  test.log("MIXED_GAME_PASS role=#{role}")
  passed = true
rescue Exception => error
  details = error.respond_to?(:details) ? error.details.inspect : ""
  $kif_test_log.call("MIXED_GAME_FAIL #{error.class}: #{error.message} #{details}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
