# Server-managed collections never import Pokemon into the local party/storage.
# Asset IDs are references to server-owned records, not trusted local UUIDs.
module KIFMultiplayer
  class CollectionClient
    attr_reader :client
    def initialize(client); @client = client; end
    def identifier(value)
      raise Error, "托管资产编号无效。" unless value.is_a?(String) && value =~ /\A[A-Za-z0-9_-]{1,100}\z/
      value
    end
    def validate_asset(asset, require_owner = true)
      unless asset.is_a?(Hash) && asset["source"] == "server_catalog" && asset["catalog_version"] == 1
        raise Error, "托管资产来源或目录版本不支持。"
      end
      identifier(asset["id"])
      raise Error, "托管资产归属不匹配。" if require_owner && asset["owner_id"] != @client.player_id
      Snapshot.validate(asset["snapshot"])
      asset
    end
    def refresh
      assets = @client.request("GET", "/v1/collections")["assets"]
      raise Error, "托管收藏响应无效。" unless assets.is_a?(Array) && assets.length <= 10_000
      assets.each { |asset| validate_asset(asset) }
      # This cache is display-only. Ownership checks always go to the server;
      # no Pokemon objects or claims from this cache enter the main save.
      LocalJournal.change(@client.profile) { @client.profile.account["managed_assets_cache"] = TradeCodec.copy(assets) }
      assets
    end
    def starter
      @client.request("POST", "/v1/collections/starter", { "catalog_version" => 1 })
      refresh
    end
    def publish(asset_id)
      asset_id = identifier(asset_id)
      raise Error, "当前身份不拥有此托管资产。" unless refresh.any? { |asset| asset["id"] == asset_id }
      @client.request("POST", "/v1/collections/#{asset_id}/showcase")
    end
  end

  class ManagedTradeSession
    attr_reader :client, :collection
    def initialize(client)
      @client, @collection = client, CollectionClient.new(client)
    end
    def code; @client.profile.account["managed_trade_code"]; end
    def save_code(value)
      LocalJournal.change(@client.profile) do
        value ? @client.profile.account["managed_trade_code"] = value : @client.profile.account.delete("managed_trade_code")
      end
    end
    def safe_code(value)
      raise Error, "交换码无效。" unless value.is_a?(String) && value =~ /\A[A-Z0-9]{4,16}\z/
      value
    end
    def path(value, action = nil)
      "/v1/trades/#{safe_code(value)}" + (action ? "/#{action}" : "")
    end
    def check_source(trade)
      unless trade.is_a?(Hash) && trade["source"] == "server_managed" && (trade["members"] || {}).key?(@client.player_id)
        raise Error, "此会话不是当前身份的服务器托管交换，不能混用本地个体。"
      end
      trade
    end
    def get(value)
      check_source(@client.request("GET", path(value))["trade"])
    end
    def list
      @client.request("GET", "/v1/trades")["trades"].select { |trade| trade["source"] == "server_managed" }
    end
    def create
      @client.recover_pending
      raise Error, "请先恢复或取消已有托管好友交换。" if code
      trade = check_source(@client.request("POST", "/v1/trades", { "source" => "server_managed", "compatibility" => @client.compatibility })["trade"])
      save_code(trade["code"])
      trade
    end
    def join(value)
      @client.recover_pending
      raise Error, "请先恢复或取消已有托管好友交换。" if code && code != value
      trade = check_source(@client.request("POST", path(value, "join"), { "compatibility" => @client.compatibility, "source" => "server_managed" })["trade"])
      save_code(trade["code"])
      trade
    end
    def offer(value, asset_id)
      asset_id = @collection.identifier(asset_id)
      raise Error, "当前身份不拥有此托管资产。" unless @collection.refresh.any? { |asset| asset["id"] == asset_id }
      trade = check_source(@client.request("POST", path(value, "offer"), { "asset_id" => asset_id, "offer_id" => KIFMultiplayer.operation_id })["trade"])
      save_code(trade["code"])
      trade
    end
    def confirm(trade)
      check_source(trade)
      offers = trade["offers"] || {}
      raise Error, "双方需要先选择托管资产。" unless offers.length == 2 && offers.key?(@client.player_id)
      offers.each_value do |offer|
        @collection.identifier(offer["asset_id"])
        Snapshot.validate(offer["snapshot"])
      end
      hashes = offers.each_with_object({}) { |(owner, offer), result| result[owner] = offer["hash"] }
      result = check_source(@client.request("POST", path(trade["code"], "confirm"), { "revision" => trade["revision"], "offer_hashes" => hashes })["trade"])
      reconcile(result)
    end
    def cancel(value)
      @client.recover_pending
      trade = get(value)
      if %w[waiting offering].include?(trade["status"])
        begin
          trade = check_source(@client.request("POST", path(value, "cancel"))["trade"])
        rescue Error => error
          raise unless error.code == "trade_closed"
          trade = get(value)
        end
      end
      reconcile(trade)
    end
    def recover
      @client.recover_pending
      unless code
        unfinished = list.find { |trade| !%w[cancelled expired completed].include?(trade["status"]) && !(trade["acked"] || []).include?(@client.player_id) }
        save_code(unfinished["code"]) if unfinished
      end
      code ? reconcile(get(code)) : nil
    end
    def reconcile(trade)
      check_source(trade)
      if %w[cancelled expired].include?(trade["status"])
        save_code(nil) if code == trade["code"]
      elsif %w[committed completed].include?(trade["status"])
        receipt = trade["receipt"]
        offers = trade["offers"] || {}
        own = offers[@client.player_id]
        other = offers[(offers.keys - [@client.player_id]).first]
        asset = receipt && receipt["received_asset"]
        unless receipt.is_a?(Hash) && receipt["source"] == "server_managed" && receipt["owner_id"] == @client.player_id &&
               receipt["transaction_id"] == trade["transaction_id"] && offers.length == 2 && own && other &&
               receipt["offered_hash"] == own["hash"] && receipt["received_hash"] == other["hash"] &&
               asset && asset["id"] == other["asset_id"] && asset["snapshot"] == other["snapshot"]
          raise Error, "托管交换凭据与已确认的资产不一致。"
        end
        @collection.validate_asset(asset)
        # A subsequent acknowledged exchange may already have moved this asset
        # again. The current server inventory is authoritative, not this receipt.
        @collection.refresh
        @client.request("POST", path(trade["code"], "ack"), { "transaction_id" => trade["transaction_id"] })
        save_code(nil) if code == trade["code"]
      end
      trade
    end
  end

  class ManagedPoolSession
    def initialize(client)
      @client, @collection = client, CollectionClient.new(client)
    end
    def deposit_id; @client.profile.account["managed_pool_id"]; end
    def save_id(value)
      LocalJournal.change(@client.profile) do
        value ? @client.profile.account["managed_pool_id"] = value : @client.profile.account.delete("managed_pool_id")
        @client.profile.account.delete("managed_pool_draft") unless value
      end
    end
    def get(id); @client.request("GET", PoolPaths.path(id))["deposit"]; end
    def list; @client.request("GET", PoolPaths.path)["deposits"].select { |deposit| deposit["source"] == "server_managed" }; end
    def deposit(asset_id)
      @client.recover_pending
      raise Error, "请先恢复托管交换池投递。" if deposit_id
      outstanding = @client.request("GET", PoolPaths.path)["deposits"]
      raise Error, "此账号已有未完成交换池投递，请从原来源分区恢复。" if outstanding.any? { |deposit| deposit["status"] != "completed" }
      asset_id = @collection.identifier(asset_id)
      raise Error, "当前身份不拥有此资产。" unless @collection.refresh.any? { |asset| asset["id"] == asset_id }
      compatibility = @client.compatibility
      id = "pool_#{KIFMultiplayer.operation_id}"
      # Persist the chosen operation ID before sending; the server locks and
      # moves authoritative ownership without touching any local Pokemon.
      payload = { "deposit_id" => id, "source" => "server_managed", "asset_id" => asset_id,
        "offer_id" => KIFMultiplayer.operation_id, "compatibility" => compatibility, "request_id" => KIFMultiplayer.operation_id }
      LocalJournal.change(@client.profile) do
        @client.profile.account["managed_pool_draft"] = payload
        @client.profile.account["managed_pool_id"] = id
      end
      result = @client.request("POST", PoolPaths.path, payload)["deposit"]
      reconcile(result)
    end
    def recover
      @client.recover_pending
      unless deposit_id
        unfinished = list.find { |deposit| deposit["status"] != "completed" }
        save_id(unfinished["deposit_id"]) if unfinished
      end
      return nil unless deposit_id
      begin
        reconcile(get(deposit_id))
      rescue Error => error
        raise unless %w[not_found deposit_not_found pool_not_found].include?(error.code)
        draft = @client.profile.account["managed_pool_draft"]
        unless draft && draft["deposit_id"] == deposit_id && draft["source"] == "server_managed"
          raise Error, "托管投递尚未创建且本地缺少原请求，请选择撤回清除准备记录。"
        end
        reconcile(@client.request("POST", PoolPaths.path, draft)["deposit"])
      end
    end
    def withdraw
      @client.recover_pending
      raise Error, "没有待处理的托管投递。" unless deposit_id
      begin
        deposit = get(deposit_id)
      rescue Error => error
        raise unless %w[not_found deposit_not_found pool_not_found].include?(error.code)
        # The authoritative query confirms no asset was ever reserved. Nothing
        # local needs restoring, so an unsent preparation can be discarded.
        save_id(nil)
        return nil
      end
      if deposit["status"] == "waiting"
        begin
          deposit = @client.request("POST", PoolPaths.path(deposit_id, "withdraw"))["deposit"]
        rescue Error => error
          raise unless error.code == "deposit_matched"
          deposit = get(deposit_id)
        end
      end
      reconcile(deposit)
    end
    def reconcile(deposit)
      unless deposit.is_a?(Hash) && deposit["source"] == "server_managed" && deposit["owner_id"] == @client.player_id && deposit["deposit_id"] == deposit_id
        raise Error, "托管投递身份、来源或编号不一致。"
      end
      case deposit["status"]
      when "waiting"
        # Server ownership remains authoritative while the asset is locked.
      when "matched", "withdrawn", "expired", "completed"
        receipt = deposit["receipt"]
        asset = receipt && receipt["received_asset"]
        unless receipt.is_a?(Hash) && receipt["source"] == "server_managed" && receipt["owner_id"] == @client.player_id &&
               receipt["transaction_id"] == deposit["transaction_id"] && receipt["offer_id"] == deposit["offer_id"] &&
               receipt["offered_hash"] == deposit["offered_hash"] &&
               %w[return exchange].include?(receipt["kind"]) && asset
          raise Error, "托管交换池领取凭据无效。"
        end
        @collection.validate_asset(asset)
        if receipt["kind"] == "return" && asset["id"] != deposit["asset_id"]
          raise Error, "托管取回凭据更改了原资产。"
        end
        @collection.refresh
        @client.request("POST", PoolPaths.path(deposit_id, "ack"), { "transaction_id" => deposit["transaction_id"] })
        save_id(nil)
      else
        raise Error, "未知托管交换池状态。"
      end
      deposit
    end
  end

  def self.open_collection_menu(client); CollectionUI.new(client).main; end
  def self.open_managed_pool_menu(client); CollectionUI.new(client).pool_menu; end
  class CollectionUI
    def initialize(client)
      @client, @ui, @collection = client, UI.new(client), CollectionClient.new(client)
      @trades, @pool = ManagedTradeSession.new(client), ManagedPoolSession.new(client)
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def select_asset
      assets = @collection.refresh
      raise Error, "托管收藏箱为空，可先领取目录初始赠送。" if assets.empty?
      index = @ui.choose("选择服务器托管资产", assets.map { |asset| "#{text(asset['snapshot']['name'])} · #{text(asset['snapshot']['species'])} · #{text(asset['id'])}" } + ["返回"])
      index >= 0 && index < assets.length ? assets[index] : nil
    end
    def show_asset(asset)
      @collection.validate_asset(asset, false)
      @ui.show_showcase({ "code" => asset["id"], "version" => asset["catalog_version"], "snapshot" => asset["snapshot"] })
    end
    def main
      @ui.perform { @trades.recover; @pool.recover }
      loop do
        choice = @ui.choose("服务器托管收藏箱\n来源：服务器认可目录，归属由服务器记录。\n此处资产不进入主存档，不能上传本地精灵。", ["查看我的托管资产", "领取账号初始目录赠送（一次）", "发布托管资产展示", "托管好友交换", "托管奇迹交换池", "刷新缓存", "返回"])
        return if choice < 0 || choice == 6
        @ui.perform do
          case choice
          when 0
            asset = select_asset
            show_asset(asset) if asset
          when 1
            if pbConfirmMessage("领取服务器固定目录的账号初始赠送？每个账号仅一次。\n它不会生成主存档精灵。")
              pbMessage("托管收藏箱现有 #{@collection.starter.length} 个资产。重复领取不会再次生成。")
            end
          when 2
            asset = select_asset
            if asset
              result = @collection.publish(asset["id"])
              showcase = result["showcase"] || {}
              pbMessage("托管资产展示已发布：#{text(showcase['code'] || result['code'])}")
            end
          when 3 then trades_menu
          when 4 then pool_menu
          when 5 then pbMessage("服务器确认当前拥有 #{@collection.refresh.length} 个资产。")
          end
        end
      end
    end
    def trades_menu
      loop do
        choice = @ui.choose("服务器托管好友交换\n资产归属在服务器原子更新，不修改本地队伍。", ["创建托管交换", "输入交换码加入", "恢复托管交换", "返回"])
        return if choice < 0 || choice == 3
        @ui.perform do
          case choice
          when 0 then trade_menu(@trades.create)
          when 1
            value = @ui.enter("输入托管交换码", "", 16).upcase
            trade_menu(@trades.join(value)) unless value.empty?
          when 2
            trade = @trades.recover
            trade ? trade_menu(trade) : pbMessage("没有未完成托管交换。")
          end
        end
      end
    end
    def trade_menu(trade)
      loop do
        choice = @ui.choose("托管交换 #{text(trade['code'])}\n#{text(trade['status'])} · 报价版本 #{trade['revision']}", ["刷新 / 恢复确认领取", "选择报价资产", "查看双方完整报价", "确认当前报价", "取消", "返回"])
        return if choice < 0 || choice == 5
        @ui.perform do
          case choice
          when 0 then trade = @trades.reconcile(@trades.get(trade["code"]))
          when 1
            asset = select_asset
            trade = @trades.offer(trade["code"], asset["id"]) if asset
          when 2 then inspect_managed_offers(trade)
          when 3
            inspect_managed_offers(trade)
            trade = @trades.confirm(trade) if pbConfirmMessage("确认这两份托管报价？双方确认后服务器立即交换归属。")
          when 4 then trade = @trades.cancel(trade["code"]) if pbConfirmMessage("取消未提交的托管交换？已提交时会恢复领取。")
          end
        end
      end
    end
    def inspect_managed_offers(trade)
      offers = trade["offers"] || {}
      raise Error, "尚无报价。" if offers.empty?
      offers.each do |owner, offer|
        Snapshot.validate(offer["snapshot"])
        pbMessage("#{owner == @client.player_id ? '你的资产' : '对方资产'} #{text(offer['asset_id'])}\n来源：服务器目录\n#{text(WireJSON.dump(offer['snapshot']))}")
      end
    end
    def pool_menu
      @ui.perform { @pool.recover }
      loop do
        choice = @ui.choose("在线奇迹交换池 · 服务器托管区\n只匹配服务器托管资产，与本地休闲区分开。", ["选择托管资产投递", "刷新 / 恢复领取", "撤回未匹配投递", "查看投递记录", "返回"])
        return if choice < 0 || choice == 4
        @ui.perform do
          case choice
          when 0
            asset = select_asset
            if asset && pbConfirmMessage("投递托管资产 #{text(asset['id'])}？匹配后不能撤回。")
              show_managed_deposit(@pool.deposit(asset["id"]))
            end
          when 1 then show_managed_deposit(@pool.recover)
          when 2 then show_managed_deposit(@pool.withdraw) if pbConfirmMessage("请求撤回？已匹配时领取服务器确定结果。")
          when 3
            deposits = @pool.list
            pbMessage(deposits.empty? ? "没有记录。" : deposits.map { |deposit| "#{text(deposit['deposit_id'])}\n#{text(deposit['status'])}" }.join("\n"))
          end
        end
      end
    end
    def show_managed_deposit(deposit)
      pbMessage(deposit ? "托管投递 #{text(deposit['deposit_id'])}\n状态：#{text(deposit['status'])}\n归属与领取记录由服务器保存。" : "没有未完成托管投递。")
    end
  end
end

previous_collection_identity_lock = KIFMultiplayer.method(:trade_identity_locked?)
KIFMultiplayer.define_singleton_method(:trade_identity_locked?) do |profile|
  previous_collection_identity_lock.call(profile) || (profile.data["servers"] || {}).values.any? do |account|
    account.is_a?(Hash) && (account["managed_trade_code"] || account["managed_pool_id"])
  end
end
previous_collection_identity_guard = KIFMultiplayer.identity_change_guard
KIFMultiplayer.identity_change_guard = lambda do |profile|
  previous_collection_identity_guard.call(profile) if previous_collection_identity_guard
  if (profile.data["servers"] || {}).values.any? { |account| account.is_a?(Hash) && (account["managed_trade_code"] || account["managed_pool_id"]) }
    raise KIFMultiplayer::Error.new("请先恢复或取消托管资产交换，再更换服务器或身份。", "collection_identity_locked")
  end
end
