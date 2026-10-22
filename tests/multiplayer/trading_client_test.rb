# Protocol validation and durable request recovery, using the real Client.
previous_fixture_flag = ENV["KIF_TRADE_FIXTURES_ONLY"]
ENV["KIF_TRADE_FIXTURES_ONLY"] = "1"
load File.expand_path("trade_test.rb", __dir__)
ENV["KIF_TRADE_FIXTURES_ONLY"] = previous_fixture_flag
load "Data/Scripts/054_Multiplayer/010_Collections.rb"
load "Data/Scripts/054_Multiplayer/021_TradingClient.rb"

class TradingResponseTransport
  attr_accessor :response, :lose_purchase
  attr_reader :purchases, :searches
  def initialize
    @purchases, @searches = 0, 0
  end
  def call(method, url, body, token, timeout)
    if url.end_with?("/buy")
      @purchases += 1
      @committed = @response
      if @lose_purchase
        @lose_purchase = false
        raise IOError, "response lost after commit"
      end
    end
    @searches += 1 if url.end_with?("/market/search")
    value = if url.include?("/operations/")
      {"ok" => true, "status" => "completed", "http_status" => 200, "response" => @committed}
    else
      @response
    end
    {status: 200, body: KIFMultiplayer::WireJSON.dump(value)}
  end
end

checks = 0
assert = lambda do |condition, description|
  raise "TRADING_CLIENT_FAIL #{description}" unless condition
  checks += 1
  puts "PASS #{description}"
end
reject = lambda do |description, &block|
  begin
    block.call
  rescue KIFMultiplayer::Error
    assert.call(true, description)
  else
    raise "TRADING_CLIENT_FAIL accepted #{description}"
  end
end
profile = KIFMultiplayer::Profile.new(File.join(TRADE_TEST_DIR, "market-profile.json"))
profile.account.merge!("identity" => {"id" => "p_test_owner", "nickname" => "Test"}, "token" => "test-only-token", "connected" => true)
profile.save
transport = TradingResponseTransport.new
client = KIFMultiplayer::Client.new(profile, transport)
compatibility = {"protocol" => 2, "game_version" => "fixture", "data_hash" => "test-data", "mods_hash" => "none", "rules_version" => "friendly-singles-v1"}
client.define_singleton_method(:compatibility) { compatibility }
trading = KIFMultiplayer::TradingClient.new(client)
wallet = {"owner_id" => client.player_id, "currency" => "LINK", "balance" => 9_999_999_999, "available" => 9_999_999_989, "reserved" => 10, "version" => 1}
transport.response = {"ok" => true, "wallet" => wallet}
assert.call(trading.wallet == wallet, "wallet preserves integer balances larger than 32 bits")
transport.response = {"ok" => true, "wallet" => wallet.merge("owner_id" => "another_player")}
reject.call("wallet belonging to another account rejected") { trading.wallet }
transport.response = {"ok" => true, "wallet" => wallet.merge("available" => 9_999_999_990)}
reject.call("inconsistent available and reserved money rejected") { trading.wallet }
transport.response = {"ok" => true, "wallet" => wallet.merge("balance" => 1.0)}
reject.call("floating point money rejected") { trading.wallet }
listing = {"id" => "lst_fixture", "seller_id" => "p_other", "asset_id" => "pkm_fixture", "status" => "active", "price" => 50000, "fee" => 1000, "revision" => 1, "currency" => "LINK", "snapshot" => trade_test_snapshot(100)["pokemon"], "compatibility" => compatibility}
transport.response = {"ok" => true, "listings" => [listing], "next_cursor" => nil}
assert.call(trading.search["listings"].length == 1 && transport.searches == 1, "search uses validated read-only POST")
assert.call(profile.account["pending"].nil?, "search never creates an economic pending record")
forged = KIFMultiplayer::TradeCodec.copy(listing)
forged["snapshot"]["species"] = "UNKNOWN_MON"
transport.response = {"ok" => true, "listings" => [forged], "next_cursor" => nil}
reject.call("unknown species in marketplace response rejected") { trading.search }
transport.response = {"ok" => true, "order" => {"id" => "ord_fixture", "listing_id" => listing["id"], "asset_id" => listing["asset_id"], "buyer_id" => client.player_id, "price" => 50000}}
transport.lose_purchase = true
reject.call("lost purchase response remains uncertain") { trading.buy(listing) }
pending = KIFMultiplayer::Profile.new(profile.path).account["pending"]
assert.call(pending && pending["path"].end_with?("/buy"), "purchase request ID is durable before network mutation")
reloaded = KIFMultiplayer::Client.new(KIFMultiplayer::Profile.new(profile.path), transport)
reloaded.recover_pending
assert.call(transport.purchases == 1 && reloaded.profile.account["pending"].nil?, "new client recovers original committed response without submitting another purchase")
assert.call(reloaded.profile.account["last_recovered_operation"]["response"]["order"]["id"] == "ord_fixture", "recovered order receipt persists with journal cleanup")
GameData::Item.define_singleton_method(:exists?) { |id| %w[POTION RARECANDY].include?(id.to_s) || GameData::TradeRegistry.exists?(id) }
stock = {"owner_id" => client.player_id, "version" => 1, "items" => [{"item_id" => "POTION", "quantity" => 20, "available" => 15, "reserved" => 5, "item" => {"id" => "POTION", "name" => "伤药", "tradeable" => true}}]}
transport.response = {"ok" => true, "inventory" => stock}
assert.call(trading.inventory["items"].first["available"] == 15, "server inventory preserves available and reserved item counts")
bad_stock = KIFMultiplayer::TradeCodec.copy(stock)
bad_stock["items"][0]["available"] = 19
transport.response = {"ok" => true, "inventory" => bad_stock}
reject.call("inconsistent item reservations rejected") { trading.inventory }
item_listing = listing.merge("kind" => "item", "asset_id" => "itm_POTION", "item_id" => "POTION", "quantity" => 5, "unit_price" => 400, "price" => 2000, "item" => {"id" => "POTION", "name" => "伤药"}, "snapshot" => {})
assert.call(trading.validate_listing(item_listing)["price"] == 2000, "item listing verifies unit quantity and total")
reject.call("misleading item total rejected") { trading.validate_listing(item_listing.merge("price" => 400)) }
reject.call("negative mixed-trade item quantity rejected") { trading.validate_offer_items({"POTION" => -1}) }
load "Data/Scripts/054_Multiplayer/017_OnlineClient.rb"
load "Data/Scripts/054_Multiplayer/018_World.rb"
world = KIFMultiplayer::WorldSession.new(client, compatibility)
journal_before = KIFMultiplayer::WireJSON.dump(profile.account["pending"])
world.send_chat("trade", "出售伤药", "lst_fixture")
assert.call(world.pending_messages == 1 && KIFMultiplayer::WireJSON.dump(profile.account["pending"]) == journal_before, "trade-card chat queues without replacing an existing economic journal")
reject.call("listing cards cannot be forged into world channel") { world.send_chat("world", "bad card", "lst_fixture") }
assert.call(world.pending_messages == 1, "invalid card leaves earlier queued trade message intact")
world.remember({"id" => 1, "channel" => "trade", "map_key" => nil, "sender_id" => "p_other", "nickname" => "Other", "text" => "Potion", "listing" => {"id" => "lst_fixture", "price" => 2000, "currency" => "LINK", "kind" => "item", "label" => "伤药"}})
assert.call(world.visible_messages("trade").length == 1, "trade cards remain visible when no map is selected")
puts "TRADING_CLIENT_TEST_PASS checks=#{checks}"
