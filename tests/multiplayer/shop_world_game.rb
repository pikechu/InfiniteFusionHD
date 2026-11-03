# Scripted choices drive production shop/network/renderer in actual Game runtimes.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  config = KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  role, username = config.fetch("role"), config.fetch("username")
  restoring = role.start_with?("restore")
  client = KIFMultiplayer.client
  client.transport.enable_online_network
  client.authenticate(restoring ? "login" : "register", username, "ShopFixturePassword8", restoring ? nil : "商城#{role}")
  KIFMultiplayer::OnlineMode.start(client)
  cloud, world = KIFMultiplayer::OnlineMode.cloud, KIFMultiplayer::OnlineMode.world
  shop = KIFMultiplayer::ShopClient.new(client)
  module ShopNativeChoices
    def choose(*args)
      return 0 if Thread.current[:shop_native_accept]
      super
    end
  end
  module ShopNativeDialogs
    def pbConfirmMessage(*args)
      return true if Thread.current[:shop_native_accept]
      super
    end
    def pbMessage(*args, &block)
      return 0 if Thread.current[:shop_native_accept]
      super
    end
  end
  KIFMultiplayer::UI.prepend(ShopNativeChoices)
  Object.prepend(ShopNativeDialogs)
  wait = lambda do |name, seconds = 180, &block|
    deadline = Time.now + seconds
    loop do
      Graphics.update
      Input.update
      $scene.updateSpritesets if $scene.is_a?(Scene_Map) && $scene.map_renderer
      break if block.call
      raise "timeout #{name}: world=#{world.error && world.error.message}; shop=#{KIFMultiplayer::ShopState.error && KIFMultiplayer::ShopState.error.message}" if Time.now > deadline
    end
    test.log("PASS #{role}: #{name}")
  end
  mark = lambda { |name, value| client.raw_request("POST", "/fixture/" + name, value) }
  read = lambda { |name| client.raw_request("GET", "/fixture/" + name)["value"] }
  snapshot = lambda do |name|
    bitmap = Graphics.snap_to_bitmap
    bitmap.to_file(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), name + ".png"))
    bitmap.dispose
  end
  if restoring
    data = SaveData.read_from_file(SaveData.get_full_path("File A"))
    SaveData.mark_values_as_unloaded
    Game.load(data)
    $scene.createSpritesets
    wait.call("account entitlements hydrate on fresh runtime") { KIFMultiplayer::ShopState.current? && KIFMultiplayer::ShopState.slots["clothes"] == "clothes:azure" }
    shop.refresh
    test.check(shop.state["wallet"]["balance"] == 2130, "#{role}: persisted debit across fresh device")
    test.check($Trainer.clothes == "shopazure" && $Trainer.hat == "shopazure" && $Trainer.hair == "3_shopazure", "#{role}: complete equipped outfit restored")
    test.check(shop.state["entitlements"].include?("frame:ocean") && shop.state["entitlements"].include?("title:researcher"), "#{role}: phase two entitlements recovered")
    test.check(shop.orders.length == 6, "#{role}: unique orders survive fresh login")
    snapshot.call(role)
  else
    Game.start_new
    $MapFactory.setup(1)
    $game_player.moveto(role == "host" ? 19 : 21, 20)
    $Trainer.name = "商城#{role}"
    {:@clothes => STARTING_OUTFIT, :@hat => nil, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
     :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each { |key, value| $Trainer.instance_variable_set(key, value) }
    $Trainer.party << test.pokemon(:PIKACHU, [:TACKLE])
    $scene.createSpritesets
    wait.call("fresh account shop hydrated") { KIFMultiplayer::ShopState.current? && KIFMultiplayer::ShopState.value }
    mark.call("fund-" + role, {"owner" => client.player_id})
    shop.refresh
    test.check(shop.state["wallet"]["balance"] == 2800, "#{role}: isolated server RP grant")
    shop.redeem("SHOP-FIXTURE-" + client.player_id[-16, 16])
    test.check(shop.state["wallet"]["balance"] == 3000, "#{role}: production redeem grants bound code exactly once")
    before = test.digest
    product = shop.catalog["products"].find { |item| item["id"] == "shop-clothes-azure" }
    preview = KIFMultiplayer::ShopVisual.bitmap(KIFMultiplayer::ShopVisual.preview(KIFMultiplayer::ShopState.base, product["grants"]))
    test.check(preview.width > 0 && test.digest == before, "#{role}: composed trial never modifies trainer or save")
    preview.dispose
    transport = client.transport
    transport.singleton_class.prepend(Module.new do
      def call(method, url, *args)
        value = super
        if @shop_drop_once && method == "POST" && url.end_with?("/v1/shop/orders")
          @shop_drop_once = false
          raise KIFMultiplayer::Error.new("isolated response dropped after commit", "fixture_response_lost")
        end
        value
      end
    end)
    transport.instance_variable_set(:@shop_drop_once, true)
    begin
      shop.purchase(product)
      raise "lost response unexpectedly arrived"
    rescue KIFMultiplayer::UncertainRequest
      test.check(client.profile.account["pending"], "#{role}: lost purchase response keeps journal")
      client.recover_pending
      shop.refresh
      test.check(!client.profile.account["pending"], "#{role}: original receipt recovers without second purchase")
    end
    test.check(shop.state["wallet"]["balance"] == 2700, "#{role}: production purchase debit")
    begin
      shop.purchase(product)
      raise "duplicate purchase unexpectedly accepted"
    rescue KIFMultiplayer::HTTPRejected => error
      test.check(error.code == "already_owned", "#{role}: duplicate purchase rejected")
    end
    shop.refresh
    shop.purchase(shop.catalog["products"].find { |item| item["id"] == "bundle-azure" })
    test.check(shop.state["wallet"]["balance"] == 2540, "#{role}: bundle charges only missing hat and hair")
    %w[shop-frame-ocean shop-title-researcher shop-palette-midnight].each do |id|
      shop.purchase(shop.catalog["products"].find { |item| item["id"] == id })
    end
    # 3000 - 300 - 160 - 150 - 80 - 80 = 2230.
    test.check(shop.state["wallet"]["balance"] == 2230, "#{role}: phase two decoration purchases")
    test.check(shop.history("orders")["orders"].length == 5 && shop.history("ledger")["ledger"].length == 8, "#{role}: production paged order and ledger history")
    purchase_scene = KIFMultiplayer::ShopScene.new(shop)
    purchase_scene.filter
    ui_index = purchase_scene.products.index { |item| item["id"] == "shop-hat-jade" }
    purchase_scene.select(ui_index)
    begin
      Thread.current[:shop_native_accept] = true
      purchase_scene.details
    ensure
      Thread.current[:shop_native_accept] = false
    end
    test.check(shop.state["wallet"]["balance"] == 2130 && $Trainer.hat == "shopjade", "#{role}: production detail confirmation purchases and equips through UI")
    shop.equip({"clothes" => "clothes:azure", "hat" => "hat:azure", "hair" => "hair:azure", "frame" => "frame:ocean", "title" => "title:researcher", "palette" => "palette:midnight"})
    card = client.request("GET", "/v1/cards/me")["card"]
    test.check(card["decoration"].keys.sort == %w[frame title], "#{role}: server projects verified card decoration")
    frame = KIFMultiplayer::ShopCardFrame.new(card["decoration"])
    avatar = KIFMultiplayer::CardAvatar.new(card["avatar"])
    Graphics.update
    snapshot.call("shop-card")
    avatar.dispose
    frame.dispose
    test.check($Trainer.clothes == "shopazure" && $Trainer.hat == "shopazure" && $Trainer.hair == "3_shopazure", "#{role}: production wardrobe changes visible trainer")
    shop.equip({})
    test.check($Trainer.clothes == STARTING_OUTFIT && $Trainer.hat.nil?, "#{role}: unequip restores original free appearance")
    shop.equip({"clothes" => "clothes:azure", "hat" => "hat:azure", "hair" => "hair:azure", "frame" => "frame:ocean", "title" => "title:researcher", "palette" => "palette:midnight"})
    # Draw the real shop scene and exercise the shared touch hit-test with paging.
    scene = KIFMultiplayer::ShopScene.new(shop)
    scene.filter
    viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    viewport.z = 1_000_000
    scene.instance_variable_set(:@viewport, viewport)
    scene.instance_variable_set(:@canvas, BitmapSprite.new(Graphics.width, Graphics.height, viewport))
    sprite = Sprite.new(viewport)
    sprite.zoom_x = sprite.zoom_y = 2.5
    scene.instance_variable_set(:@preview, sprite)
    scene.update
    scene.update
    snapshot.call("shop-catalog")
    scene.click(Graphics.width * 4 / 6 + 8, Graphics.height - 20)
    scene.draw
    test.check(scene.instance_variable_get(:@index) == 5, "#{role}: touch next-page routes to real shop list")
    scene.dispose
    wait.call("equipped peer received across native platforms") do
      world.players.any? { |player| player.dig("appearance", "clothes") == "shopazure" && player.dig("appearance", "hat") == "shopazure" }
    end
    layer = $scene.spriteset.instance_variable_get(:@usersprites).find { |value| value.is_a?(KIFMultiplayer::WorldSprites) }
    wait.call("remote layered shop avatar drawn") do
      layer && layer.avatars.values.any? { |entry| entry.is_a?(Array) ? entry.any? { |value| value.is_a?(KIFMultiplayer::RemoteSprite) && value.instance_variable_get(:@shop_bitmap) } : false }
    end
    snapshot.call("shop-world")
    mark.call(role + "-render", {"passed" => true, "map_key" => world.map_key, "ruby" => RUBY_VERSION})
    other = role == "host" ? "guest" : "host"
    wait.call("other platform rendered") { read.call(other + "-render") }
    if role == "host"
      $game_player.moveto(20, 20)
      $game_player.direction = 6
      wait.call("peer observed equipped walking actor") { read.call("shop-movement-seen") }
    else
      wait.call("equipped remote movement and direction synchronized") do
        world.players.any? { |player| player["x"] == 20 && player["direction"] == 6 && player.dig("appearance", "clothes") == "shopazure" }
      end
      mark.call("shop-movement-seen", {"passed" => true})
    end
    collection = KIFMultiplayer::CollectionClient.new(client)
    collection.starter
    owned_asset = collection.refresh.first
    market = lambda do |action, body|
      client.request("POST", "/v1/market/" + action, body.merge("session_id" => cloud.session_id))
    end
    if role == "host"
      listing = market.call("listings", {"asset_id" => owned_asset["id"], "price" => 200})["receipt"]["listing_id"]
      test.check(collection.refresh.first["locked"], "host: listing holds shared authority lock")
      mark.call("host-listing", {"id" => listing})
      wait.call("peer buyer committed hosted purchase") { read.call("guest-purchased") }
      test.check(collection.refresh.empty?, "host: sold asset removed from seller authority")
      shop.refresh
      test.check(shop.state["market_wallet"]["balance"] == 3200, "host: sale credited separate market wallet")
    else
      cancelled = market.call("listings", {"asset_id" => owned_asset["id"], "price" => 50})["receipt"]["listing_id"]
      market.call("cancel/" + cancelled, {})
      test.check(!collection.refresh.first["locked"], "guest: cancel releases hosted lock")
      wait.call("seller listing delivered") { read.call("host-listing") }
      listing = read.call("host-listing")["id"]
      public_rows = client.request("GET", "/v1/market/listings/page/0/low/_")["listings"]
      test.check(public_rows.any? { |row| row["id"] == listing && !row["snapshot"].key?("owner") }, "guest: paged market search projects safe listings")
      market.call("buy/" + listing, {"expected_price" => 200})
      test.check(collection.refresh.length == 2 && $Trainer.party.length == 1, "guest: market purchase changes hosted collection without minting local Pokemon")
      shop.refresh
      test.check(shop.state["market_wallet"]["balance"] == 2800, "guest: buyer debit isolated from RP")
      mark.call("guest-purchased", {"id" => listing})
    end
    # Save before a new login reads the immutable economic records.
    test.check(Game.save("File A") && cloud.flush, "#{role}: equipped preferences reach production cloud save")
  end
  KIFMultiplayer::OnlineMode.stop
  mark.call(role + "-pass", {"passed" => true, "ruby" => RUBY_VERSION})
  test.log("SHOP_GAME_PASS role=#{role}")
  passed = true
rescue Exception => error
  $kif_test_log.call("SHOP_GAME_FAIL #{error.class}: #{error.message} #{error.respond_to?(:details) && error.details.inspect}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
