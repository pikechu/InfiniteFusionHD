# Online wonder pool. Local casual deposits use the SAME durable save escrow
# and applied transaction markers as friend trades, with an independent journal.
module KIFMultiplayer
  module PoolPaths
    def self.id(value)
      raise Error, "无效交换池投递编号。" unless value.is_a?(String) && value =~ /\Apool_[0-9a-f]{32}\z/
      value
    end
    def self.path(value = nil, action = nil)
      result = "/v1/pool/deposits"
      result += "/#{id(value)}" if value
      result += "/#{action}" if action
      result
    end
  end

  class PoolSession < TradeSession
    def pending; @client.profile.account["pool_pending"]; end
    def clear_local_journal
      change_profile { @client.profile.account.delete("pool_pending") }
    end
    def get(id); @client.request("GET", PoolPaths.path(id))["deposit"]; end
    def list; @client.request("GET", PoolPaths.path)["deposits"]; end
    def own_escrow
      value = escrow
      value && value["kind"] == "pool" ? value : nil
    end
    def deposit(pokemon)
      @client.recover_pending
      raise Error, "请先恢复或取消待处理的本地交换 / 投递。" if pending || escrow || @client.profile.account["trade_pending"]
      if list.any? { |deposit| deposit["status"] != "completed" }
        raise Error, "此账号已有未完成交换池投递，请从原来源分区恢复或撤回。"
      end
      compatibility = @client.compatibility
      snapshot = TradeCodec.export(pokemon)
      TradeCodec.import(snapshot)
      location = location_of(pokemon)
      if location[0] == "party" && pokemon.hp > 0 && $Trainer.party.count { |entry| !entry.egg? && entry.hp > 0 } <= 1
        raise Error, "请至少保留一只可战斗精灵，或从电脑选择投递。"
      end
      id = "pool_#{KIFMultiplayer.operation_id}"
      offer_id, request_id = KIFMultiplayer.operation_id, KIFMultiplayer.operation_id
      save_id = $Trainer.instance_variable_get(:@kif_multiplayer_trade_save_id) || KIFMultiplayer.operation_id
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_save_id, save_id)
      record = { "kind" => "pool", "code" => id, "deposit_id" => id, "server" => @client.server,
        "player_id" => @client.player_id, "save_path" => active_path, "save_id" => save_id,
        "offer_id" => offer_id, "request_id" => request_id, "compatibility" => compatibility, "stage" => "preparing" }
      change_profile { @client.profile.account["pool_pending"] = record }
      entry = { "pokemon" => pokemon, "snapshot" => snapshot, "hash" => TradeCodec.digest(snapshot), "location" => location, "offer_id" => offer_id, "codec_version" => 2 }
      mutate_save do
        remove_at(location)
        $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, record.merge("entries" => [entry]))
      end
      change_profile { pending["stage"] = "locked" }
      submit_locked
    end
    def submit_locked
      check_binding
      value = own_escrow
      raise Error, "没有当前投递的锁定原个体，禁止从网络生成副本。" unless value && value["code"] == pending["deposit_id"] && value["entries"].length == 1
      entry = value["entries"].first
      raise Error, "锁定个体发生变化，已停止投递。" unless TradeCodec.entry_matches?(entry)
      payload = { "deposit_id" => pending["deposit_id"], "source" => "local_casual", "offer_id" => entry["offer_id"],
        "snapshot" => entry["snapshot"], "compatibility" => pending["compatibility"], "request_id" => pending["request_id"] }
      reconcile(@client.request("POST", PoolPaths.path, payload)["deposit"])
    end
    def recover
      @client.recover_pending
      if !pending && own_escrow
        change_profile { @client.profile.account["pool_pending"] = own_escrow.reject { |key, _| key == "entries" } }
      end
      if !pending && !applied.empty?
        interrupted = list.find do |deposit|
          marker = applied[deposit["transaction_id"]]
          marker && marker["kind"] == "pool" && marker["server"] == @client.server && marker["player_id"] == @client.player_id &&
            marker["code"] == deposit["deposit_id"] && deposit["status"] != "completed"
        end
        if interrupted
          change_profile { @client.profile.account["pool_pending"] = { "kind" => "pool", "code" => interrupted["deposit_id"], "deposit_id" => interrupted["deposit_id"],
            "server" => @client.server, "player_id" => @client.player_id, "save_path" => active_path,
            "save_id" => $Trainer.instance_variable_get(:@kif_multiplayer_trade_save_id), "stage" => "applied" } }
        end
      end
      return nil unless pending
      # A profile-only preparing record means the first durable save never
      # completed. Query its server ID before releasing that preparation.
      if !own_escrow && pending["stage"] == "preparing" && pending["server"] == @client.server && pending["player_id"] == @client.player_id && pending["save_path"] == active_path
        begin
          deposit = get(pending["deposit_id"])
        rescue Error => error
          raise unless %w[not_found deposit_not_found pool_not_found].include?(error.code)
          clear_local_journal
          return nil
        end
        raise Error, "服务器已有投递，但当前存档缺少原个体。请加载原存档恢复。" if deposit
      end
      check_binding
      begin
        reconcile(get(pending["deposit_id"]))
      rescue Error => error
        raise unless %w[not_found deposit_not_found pool_not_found].include?(error.code)
        # Crash after save, before POST: reuse the journal's original ID and
        # payload. Never create a second deposit because a response was absent.
        submit_locked
      end
    end
    def withdraw
      @client.recover_pending
      check_binding
      begin
        deposit = get(pending["deposit_id"])
      rescue Error => error
        raise unless %w[not_found deposit_not_found pool_not_found].include?(error.code)
        # The generic operation journal was resolved before this query. An
        # unsent/rejected preparation has never reserved anything remotely.
        id = pending["deposit_id"]
        release_all
        clear_local_journal
        return { "deposit_id" => id, "status" => "preparation_cancelled" }
      end
      if deposit["status"] == "waiting"
        begin
          deposit = @client.request("POST", PoolPaths.path(pending["deposit_id"], "withdraw"))["deposit"]
        rescue Error => error
          raise unless error.code == "deposit_matched"
          deposit = get(pending["deposit_id"])
        end
      end
      reconcile(deposit)
    end
    def reconcile(deposit)
      raise Error, "交换池响应无效。" unless deposit.is_a?(Hash)
      return deposit unless pending
      check_binding
      unless deposit["deposit_id"] == pending["deposit_id"] && deposit["owner_id"] == @client.player_id && deposit["source"] == "local_casual"
        raise Error, "投递编号、来源或身份与原存档不一致。"
      end
      case deposit["status"]
      when "waiting"
        value = own_escrow
        entry = value && value["entries"].first
        unless entry && entry["offer_id"] == deposit["offer_id"] && entry["snapshot"] == deposit["snapshot"]
          raise Error, "服务器投递与锁定原个体不一致。"
        end
      when "matched", "withdrawn", "expired", "completed"
        receive_pool(deposit)
      else
        raise Error, "未知投递状态，请更新客户端后恢复。"
      end
      deposit
    end
    def receive_pool(deposit)
      receipt = deposit["receipt"]
      unless receipt.is_a?(Hash) && receipt["source"] == "local_casual" && receipt["owner_id"] == @client.player_id &&
             %w[return exchange].include?(receipt["kind"]) && receipt["offer_id"] == deposit["offer_id"] &&
             receipt["offered_snapshot"] == deposit["snapshot"] && receipt["offered_hash"] == deposit["offered_hash"]
        raise Error, "无效交换池领取凭据，原个体仍锁定。"
      end
      transaction_id = receipt["transaction_id"]
      unless transaction_id.is_a?(String) && transaction_id =~ /\A[A-Za-z0-9_-]{1,100}\z/ && transaction_id == deposit["transaction_id"]
        raise Error, "交换池交易编号无效。"
      end
      returning = receipt["kind"] == "return"
      if returning && (receipt["received_snapshot"] != receipt["offered_snapshot"] || receipt["received_hash"] != receipt["offered_hash"])
        raise Error, "取回凭据更改了原个体，已停止领取。"
      end
      received = receipt["received_snapshot"]
      received_hash = TradeCodec.digest(received)
      raise Error, "交换池收到个体与凭据摘要不一致，已停止领取。" unless received_hash == receipt["received_hash"]
      marker = applied[transaction_id]
      if marker
        unless marker["kind"] == "pool" && marker["code"] == deposit["deposit_id"] && marker["server"] == @client.server &&
               marker["player_id"] == @client.player_id && marker["received_hash"] == received_hash && marker["offered_hash"] == receipt["offered_hash"]
          raise Error, "已应用的交换池结果发生变化，禁止重复领取。"
        end
      else
        value = own_escrow
        entry = value && value["entries"].first
        unless entry && value["entries"].length == 1 && entry["offer_id"] == receipt["offer_id"] && entry["snapshot"] == receipt["offered_snapshot"] &&
               entry["hash"] == TradeCodec.digest(receipt["offered_snapshot"])
          raise Error, "缺少匹配的锁定原个体，禁止从网络重新生成。"
        end
        unless returning
          TradeCodec.validate(received)
          raise Error, "锁定个体内容发生变化，禁止交换。" unless TradeCodec.entry_matches?(entry)
        end
        # Return the exact original object on withdrawal/expiry. Only a matched
        # exchange constructs a received individual, after full validation.
        pokemon = returning ? entry["pokemon"] : TradeCodec.import(received)
        mutate_save do
          insert(pokemon, entry["location"])
          markers = applied.dup
          markers[transaction_id] = { "kind" => "pool", "code" => deposit["deposit_id"], "server" => @client.server,
            "player_id" => @client.player_id, "received_hash" => received_hash, "offered_hash" => receipt["offered_hash"] }
          $Trainer.instance_variable_set(:@kif_multiplayer_trade_applied, markers)
          $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, nil)
        end
      end
      change_profile { pending["stage"] = "applied" }
      @client.request("POST", PoolPaths.path(deposit["deposit_id"], "ack"), { "transaction_id" => transaction_id })
      clear_local_journal
    end
  end

  # Keep an online-pool escrow from being interpreted as a friend trade. This
  # wrapper leaves the frozen V2 transaction implementation unchanged.
  module PoolEscrowIsolation
    def recover
      value = escrow
      if value && value["kind"] == "pool"
        raise Error, "当前锁定个体属于在线奇迹交换池，请从交换池入口恢复。"
      end
      super
    end
  end
  TradeSession.prepend(PoolEscrowIsolation)

  def self.open_pool_menu(client); PoolUI.new(client).main; end
  class PoolUI
    def initialize(client)
      @client, @ui, @session = client, UI.new(client), PoolSession.new(client)
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def main
      @ui.perform { @session.recover }
      loop do
        choice = @ui.choose("在线奇迹交换池\n自由休闲区：本地来源，备份和回滚仍可复制。\n每账号一个待处理投递，24 小时未匹配可取回。", ["选择精灵投递（安全存档并锁定）", "刷新 / 恢复领取", "撤回未匹配投递", "查看我的投递", "服务器托管区", "返回"])
        return if choice < 0 || choice == 5
        @ui.perform do
          case choice
          when 0
            pokemon = @ui.choose_pokemon
            if pokemon && pbConfirmMessage("投递 #{text(pokemon.name)}？将保存当前游戏并锁定原个体。\n匹配后不可撤销，来源为本地休闲。")
              show(@session.deposit(pokemon))
            end
          when 1 then show(@session.recover)
          when 2
            raise Error, "没有待处理投递。" unless @session.pending
            show(@session.withdraw) if pbConfirmMessage("请求撤回？若服务器已经匹配，将领取已确定的交换结果。")
          when 3
            deposits = @session.list.select { |deposit| deposit["source"] == "local_casual" }
            pbMessage(deposits.empty? ? "没有投递记录。" : deposits.map { |deposit| "#{text(deposit['deposit_id'])}\n#{text(deposit['status'])} / #{text(deposit['final_status'])}" }.join("\n"))
          when 4
            raise Error, "请先恢复当前本地投递。" if @session.pending
            KIFMultiplayer.open_managed_pool_menu(@client)
          end
        end
      end
    end
    def show(deposit)
      return pbMessage("没有待处理的本地投递。") unless deposit
      message = "投递 #{text(deposit['deposit_id'])}\n状态：#{text(deposit['status'])}"
      if deposit["status"] == "preparation_cancelled"
        message += "\n尚未上传的准备已取消，原个体已安全归还。"
      elsif deposit["receipt"]
        receipt = deposit["receipt"]
        data = receipt["received_snapshot"] && receipt["received_snapshot"]["pokemon"]
        message += "\n#{receipt['kind'] == 'return' ? '原个体取回' : '匹配交换'}已安全保存。"
        message += "\n#{text(data['name'])} · #{text(data['species'])} Lv.#{data['level']}" if data
      else
        message += "\n原个体仍在存档中安全锁定。"
      end
      pbMessage(message)
    end
  end
end

# Recovery of a local pool must retain the same account even after the received
# Pokemon is durable and only a network ack remains outstanding.
previous_pool_identity_lock = KIFMultiplayer.method(:trade_identity_locked?)
KIFMultiplayer.define_singleton_method(:trade_identity_locked?) do |profile|
  previous_pool_identity_lock.call(profile) || (profile.data["servers"] || {}).values.any? { |account| account.is_a?(Hash) && account["pool_pending"] }
end
previous_pool_identity_guard = KIFMultiplayer.identity_change_guard
KIFMultiplayer.identity_change_guard = lambda do |profile|
  previous_pool_identity_guard.call(profile) if previous_pool_identity_guard
  if (profile.data["servers"] || {}).values.any? { |account| account.is_a?(Hash) && account["pool_pending"] }
    raise KIFMultiplayer::Error.new("请先恢复在线交换池投递，再更换服务器或身份。", "pool_identity_locked")
  end
end
