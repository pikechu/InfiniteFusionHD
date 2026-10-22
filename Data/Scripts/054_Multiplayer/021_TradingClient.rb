# Server inventory references only. The existing Client journal persists every
# economic write before sending and recovers uncertain results by request_id.
module KIFMultiplayer
  class TradingClient
    MAX_COINS = 9_999_999_999
    attr_reader :client
    def initialize(client); @client = client; end
    def check(value, message = "交易响应无效。")
      raise Error.new(message, "invalid_trading_response") unless value
    end
    def identifier(value)
      check(value.is_a?(String) && value =~ /\A[A-Za-z0-9_-]{1,80}\z/)
      value
    end
    def amount(value, minimum = 0)
      check(value.is_a?(Integer) && value.between?(minimum, MAX_COINS), "金额超出支持范围。")
      value
    end
    def wallet
      value = @client.request("GET", "/v1/wallet")["wallet"]
      check(value.is_a?(Hash) && value["owner_id"] == @client.player_id && value["currency"] == "LINK")
      %w[balance available reserved version].each { |key| amount(value[key]) }
      check(value["available"] + value["reserved"] == value["balance"])
      value
    end
    def config; @client.request("GET", "/v1/market/config")["config"]; end
    def assets
      CollectionClient.new(@client).refresh
    end
    def item_quantity(value, minimum = 0)
      check(value.is_a?(Integer) && value.between?(minimum, 999_999_999), "道具数量无效。")
      value
    end
    def inventory
      value = @client.request("GET", "/v1/inventory")["inventory"]
      validate_inventory(value)
    end
    def validate_inventory(value)
      check(value.is_a?(Hash) && value["owner_id"] == @client.player_id && value["items"].is_a?(Array) && value["items"].length <= 128)
      check(value["version"].is_a?(Integer) && value["version"] >= 0)
      if value["catalog_ids"]
        check(value["catalog_ids"].is_a?(Array) && value["catalog_ids"].length <= 128)
        value["catalog_ids"].each { |id| Snapshot.registry(:Item, id) }
      end
      value["items"].each do |item|
        check(item.is_a?(Hash) && item["item_id"].is_a?(String))
        Snapshot.registry(:Item, item["item_id"])
        %w[quantity available reserved].each { |key| item_quantity(item[key]) }
        check(item["available"] + item["reserved"] == item["quantity"] && item["item"].is_a?(Hash) && item["item"]["id"] == item["item_id"])
        check(item["item"]["name"].is_a?(String) && item["item"]["name"].length.between?(1, 100) && [true, false].include?(item["item"]["tradeable"]))
      end
      value
    end
    def validate_listing(value)
      check(value.is_a?(Hash))
      %w[id seller_id asset_id].each { |key| identifier(value[key]) }
      amount(value["price"], 1)
      amount(value["fee"])
      check(value["revision"].is_a?(Integer) && value["revision"] >= 1 && value["currency"] == "LINK")
      check(%w[active sold cancelled expired].include?(value["status"]))
      check(value["compatibility"].is_a?(Hash))
      if value["kind"] == "item"
        Snapshot.registry(:Item, value["item_id"])
        item_quantity(value["quantity"], 1)
        amount(value["unit_price"], 1)
        check(value["quantity"] * value["unit_price"] == value["price"] && value["item"].is_a?(Hash) && value["item"]["id"] == value["item_id"])
        check(value["item"]["name"].is_a?(String) && value["item"]["name"].length.between?(1, 100))
      else
        check(value["kind"].nil? || value["kind"] == "pokemon")
        Snapshot.validate(value["snapshot"])
      end
      value
    end
    def search(filters = {}, sort = "price_asc", cursor = nil)
      # Read-only POST accepts bounded Unicode filters without changing the
      # established HTTP query-string contract or occupying an economic journal.
      response = @client.raw_request("POST", "/v1/market/search", {"filters" => filters, "sort" => sort, "cursor" => cursor})
      check(response["listings"].is_a?(Array) && response["listings"].length <= 20)
      response["listings"].each { |listing| validate_listing(listing) }
      check(response["next_cursor"].nil? || response["next_cursor"].is_a?(Hash))
      response
    end
    def listing(id)
      validate_listing(@client.request("GET", "/v1/market/listings/#{identifier(id)}")["listing"])
    end
    def sell(asset_id, price)
      validate_listing(@client.request("POST", "/v1/market/listings", {"asset_id" => identifier(asset_id), "price" => amount(price, 1), "compatibility" => @client.compatibility})["listing"])
    end
    def sell_item(item_id, quantity, unit_price)
      Snapshot.registry(:Item, item_id)
      validate_listing(@client.request("POST", "/v1/market/listings", {"kind" => "item", "item_id" => item_id, "quantity" => item_quantity(quantity, 1), "unit_price" => amount(unit_price, 1), "compatibility" => @client.compatibility})["listing"])
    end
    def buy(value)
      validate_listing(value)
      check(value["status"] == "active" && value["seller_id"] != @client.player_id, "商品已结束或属于自己。")
      check(value["compatibility"] == @client.compatibility, "商品与当前游戏数据版本不一致。")
      response = @client.request("POST", "/v1/market/listings/#{value['id']}/buy", {"revision" => value["revision"], "price" => value["price"], "compatibility" => @client.compatibility})
      order = response["order"]
      check(order.is_a?(Hash) && order["listing_id"] == value["id"] && order["asset_id"] == value["asset_id"] && order["buyer_id"] == @client.player_id && order["price"] == value["price"])
      identifier(order["id"])
      response
    end
    def cancel_listing(id)
      validate_listing(@client.request("POST", "/v1/market/listings/#{identifier(id)}/cancel")["listing"])
    end
    def my_listings
      values = @client.request("GET", "/v1/market/my-listings")["listings"]
      check(values.is_a?(Array) && values.length <= 100)
      values.each { |value| validate_listing(value); check(value["seller_id"] == @client.player_id) }
      values
    end
    def deliveries
      values = @client.request("GET", "/v1/deliveries")["deliveries"]
      check(values.is_a?(Array) && values.length <= 200)
      values.each do |value|
        check(value.is_a?(Hash) && value["owner_id"] == @client.player_id && %w[pending claimed].include?(value["status"]))
        %w[id asset_id event_id].each { |key| identifier(value[key]) }
        if value["kind"] == "item"
          Snapshot.registry(:Item, value["item_id"])
          item_quantity(value["quantity"], 1)
        elsif value["status"] == "pending"
          CollectionClient.new(@client).validate_asset(value["asset"])
        end
      end
      values
    end
    def claim(id)
      value = @client.request("POST", "/v1/deliveries/#{identifier(id)}/claim")["delivery"]
      check(value.is_a?(Hash) && value["id"] == id && value["owner_id"] == @client.player_id && value["status"] == "claimed")
      value
    end
    def history; @client.request("GET", "/v1/trading/history")["events"]; end
    def preferences(body = nil)
      value = @client.request(body ? "POST" : "GET", "/v1/trading/preferences", body)["preferences"]
      check(value.is_a?(Hash) && [true, false].include?(value["allow_nearby"]) && [true, false].include?(value["allow_friend"]))
      check(value["blocked"].is_a?(Array) && value["blocked"].length <= 100)
      value["blocked"].each do |trainer|
        check(trainer.is_a?(Hash) && trainer["friend_code"].is_a?(String) && trainer["friend_code"] =~ /\A[A-F0-9]{8}\z/ && trainer["nickname"].is_a?(String))
      end
      value
    end
    def validate_exchange(value)
      check(value.is_a?(Hash))
      identifier(value["id"])
      check(value["members"].is_a?(Array) && value["members"].length == 2 && value["members"].uniq.length == 2 && value["members"].include?(@client.player_id))
      check(value["offers"].is_a?(Hash) && value["offers"].keys.sort == value["members"].sort)
      value["offers"].each_value do |offer|
        check(offer.is_a?(Hash) && offer["assets"].is_a?(Array) && offer["assets"].length <= 6)
        amount(offer["amount"])
        offer["assets"].each { |asset| identifier(asset["id"]); Snapshot.validate(asset["snapshot"]) }
        check(offer["assets"].map { |asset| asset["id"] }.uniq.length == offer["assets"].length)
        validate_offer_items(offer["items"] || {})
      end
      check(%w[invited offering locked committed cancelled expired].include?(value["status"]))
      check(value["revision"].is_a?(Integer) && value["revision"] > 0)
      value
    end
    def exchanges
      values = @client.request("GET", "/v1/exchanges")["exchanges"]
      check(values.is_a?(Array) && values.length <= 100)
      values.each { |value| validate_exchange(value) }
      values
    end
    def exchange(id)
      validate_exchange(@client.request("GET", "/v1/exchanges/#{identifier(id)}")["exchange"])
    end
    def invite(friend_code)
      check(friend_code.is_a?(String) && friend_code =~ /\A[A-Fa-f0-9]{8}\z/, "好友码应为八位字母数字。")
      validate_exchange(@client.request("POST", "/v1/exchanges", {"friend_code" => friend_code.upcase, "compatibility" => @client.compatibility})["exchange"])
    end
    def invite_nearby(target_id)
      validate_exchange(@client.request("POST", "/v1/exchanges", {"target_id" => identifier(target_id), "compatibility" => @client.compatibility})["exchange"])
    end
    def validate_offer_items(items)
      check(items.is_a?(Hash) && items.length <= 8, "每次最多交易八种道具。")
      items.each { |item_id, quantity| Snapshot.registry(:Item, item_id); item_quantity(quantity, 1) }
      items
    end
    def exchange_action(value, action, body = {})
      validate_exchange(value)
      check(%w[accept offer lock confirm cancel].include?(action))
      body = WireJSON.parse(WireJSON.dump(body))
      body["compatibility"] = @client.compatibility if action == "accept"
      if %w[lock confirm].include?(action)
        expected = TradeCodec.digest({"revision" => value["revision"], "offers" => value["offers"], "compatibility" => value["compatibility"]})
        check(value["offer_hash"] == expected, "交易清单校验不一致，请刷新。")
        check(value["compatibility"] == @client.compatibility, "交易数据版本不一致。")
        body.merge!("revision" => value["revision"], "offer_hash" => expected)
      end
      validate_exchange(@client.request("POST", "/v1/exchanges/#{value['id']}/#{action}", body)["exchange"])
    end
    def offer(value, asset_ids, coins, items = {})
      check(asset_ids.is_a?(Array) && asset_ids.length <= 6 && asset_ids.uniq.length == asset_ids.length)
      asset_ids.each { |id| identifier(id) }
      exchange_action(value, "offer", {"revision" => value["revision"], "asset_ids" => asset_ids, "amount" => amount(coins), "items" => validate_offer_items(items)})
    end
    def recover
      @client.recover_pending
      {"wallet" => wallet, "deliveries" => deliveries, "exchanges" => exchanges, "inventory" => inventory}
    end
  end
end
