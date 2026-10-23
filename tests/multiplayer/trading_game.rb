# Real Game.exe, game registries, production HTTP clients and durable profile
# journal. Guest exits after purchase commit but before receiving its response.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  config = KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  directory = config.fetch("directory")
  role = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host") ? "host" : "guest"
  path = lambda { |name| File.join(directory, name + ".json") }
  marker = lambda { |name, value = {"passed" => true}| test.marker(path.call(name), value) }
  read = lambda { |name| test.read(path.call(name)) }
  client = KIFMultiplayer::Client.new
  if config['cross_device']
    marker=lambda { |name,value={'passed'=>true}| client.raw_request('POST','/fixture/'+name,value) }
    read=lambda { |name| client.raw_request('GET','/fixture/'+name)['value'] }
    {:@clothes=>STARTING_OUTFIT,:@hair=>'3_'+DEFAULT_OUTFIT_MALE,:@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
  end
  original_world = test.digest
  if role == "guest" && read.call("guest-restart-required")
    test.check(!!client.profile.account["pending"], "fresh process finds durable uncertain purchase journal")
    client.connect("unused-existing-account")
    test.check(!client.profile.account["pending"], "fresh process resolves original purchase request without a second debit")
  else
    client.authenticate("login", "trading_" + role, "IsolatedNativeFixture123")
  end
  trading = KIFMultiplayer::TradingClient.new(client)
  trading.recover
  marker.call(role + "-identity", {"id" => client.player_id, "friend_code" => client.identity["friend_code"]})
  if role == "host"
    initial = trading.assets
    test.check(initial.length == 3 && trading.wallet["balance"] == 200000, "native host starts with three authoritative assets and audited funds")
    preview_before = test.digest
    preview_fixture = KIFMultiplayer::TradeCodec.copy(initial[0]["snapshot"])
    preview_fixture["species"] = "PIKACHU"
    preview = KIFMultiplayer::TradingPreview.bitmap(preview_fixture)
    test.check(preview.bitmap.width > 0, "standard-art preview fixture renders installed native Pokemon art")
    preview.dispose
    test.check(test.digest == preview_before, "trading preview never changes the main world's sprite cache")
    cancel_choices = 0
    cancel_ui = KIFMultiplayer::TradingUI.new(client)
    cancel_ui.define_singleton_method(:choose) do |_title, choices|
      cancel_choices += 1
      raise "Cancellation loop did not exit" if cancel_choices > 3
      choices.length  # The real UI returns the cancel sentinel, past the last row.
    end
    cancel_ui.main
    cancel_ui.market
    cancel_ui.filters_menu({})
    test.check(cancel_choices == 3, "native menu cancel sentinel exits home market and filter flows")
    listing = trading.sell(initial[0]["id"], 50000)
    test.check(listing["fee"] == 1000 && trading.wallet["balance"] == 199000, "listing reserves actual server asset and charges exact fee")
    marker.call("listing", {"id" => listing["id"], "asset_id" => initial[0]["id"]})
    test.wait(client, "restarted guest claims purchase") { read.call("guest-claimed") }
    test.check(trading.wallet["balance"] == 249000, "offline-compatible market settlement credits seller once")
    test.check(trading.assets.none? { |asset| asset["id"] == initial[0]["id"] }, "sold asset is absent from seller ownership")
    returned = trading.sell(initial[1]["id"], 1000)
    cancelled = trading.cancel_listing(returned["id"])
    test.check(cancelled["status"] == "cancelled", "native seller cancels unsold listing")
    trading.claim(cancelled["delivery_id"])
    trading.claim(cancelled["delivery_id"])
    test.check(trading.assets.count { |asset| asset["id"] == initial[1]["id"] } == 1, "repeated return claim retains one existing asset")
    peer = test.wait(client, "guest identity") { read.call("guest-identity") }
    session = trading.invite(peer["friend_code"])
    marker.call("exchange", {"id" => session["id"]})
    test.wait(client, "guest accepts") { trading.exchange(session["id"])["status"] == "offering" }
    session = trading.exchange(session["id"])
    session = trading.offer(session, [initial[2]["id"]], 20000)
    test.check(trading.wallet["reserved"] == 20000, "native direct exchange reserves wallet funds")
    marker.call("host-offered")
    test.wait(client, "guest offer") { read.call("guest-offered") }
    session = trading.exchange(session["id"])
    session = trading.exchange_action(session, "lock")
    marker.call("host-locked")
    test.wait(client, "both locks and server review timer") do
      current = trading.exchange(session["id"])
      current["status"] == "locked" && current["server_time"] >= current["confirm_after"]
    end
    session = trading.exchange_action(trading.exchange(session["id"]), "confirm")
    marker.call("host-confirmed")
    test.wait(client, "guest commits") { read.call("guest-committed") }
    session = trading.exchange(session["id"])
    test.check(session["status"] == "committed" && trading.wallet["balance"] == 233900 && trading.wallet["reserved"] == 0, "native direct settlement applies net money and clears reserves")
    test.check(trading.assets.length == 2, "native host final inventory count preserves unique assets")
    marker.call("host-pass", {"pid" => Process.pid, "wallet" => trading.wallet, "transaction_id" => session["transaction_id"]})
  else
    listing_marker = test.wait(client, "host listing") { read.call("listing") }
    if !read.call("guest-restart-required")
      page = trading.search({"min_price" => 50000, "max_price" => 50000})
      test.check(page["listings"].any? { |listing| listing["id"] == listing_marker["id"] }, "real HTTP market search finds native listing")
      listing = trading.listing(listing_marker["id"])
      transport = client.transport
      original_call = transport.method(:call)
      transport.define_singleton_method(:call) do |method, url, body, token, timeout|
        response = original_call.call(method, url, body, token, timeout)
        if url.end_with?("/buy") && (response[:status] || response["status"]).to_i == 200
          raise IOError, "Diagnostic response loss after real purchase commit"
        end
        response
      end
      begin
        trading.buy(listing)
        raise "Expected uncertain purchase response"
      rescue KIFMultiplayer::Error => error
        test.check(!!client.profile.account["pending"], "uncertain native purchase retains durable request ID")
        marker.call("guest-restart-required", {"pid" => Process.pid, "request_id" => client.profile.account["pending"]["body"]["request_id"]})
        test.log("TRADING_NATIVE_RESTART_REQUIRED #{error.message}")
        exit!(23)
      end
    end
    test.check(trading.wallet["balance"] == 150000, "restart recovery debits purchase exactly once")
    pending = trading.deliveries.find { |value| value["status"] == "pending" && value["asset_id"] == listing_marker["asset_id"] }
    test.check(!!pending, "fresh process recovers server pending delivery")
    trading.claim(pending["id"])
    trading.claim(pending["id"])
    test.check(trading.assets.count { |asset| asset["id"] == listing_marker["asset_id"] } == 1, "native duplicate claim never duplicates asset")
    marker.call("guest-claimed")
    invitation = test.wait(client, "host exchange invitation") { read.call("exchange") }
    session = trading.exchange(invitation["id"])
    session = trading.exchange_action(session, "accept")
    test.wait(client, "host offer") { read.call("host-offered") }
    session = trading.exchange(invitation["id"])
    own_asset = trading.assets.find { |asset| !asset["locked"] && asset["id"] != listing_marker["asset_id"] }
    session = trading.offer(session, [own_asset["id"]], 5000)
    marker.call("guest-offered")
    test.wait(client, "host lock") { read.call("host-locked") }
    session = trading.exchange_action(trading.exchange(session["id"]), "lock")
    test.wait(client, "host final confirmation") { read.call("host-confirmed") }
    session = trading.exchange_action(trading.exchange(session["id"]), "confirm")
    test.check(session["status"] == "committed" && trading.wallet["balance"] == 165000, "native guest confirms same offer hash and receives net settlement")
    test.check(trading.assets.length == 4, "native guest inventory count preserves all received assets")
    marker.call("guest-committed")
    marker.call("guest-pass", {"pid" => Process.pid, "wallet" => trading.wallet, "transaction_id" => session["transaction_id"]})
  end
  # Phase 2: actual world presence, trade cards, item delivery and nearby mixed
  # barter. WorldSession is real; no synthetic presence or item inventory.
  marker.call(role + "-pokemon-done")
  peer_role = role == "host" ? "guest" : "host"
  test.wait(client, "peer Pokemon flow finished") { read.call(peer_role + "-pokemon-done") }
  old_chatting = KIFMultiplayer::OnlineMode.chatting
  KIFMultiplayer::OnlineMode.chatting = true
  world = KIFMultiplayer::WorldSession.new(client, client.compatibility)
  if config['cross_device']
    test.check(test.digest==original_world,'Pokemon trading preserves the original world before renderer initialization')
    previous_world=KIFMultiplayer::OnlineMode.world
    KIFMultiplayer::OnlineMode.world=world
    previous_map_scene=$scene
    $game_player.refresh
    $scene=Scene_Map.new;$scene.createSpritesets
  end
  client.wait_update = proc { world.tick }
  test.wait(client, "real map presence") { world.tick; world.map_key && !world.players.empty? }
  if config['cross_device']
    8.times { Graphics.update;Input.update;$scene.updateSpritesets }
    layer=$scene.spriteset.instance_variable_get(:@usersprites).find { |sprite| sprite.is_a?(KIFMultiplayer::WorldSprites) }
    test.check(layer && layer.avatars.length==1,'native cross-device avatar rendered from real map presence')
    bitmap=Graphics.snap_to_bitmap;bitmap.to_file(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'trading-world.png'));bitmap.dispose
    marker.call(role+'-render',{'map_key'=>world.map_key,'ruby'=>RUBY_VERSION})
    # Scene_Map initialization updates its map trail/day-night metadata. Capture
    # the invariant after that deliberate setup; subsequent checks do not tick
    # story/time events while the production trading SDK performs transactions.
    original_world=test.digest
  end
  item_quantity = lambda do |id|
    entry = trading.inventory["items"].find { |value| value["item_id"] == id }
    entry ? entry["quantity"] : 0
  end
  if role == "host"
    item_listing = trading.sell_item("POTION", 3, 600)
    test.check(item_listing["price"] == 1800 && item_listing["quantity"] == 3, "native item listing distinguishes unit price quantity and total")
    world.send_chat("trade", "联机道具测试出售", item_listing["id"])
    marker.call("item-listing", {"id" => item_listing["id"]})
    test.wait(client, "guest item claim") { read.call("guest-item-claimed") }
    test.check(item_quantity.call("POTION") == 7 && trading.wallet["balance"] == 235600, "native item sale debits server stock and credits money once")
    peer = read.call("guest-identity")
    session = trading.invite_nearby(peer["id"])
    marker.call("nearby-item-exchange", {"id" => session["id"]})
    test.wait(client, "nearby invitation accepted") { trading.exchange(session["id"])["status"] == "offering" }
    session = trading.offer(trading.exchange(session["id"]), [], 1000, {"POTION" => 2, "RARECANDY" => 1})
    marker.call("host-items-offered")
    test.wait(client, "guest item offer") { read.call("guest-items-offered") }
    trading.exchange_action(trading.exchange(session["id"]), "lock")
    marker.call("host-items-locked")
    test.wait(client, "item review timer") do
      current = trading.exchange(session["id"])
      current["status"] == "locked" && current["server_time"] >= current["confirm_after"]
    end
    trading.exchange_action(trading.exchange(session["id"]), "confirm")
    marker.call("host-items-confirmed")
    test.wait(client, "mixed item commit") { read.call("guest-items-committed") }
    session = trading.exchange(session["id"])
    test.check(session["status"] == "committed" && item_quantity.call("POTION") == 6 && item_quantity.call("RARECANDY") == 4, "native nearby barter conserves both item types")
    test.check(trading.wallet["balance"] == 234600, "native mixed item payment settles once")
    marker.call("host-pass", {"pid" => Process.pid, "wallet" => trading.wallet, "transaction_id" => session["transaction_id"]})
  else
    item_marker = test.wait(client, "item listing") { read.call("item-listing") }
    test.wait(client, "real trade-channel item card") { world.visible_messages("trade").any? { |m| m["listing"] && m["listing"]["id"] == item_marker["id"] } }
    listing = trading.search({"category" => "item", "item_id" => "POTION"})["listings"].find { |value| value["id"] == item_marker["id"] }
    test.check(listing && listing["unit_price"] == 600, "native item search and world card point to same active listing")
    purchased = trading.buy(trading.listing(listing["id"]))
    trading.claim(purchased["delivery"]["id"])
    trading.claim(purchased["delivery"]["id"])
    test.check(item_quantity.call("POTION") == 23 && trading.wallet["balance"] == 163200, "native item purchase and repeated claim preserve exact quantity")
    marker.call("guest-item-claimed")
    invitation = test.wait(client, "nearby trade") { read.call("nearby-item-exchange") }
    test.wait(client, "map invitation notification") { world.trade_invites.any? { |value| value["id"] == invitation["id"] } }
    test.check(true, "native world polling receives only current trainer's invitation notification")
    session = trading.exchange_action(trading.exchange(invitation["id"]), "accept")
    test.wait(client, "host item offer") { read.call("host-items-offered") }
    session = trading.offer(trading.exchange(session["id"]), [], 0, {"POTION" => 1})
    marker.call("guest-items-offered")
    test.wait(client, "host item lock") { read.call("host-items-locked") }
    trading.exchange_action(trading.exchange(session["id"]), "lock")
    test.wait(client, "host item confirmation") { read.call("host-items-confirmed") }
    session = trading.exchange_action(trading.exchange(session["id"]), "confirm")
    test.check(item_quantity.call("POTION") == 24 && item_quantity.call("RARECANDY") == 6 && trading.wallet["balance"] == 164200, "native mixed barter transfers items and money atomically")
    marker.call("guest-items-committed")
    marker.call("guest-pass", {"pid" => Process.pid, "wallet" => trading.wallet, "transaction_id" => session["transaction_id"]})
  end
  client.wait_update = nil
  world.close
  KIFMultiplayer::OnlineMode.chatting = old_chatting
  if config['cross_device']
    $scene.disposeSpritesets
    $scene=previous_map_scene
    KIFMultiplayer::OnlineMode.world=previous_world
  end
  test.check(test.digest == original_world, "managed trading leaves main player bag system and story unchanged")
  marker.call(role+'-complete',{'pid'=>Process.pid,'wallet'=>trading.wallet,'data_hash'=>client.compatibility['data_hash'],'ruby'=>RUBY_VERSION}) if config['cross_device']
  test.log("TRADING_NATIVE_PASS role=#{role}")
  passed = true
rescue Exception => error
  $kif_test_log.call("TRADING_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  world.close if defined?(world) && world
  KIFMultiplayer::OnlineMode.chatting = old_chatting if defined?(old_chatting)
  exit!(passed ? 0 : 1)
end
