# Account-bound cosmetic entitlements. Save data contains preferences only.
module KIFMultiplayer
  module ShopData
    SLOTS = %w[clothes hat hair frame title palette].freeze
    def self.local
      return @local if @local
      require "digest/sha2"
      raw = File.binread("Data/shop/catalog.json")
      value = WireJSON.parse(raw)
      raise Error, "本机商城目录版本不支持。" unless value["version"] == 1 && value["entitlements"].is_a?(Hash)
      value["assets"].each do |path, sha|
        raise Error, "商城素材路径无效。" unless path =~ /\AGraphics\/Characters\/player\/(clothes|hat|hair)\/shop[a-z]+\/[a-z0-9_]+\.png\z/
        raise Error, "商城素材缺失或已变更，请更新客户端。" unless File.file?(path) && Digest::SHA256.hexdigest(File.binread(path)) == sha
      end
      value["hash"] = Digest::SHA256.hexdigest(raw)
      @local = value
    end
    def self.equipment(value, owned = nil)
      raise Error, "装扮响应无效。" unless value.is_a?(Hash) && value["version"] == 1 && value["revision"].is_a?(Integer) && value["revision"] >= 0 && value["slots"].is_a?(Hash) && (value["slots"].keys - SLOTS).empty?
      value["slots"].each do |slot, key|
        definition = local["entitlements"][key]
        raise Error, "装扮资源或拥有权无效。" unless definition && definition["slot"] == slot && (!owned || owned.include?(key))
      end
      value
    end
    def self.state(value)
      raise Error, "商城账号响应无效。" unless value.is_a?(Hash) && value["entitlements"].is_a?(Array) && value["entitlements"].length <= 1000 && value["entitlements"].uniq.length == value["entitlements"].length
      value["entitlements"].each { |key| raise Error, "商城资源版本不兼容。" unless local["entitlements"].key?(key) }
      %w[wallet market_wallet].each do |key|
        wallet = value[key]
        raise Error, "商城余额无效。" unless wallet.is_a?(Hash) && wallet["balance"].is_a?(Integer) && wallet["balance"].between?(0, 1_000_000_000) && wallet["revision"].is_a?(Integer) && wallet["revision"] >= 0 && wallet["currency"] == (key == "wallet" ? "RP" : "MARKET")
      end
      equipment(value["equipment"], value["entitlements"])
      value
    end
    def self.appearance(value)
      raise Error, "地图装扮格式无效。" unless value.is_a?(Hash) && value["version"] == 1 && value["catalog_hash"] == local["hash"]
      %w[clothes hat hair skin_tone].each do |slot|
        resources = local["entitlements"].values.select { |item| item["slot"] == slot }.map { |item| item["resource"] }
        raise Error, "地图装扮资源无效。" unless local["base"][slot].include?(value[slot]) || resources.include?(value[slot])
      end
      %w[clothes_color hat_color hair_color].each { |key| raise Error, "外观颜色无效。" unless value[key].is_a?(Integer) && value[key].between?(0, 359) }
      value
    end
    def self.copy(value); WireJSON.parse(WireJSON.dump(value)); end
  end

  class ShopClient
    attr_reader :client, :state, :catalog
    def initialize(client = KIFMultiplayer.client, session_id = nil)
      @client, @session_id = client, session_id
    end
    def session_id
      @session_id || (OnlineMode.active? && OnlineMode.cloud.client.equal?(@client) && OnlineMode.cloud.session_id) || raise(Error, "请先进入在线模式。")
    end
    def refresh
      pending = @client.profile.account["pending"]
      @client.recover_pending if pending && pending["path"].to_s =~ /\A\/v1\/(shop|market)\//
      adopt(@client.request("GET", "/v1/shop/state"))
      catalog = @client.request("GET", "/v1/shop/catalog")["catalog"]
      raise Error, "商城目录已更新，请更新客户端。" unless catalog.is_a?(Hash) && catalog["hash"] == ShopData.local["hash"] && catalog["entitlements"] == ShopData.local["entitlements"] && catalog["products"].is_a?(Array) && catalog["products"].length <= 1000
      known = ShopData.local["products"].map { |item| [item["id"], item] }.to_h
      catalog["products"].each do |item|
        original = known[item["id"]]
        raise Error, "商城商品响应无效。" unless original && item["grants"] == original["grants"] && item["total"].is_a?(Integer) && item["total"].between?(0, 1_000_000_000)
      end
      @catalog = catalog
      self
    end
    def adopt(value)
      @state = ShopData.state(value)
      ShopState.adopt(@client, value) if defined?(ShopState)
      value
    end
    def purchase(product)
      raise Error, "请先刷新商城。" unless @catalog
      result = @client.request("POST", "/v1/shop/orders", {"session_id" => session_id, "sku" => product.fetch("id"), "quantity" => 1,
                                 "catalog_hash" => @catalog["hash"], "expected_total" => product.fetch("total")})
      refresh
      result.fetch("order")
    end
    def redeem(code)
      result = @client.request("POST", "/v1/shop/redeem", {"session_id" => session_id, "code" => code})
      refresh
      result.fetch("redemption")
    end
    def equip(slots)
      ShopData.equipment({"version" => 1, "revision" => 0, "slots" => slots}, @state && @state["entitlements"])
      response = @client.request("POST", "/v1/shop/equipment", {"session_id" => session_id, "catalog_hash" => ShopData.local["hash"], "slots" => slots})
      equipment = ShopData.equipment(response["equipment"], @state["entitlements"])
      @state["equipment"] = equipment
      if defined?($Trainer) && $Trainer
        $Trainer.instance_variable_set(:@kif_shop_preferences, {"server" => @client.server, "owner" => @client.player_id, "slots" => ShopData.copy(slots)})
      end
      ShopState.adopt(@client, @state)
      equipment
    end
    def orders; @client.request("GET", "/v1/shop/orders")["orders"]; end
    def ledger; @client.request("GET", "/v1/shop/ledger")["ledger"]; end
    def history(kind, cursor = 0)
      raise Error, "记录类型无效。" unless %w[orders ledger].include?(kind)
      @client.request("GET", "/v1/shop/#{kind}/page/#{cursor}")
    end
  end

  # Read-only hydration is asynchronous; no economic cache in the save is trusted.
  module ShopState
    class << self
      attr_reader :value, :error
      def adopt(client, value)
        return unless OnlineMode.active? && OnlineMode.cloud.client.equal?(client)
        @owner, @server, @value = client.player_id, client.server, ShopData.state(value)
        apply
      end
      def current?
        OnlineMode.active? && @owner == OnlineMode.cloud.client.player_id && @server == OnlineMode.cloud.client.server
      end
      def slots; current? && @value ? @value["equipment"]["slots"] : {}; end
      def base(trainer = $Trainer)
        stored = trainer.instance_variable_get(:@kif_shop_base)
        result = stored.is_a?(Hash) ? ShopData.copy(stored) : {}
        %w[clothes hat hair skin_tone clothes_color hat_color hair_color].each do |key|
          actual = trainer.public_send(key)
          is_shop = actual.is_a?(String) && actual.include?("shop")
          result[key] = actual unless is_shop || (!slots.empty? && %w[clothes_color hat_color hair_color].include?(key) && slots.key?(key.sub("_color", "")))
        end
        catalog = ShopData.local
        %w[clothes hat hair skin_tone].each { |slot| result[slot] = catalog["base"][slot].first unless catalog["base"][slot].include?(result[slot]) }
        %w[clothes_color hat_color hair_color].each { |key| result[key] = result[key].to_i % 360 }
        result
      end
      def apply
        return unless current? && @value && defined?($Trainer) && $Trainer && $Trainer.name != "Unnamed"
        baseline = base
        $Trainer.instance_variable_set(:@kif_shop_base, ShopData.copy(baseline))
        desired = ShopData.copy(baseline)
        slots.each do |slot, key|
          definition = ShopData.local["entitlements"][key]
          next unless %w[clothes hat hair].include?(slot)
          desired[slot], desired[slot + "_color"] = definition["resource"], 0
        end
        changed = false
        desired.each do |key, val|
          next if $Trainer.public_send(key) == val
          $Trainer.public_send(key + "=", val)
          changed = true
        end
        refreshPlayerOutfit if changed && defined?($game_player) && $game_player && $scene.respond_to?(:spritesetGlobal)
      end
      def tick
        return unless OnlineMode.active? && defined?($Trainer) && $Trainer && $Trainer.name != "Unnamed"
        client = OnlineMode.cloud.client
        trainer_changed = !@trainer.equal?($Trainer) || !current?
        if @worker
          @worker.poll if @worker.respond_to?(:poll)
          return if @worker.alive?
          worker, @worker = @worker, nil
          KIFMultiplayer.unregister_worker(worker)
          response = worker.value
          raise response if response.is_a?(Exception)
          ShopData.state(response)
          @trainer = $Trainer
          adopt(client, response)
          preference = $Trainer.instance_variable_get(:@kif_shop_preferences)
          if @restore_preference && preference.is_a?(Hash) && preference["server"] == client.server && preference["owner"] == client.player_id
            owned = response["entitlements"]
            desired = preference["slots"].select { |_slot, key| owned.include?(key) }
            if desired != slots
              shop = ShopClient.new(client)
              shop.instance_variable_set(:@state, response)
              shop.equip(desired)
            end
          end
          @restore_preference = false
          @error = nil
          return
        end
        return unless trainer_changed || KIFMultiplayer.monotonic >= (@next_read || 0)
        @restore_preference = trainer_changed
        @next_read = KIFMultiplayer.monotonic + 30
        transport, token, url = client.transport, client.token, client.server + "/v1/shop/state"
        @worker = KIFMultiplayer.network_worker do
          begin
            raw = transport.call("GET", url, nil, token, 5.0)
            parsed = WireJSON.parse((raw[:body] || raw["body"]).to_s)
            raise Error, "商城账号状态暂时不可用。" unless (raw[:status] || raw["status"]).to_i == 200 && parsed["ok"] == true
            parsed
          rescue StandardError => error
            error
          end
        end
        KIFMultiplayer.register_worker(@worker)
      rescue StandardError => error
        @error = error
        @next_read = KIFMultiplayer.monotonic + 5
      end
      def reset
        if @worker
          @worker.cancel if @worker.respond_to?(:cancel)
          KIFMultiplayer.unregister_worker(@worker)
        end
        @worker, @value, @owner, @server, @trainer = nil, nil, nil, nil, nil
      end
    end
  end

  module ShopOnlineTick
    def tick
      result = super
      return result if @shop_ticking
      @shop_ticking = true
      begin
        ShopState.tick
      ensure
        @shop_ticking = false
      end
      result
    end
    def stop
      super
    ensure
      ShopState.reset
    end
  end
  OnlineMode.singleton_class.prepend(ShopOnlineTick)
end
