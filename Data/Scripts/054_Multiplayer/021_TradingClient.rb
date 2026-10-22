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
    def validate_listing(value)
      check(value.is_a?(Hash))
      %w[id seller_id asset_id].each { |key| identifier(value[key]) }
      amount(value["price"], 1)
      amount(value["fee"])
      check(value["revision"].is_a?(Integer) && value["revision"] >= 1 && value["currency"] == "LINK")
      check(%w[active sold cancelled expired].include?(value["status"]))
      check(value["compatibility"].is_a?(Hash))
      Snapshot.validate(value["snapshot"])
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
        CollectionClient.new(@client).validate_asset(value["asset"]) if value["status"] == "pending"
      end
      values
    end
    def claim(id)
      value = @client.request("POST", "/v1/deliveries/#{identifier(id)}/claim")["delivery"]
      check(value.is_a?(Hash) && value["id"] == id && value["owner_id"] == @client.player_id && value["status"] == "claimed")
      value
    end
    def history; @client.request("GET", "/v1/trading/history")["events"]; end
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
    def offer(value, asset_ids, coins)
      check(asset_ids.is_a?(Array) && asset_ids.length <= 6 && asset_ids.uniq.length == asset_ids.length)
      asset_ids.each { |id| identifier(id) }
      exchange_action(value, "offer", {"revision" => value["revision"], "asset_ids" => asset_ids, "amount" => amount(coins)})
    end
    def recover
      @client.recover_pending
      {"wallet" => wallet, "deliveries" => deliveries, "exchanges" => exchanges}
    end
  end
end
