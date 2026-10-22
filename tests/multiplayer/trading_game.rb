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
  test.check(test.digest == original_world, "managed trading leaves main player bag system and story unchanged")
  test.log("TRADING_NATIVE_PASS role=#{role}")
  passed = true
rescue Exception => error
  $kif_test_log.call("TRADING_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
