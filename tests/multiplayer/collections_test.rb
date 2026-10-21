previous_fixture_flag = ENV["KIF_TRADE_FIXTURES_ONLY"]
ENV["KIF_TRADE_FIXTURES_ONLY"] = "1"
load File.expand_path("trade_test.rb", __dir__)
ENV["KIF_TRADE_FIXTURES_ONLY"] = previous_fixture_flag
load "Data/Scripts/054_Multiplayer/009_Pool.rb"
load "Data/Scripts/054_Multiplayer/010_Collections.rb"

class CollectionTestService
  attr_reader :assets, :trades, :deposits, :locks
  def initialize
    @assets, @granted, @trades, @deposits, @locks, @counter = {}, {}, {}, {}, {}, 0
  end
  def copy(value); KIFMultiplayer::TradeCodec.copy(value); end
  def require_owner(owner, asset_id)
    asset = @assets[asset_id]
    raise KIFMultiplayer::Error, "asset ownership mismatch" unless asset && asset["owner_id"] == owner
    asset
  end
  def view(trade, owner)
    result = copy(trade.reject { |key, _| key == "receipts" })
    result["receipt"] = copy(trade["receipts"][owner]) if trade["receipts"]
    result
  end
  def request(owner, method, path, body)
    parts = path.split("/").reject(&:empty?)
    if parts[1] == "collections"
      if method == "GET"
        return { "assets" => copy(@assets.values.select { |asset| asset["owner_id"] == owner }) }
      elsif parts[2] == "starter"
        raise KIFMultiplayer::Error, "client snapshot upload forbidden" unless (body.keys - %w[catalog_version request_id]).empty? && body["catalog_version"] == 1
        unless @granted[owner]
          id = "asset_#{owner}"
          @assets[id] = { "id" => id, "owner_id" => owner, "source" => "server_catalog", "catalog_version" => 1, "snapshot" => trade_test_snapshot(@assets.length + 500)["pokemon"] }
          @granted[owner] = true
        end
        return { "ok" => true }
      elsif parts[3] == "showcase"
        asset = require_owner(owner, parts[2])
        return { "showcase" => { "code" => "SHOW_#{asset['id']}", "snapshot" => copy(asset["snapshot"]), "source" => "server_catalog" } }
      end
    elsif parts[1] == "trades"
      if parts.length == 2
        return { "trades" => @trades.values.select { |trade| trade["members"].key?(owner) }.map { |trade| view(trade, owner) } } if method == "GET"
        @counter += 1
        code = "M%05d" % @counter
        trade = { "code" => code, "source" => body["source"], "members" => { owner => { "id" => owner } }, "offers" => {}, "confirmations" => [], "revision" => 1, "status" => "waiting", "acked" => [] }
        @trades[code] = trade
        return { "trade" => view(trade, owner) }
      end
      trade = @trades.fetch(parts[2])
      if method == "GET"
        raise KIFMultiplayer::Error, "not member" unless trade["members"].key?(owner)
        return { "trade" => view(trade, owner) }
      end
      case parts[3]
      when "join"
        raise KIFMultiplayer::Error, "source mismatch" if body["source"] && body["source"] != trade["source"]
        trade["members"][owner] = { "id" => owner }
        trade["status"] = "offering"
      when "offer"
        asset = require_owner(owner, body["asset_id"])
        raise KIFMultiplayer::Error, "asset locked" if @locks[asset["id"]] && @locks[asset["id"]] != trade["code"]
        @locks[asset["id"]] = trade["code"]
        trade["offers"][owner] = { "asset_id" => asset["id"], "snapshot" => copy(asset["snapshot"]), "hash" => KIFMultiplayer::TradeCodec.digest(asset["snapshot"]), "offer_id" => body["offer_id"] }
        trade["revision"] += 1
        trade["confirmations"] = []
      when "confirm"
        raise KIFMultiplayer::Error, "stale revision" unless trade["revision"] == body["revision"]
        hashes = trade["offers"].each_with_object({}) { |(id, offer), result| result[id] = offer["hash"] }
        raise KIFMultiplayer::Error, "wrong offer hashes" unless hashes.length == 2 && hashes == body["offer_hashes"]
        trade["confirmations"] << owner unless trade["confirmations"].include?(owner)
        if trade["confirmations"].length == 2
          trade["transaction_id"], trade["status"], trade["receipts"] = "hosted_#{trade['code']}", "committed", {}
          owners = trade["members"].keys
          owners.each do |recipient|
            other = (owners - [recipient]).first
            asset = @assets[trade["offers"][other]["asset_id"]]
            asset["owner_id"] = recipient
            @locks.delete(asset["id"])
          end
          owners.each do |recipient|
            other = (owners - [recipient]).first
            asset = @assets[trade["offers"][other]["asset_id"]]
            trade["receipts"][recipient] = { "transaction_id" => trade["transaction_id"], "source" => "server_managed", "owner_id" => recipient,
              "offered_hash" => trade["offers"][recipient]["hash"], "received_hash" => trade["offers"][other]["hash"], "received_asset" => copy(asset) }
          end
        end
      when "ack"
        raise KIFMultiplayer::Error, "wrong transaction" unless trade["transaction_id"] == body["transaction_id"]
        trade["acked"] << owner unless trade["acked"].include?(owner)
        trade["status"] = "completed" if trade["acked"].length == 2
      when "cancel"
        trade["status"] = "cancelled"
        trade["offers"].each_value { |offer| @locks.delete(offer["asset_id"]) }
      end
      return { "trade" => view(trade, owner) }
    elsif parts[1] == "pool"
      if parts.length == 3
        return { "deposits" => copy(@deposits.values.select { |deposit| deposit["owner_id"] == owner }) } if method == "GET"
        id = body["deposit_id"]
        return { "deposit" => copy(@deposits[id]) } if @deposits[id]
        asset = require_owner(owner, body["asset_id"])
        raise KIFMultiplayer::Error, "asset locked" if @locks[asset["id"]]
        @locks[asset["id"]] = id
        deposit = { "deposit_id" => id, "owner_id" => owner, "source" => "server_managed", "offer_id" => body["offer_id"], "asset_id" => asset["id"], "status" => "waiting", "acked" => false }
        @deposits[id] = deposit
        return { "deposit" => copy(deposit) }
      end
      deposit = @deposits[parts[3]]
      raise KIFMultiplayer::Error.new("not found", "deposit_not_found") unless deposit
      raise KIFMultiplayer::Error, "wrong owner" unless deposit["owner_id"] == owner
      if parts[4] == "withdraw" && deposit["status"] == "waiting"
        @locks.delete(deposit["asset_id"])
        deposit["status"], deposit["transaction_id"] = "withdrawn", "return_#{deposit['deposit_id']}"
        deposit["receipt"] = { "transaction_id" => deposit["transaction_id"], "source" => "server_managed", "owner_id" => owner, "kind" => "return", "offer_id" => deposit["offer_id"], "received_asset" => copy(@assets[deposit["asset_id"]]) }
      elsif parts[4] == "ack"
        raise KIFMultiplayer::Error, "wrong transaction" unless body["transaction_id"] == deposit["transaction_id"]
        deposit["status"], deposit["acked"] = "completed", true
      end
      return { "deposit" => copy(deposit) }
    end
    raise KIFMultiplayer::Error, "unknown test endpoint"
  end
end

checks = 0
log = File.open(File.join(TRADE_TEST_DIR, "collections-test.log"), "w")
assert = lambda do |condition, description|
  raise "FAIL #{description}" unless condition
  checks += 1; log.puts("PASS #{description}"); log.flush
end
reject = lambda do |description, &action|
  rejected = false
  begin
    action.call
  rescue KIFMultiplayer::Error
    rejected = true
  end
  assert.call(rejected, description)
end
begin
  $Trainer, $PokemonStorage = TradeTestPlayer.new(5), TradeTestStorage.new
  original_save_objects = Marshal.dump([$Trainer, $PokemonStorage])
  service = CollectionTestService.new
  clients = [TradeTestClient.new(service, 5), TradeTestClient.new(service, 6)]
  collections = clients.map { |client| KIFMultiplayer::CollectionClient.new(client) }
  trades = clients.map { |client| KIFMultiplayer::ManagedTradeSession.new(client) }
  pools = clients.map { |client| KIFMultiplayer::ManagedPoolSession.new(client) }
  assert.call(collections[0].refresh.empty?, "new server inventory is empty without inventing local assets")
  a = collections[0].starter.first
  b = collections[1].starter.first
  assert.call(a["source"] == "server_catalog" && a["owner_id"] == clients[0].player_id, "starter source and authoritative owner are server records")
  assert.call(collections[0].starter.length == 1 && service.assets.length == 2, "repeated starter cannot grant duplicate assets")
  reject.call("local snapshot upload cannot become a hosted starter") { clients[0].request("POST", "/v1/collections/starter", { "catalog_version" => 1, "snapshot" => trade_test_snapshot(999) }) }
  reject.call("client cannot offer another server owner's asset") { trades[0].offer("M00001", b["id"]) }
  result = collections[0].publish(a["id"])
  assert.call(result["showcase"]["snapshot"] == a["snapshot"], "hosted showcase uses authoritative asset snapshot")
  local_trade = service.request(clients[0].player_id, "POST", "/v1/trades", { "source" => "local_casual" })["trade"]
  reject.call("hosted entry rejects local-source room code before joining") { trades[1].join(local_trade["code"]) }
  assert.call(!service.trades[local_trade["code"]]["members"].key?(clients[1].player_id), "source mismatch cannot mutate room membership")
  service.trades.delete(local_trade["code"])
  trade = trades[0].create
  trades[1].join(trade["code"])
  trades[0].offer(trade["code"], a["id"])
  trade = trades[1].offer(trade["code"], b["id"])
  assert.call(service.locks[a["id"]] == trade["code"], "hosted quote locks authoritative asset")
  reject.call("quoted hosted asset cannot be deposited concurrently") { pools[0].deposit(a["id"]) }
  pools[0].withdraw # no server deposit was created, clearing unsent draft only
  trade = trades[0].confirm(trade)
  trade = trades[1].confirm(trade)
  assert.call(service.assets[a["id"]]["owner_id"] == clients[1].player_id && service.assets[b["id"]]["owner_id"] == clients[0].player_id, "double confirmation atomically swaps server owners")
  assert.call(collections[1].refresh.map { |asset| asset["id"] } == [a["id"]], "recipient cache refresh reflects authoritative ownership")
  clients[0].fail_before_for = "/ack"
  reject.call("hosted post-commit disconnect preserves recovery code") { trades[0].recover }
  assert.call(trades[0].code == trade["code"], "unacked hosted exchange retains exact original session")
  trades[0].recover
  assert.call(!trades[0].code && service.trades[trade["code"]]["status"] == "completed", "hosted recovery acks original swap without reassigning owners")
  reject.call("old owner cannot publish transferred asset") { collections[0].publish(a["id"]) }
  assert.call(Marshal.dump([$Trainer, $PokemonStorage]) == original_save_objects, "starter showcase hosted exchange and recovery never mutate main save objects")
  clients[0].fail_before_for = ["POST", "/v1/pool/deposits"]
  reject.call("hosted pool unsent request keeps original deposit ID") { pools[0].deposit(b["id"]) }
  original_id = pools[0].deposit_id
  assert.call(!service.deposits.key?(original_id), "unsent hosted pool preparation does not create phantom asset")
  deposit = pools[0].recover
  assert.call(deposit["deposit_id"] == original_id && service.locks[b["id"]] == original_id, "hosted pool recovery reuses journaled operation and locks server asset")
  reject.call("pending hosted pool prevents identity server switch") { clients[0].profile.server = "http://127.0.0.1:9999" }
  deposit = pools[0].withdraw
  assert.call(deposit["status"] == "withdrawn" && !pools[0].deposit_id && !service.locks[b["id"]], "hosted pool withdrawal returns server ownership without local generation")
  assert.call(collections[0].refresh.map { |asset| asset["id"] } == [b["id"]], "withdrawn hosted asset remains solely with authoritative owner")
  assert.call(Marshal.dump([$Trainer, $PokemonStorage]) == original_save_objects, "hosted pool never writes local party or storage")
  # Reload metadata cache; it is still not accepted as source for assets.
  reloaded = KIFMultiplayer::Profile.new(clients[0].profile.path)
  assert.call(reloaded.account["managed_assets_cache"].first["id"] == b["id"], "display cache persists independently of main save")
  forged = KIFMultiplayer::TradeCodec.copy(a)
  forged["owner_id"] = clients[0].player_id
  clients[0].profile.account["managed_assets_cache"] = [forged]
  reject.call("forged local cache cannot satisfy server-backed offer ownership") { trades[0].offer("M00002", a["id"]) }
  assert.call(service.assets.length == 2, "all hosted operations preserve fixed authoritative asset count")
  # Reading an old terminal session must not unlock a newer active session.
  historical = service.trades[trade["code"]]
  newer = trades[0].create
  trades[0].reconcile(service.view(historical, clients[0].player_id))
  assert.call(trades[0].code == newer["code"], "historical completed receipt cannot clear newer managed transaction context")
  trades[0].cancel(newer["code"])
  profile = clients[0].profile
  save = profile.method(:save)
  failed = false
  active = trades[0].create
  profile.define_singleton_method(:save) do
    if !failed && !account["managed_trade_code"]
      failed = true
      raise IOError, "managed journal cleanup failed"
    end
    save.call
  end
  begin
    trades[0].cancel(active["code"])
    raise "expected cleanup failure"
  rescue IOError
    assert.call(trades[0].code == active["code"], "managed profile cleanup failure keeps current transaction lock in memory")
  end
  trades[0].recover
  assert.call(!trades[0].code, "managed cleanup recovery clears only original cancelled session")
  profile.define_singleton_method(:save, save)
  # An initial local draft save failure must not leave a phantom pending pool
  # pointer in memory or create a server asset/deposit.
  before_deposits = service.deposits.length
  failed = false
  profile.define_singleton_method(:save) do
    if !failed && account["managed_pool_id"]
      failed = true
      raise IOError, "managed pool preparation save failed"
    end
    save.call
  end
  begin
    pools[0].deposit(b["id"])
    raise "expected managed pool profile failure"
  rescue IOError
    assert.call(!pools[0].deposit_id && !profile.account["managed_pool_draft"], "managed pool failed preparation atomically rolls both draft and ID back")
  end
  assert.call(service.deposits.length == before_deposits && service.assets[b["id"]]["owner_id"] == clients[0].player_id, "managed preparation save failure cannot submit or transfer any asset")
  profile.define_singleton_method(:save, save)
  log.puts("COLLECTIONS_TEST_PASS checks=#{checks}")
  puts("COLLECTIONS_TEST_PASS checks=#{checks} evidence=#{TRADE_TEST_DIR}")
rescue StandardError => error
  log.puts("COLLECTIONS_TEST_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  raise
ensure
  log.close
end
