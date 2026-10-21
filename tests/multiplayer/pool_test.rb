# Reuse isolated save fixtures without running or altering the V2 test scenario.
previous_fixture_flag = ENV["KIF_TRADE_FIXTURES_ONLY"]
ENV["KIF_TRADE_FIXTURES_ONLY"] = "1"
load File.expand_path("trade_test.rb", __dir__)
ENV["KIF_TRADE_FIXTURES_ONLY"] = previous_fixture_flag
load "Data/Scripts/054_Multiplayer/009_Pool.rb"
codec = KIFMultiplayer::TradeCodec
codec.define_singleton_method(:export) { |pokemon| copy(validate(pokemon.snapshot)) }
codec.define_singleton_method(:import) { |snapshot| TradeTestPokemon.new(validate(snapshot)) }

class PoolTestService
  attr_reader :deposits, :acks
  attr_accessor :now
  def initialize; @deposits, @acks, @now = {}, 0, 1000; end
  def copy(data); KIFMultiplayer::TradeCodec.copy(data); end
  def return_deposit(deposit, status)
    deposit["status"] = deposit["final_status"] = status
    deposit["transaction_id"] = "return_#{deposit['deposit_id']}"
    deposit["receipt"] = { "transaction_id" => deposit["transaction_id"], "source" => deposit["source"], "owner_id" => deposit["owner_id"],
      "kind" => "return", "offer_id" => deposit["offer_id"], "offered_snapshot" => deposit["snapshot"], "offered_hash" => deposit["offered_hash"],
      "received_snapshot" => deposit["snapshot"], "received_hash" => deposit["offered_hash"] }
  end
  def expire
    @deposits.each_value { |deposit| return_deposit(deposit, "expired") if deposit["status"] == "waiting" && @now >= deposit["expires_at"] }
  end
  def request(owner, method, path, body)
    expire
    parts = path.split("/").reject(&:empty?)
    if parts.length == 3
      return { "deposits" => copy(@deposits.values.select { |deposit| deposit["owner_id"] == owner }) } if method == "GET"
      id = body["deposit_id"]
      if @deposits[id]
        raise KIFMultiplayer::Error, "wrong owner" unless @deposits[id]["owner_id"] == owner
        return { "deposit" => copy(@deposits[id]) }
      end
      raise KIFMultiplayer::Error, "pending deposit" if @deposits.values.any? { |deposit| deposit["owner_id"] == owner && deposit["status"] != "completed" }
      snapshot = copy(body["snapshot"])
      deposit = { "deposit_id" => id, "owner_id" => owner, "source" => body["source"], "offer_id" => body["offer_id"], "snapshot" => snapshot,
        "offered_hash" => KIFMultiplayer::TradeCodec.digest(snapshot), "compatibility" => body["compatibility"], "status" => "waiting", "acked" => false, "created_at" => @now, "expires_at" => @now + 86_400 }
      @deposits[id] = deposit
      other = @deposits.values.find { |candidate| candidate["owner_id"] != owner && candidate["status"] == "waiting" && candidate["source"] == deposit["source"] && candidate["compatibility"] == deposit["compatibility"] }
      if other
        transaction = "match_#{id}"
        [[deposit, other], [other, deposit]].each do |recipient, sender|
          recipient["status"] = recipient["final_status"] = "matched"
          recipient["transaction_id"] = transaction
          recipient["receipt"] = { "transaction_id" => transaction, "source" => recipient["source"], "owner_id" => recipient["owner_id"], "kind" => "exchange", "offer_id" => recipient["offer_id"],
            "offered_snapshot" => recipient["snapshot"], "offered_hash" => recipient["offered_hash"], "received_snapshot" => sender["snapshot"], "received_hash" => sender["offered_hash"] }
        end
      end
      return { "deposit" => copy(deposit) }
    end
    deposit = @deposits[parts[3]]
    raise KIFMultiplayer::Error.new("not found", "deposit_not_found") unless deposit
    raise KIFMultiplayer::Error, "wrong owner" unless deposit["owner_id"] == owner
    if method == "POST" && parts[4] == "withdraw"
      return_deposit(deposit, "withdrawn") if deposit["status"] == "waiting"
    elsif method == "POST" && parts[4] == "ack"
      raise KIFMultiplayer::Error, "wrong transaction" unless deposit["transaction_id"] == body["transaction_id"]
      @acks += 1
      deposit["acked"], deposit["status"] = true, "completed"
    end
    { "deposit" => copy(deposit) }
  end
end

checks = 0
log = File.open(File.join(TRADE_TEST_DIR, "pool-test.log"), "w")
assert = lambda do |condition, description|
  raise "FAIL #{description}" unless condition
  checks += 1
  log.puts("PASS #{description}"); log.flush
end
reject = lambda do |description, &action|
  rejected = false
  begin
    action.call
  rescue KIFMultiplayer::Error, IOError
    rejected = true
  end
  assert.call(rejected, description)
end
begin
  service = PoolTestService.new
  players = [TradeTestPlayer.new(3), TradeTestPlayer.new(4)]
  storages = [TradeTestStorage.new, TradeTestStorage.new]
  clients = [TradeTestClient.new(service, 3), TradeTestClient.new(service, 4)]
  sessions = clients.map { |client| KIFMultiplayer::PoolSession.new(client) }
  use = lambda { |index| $Trainer, $PokemonStorage = players[index], storages[index] }
  reload_player = lambda do |index|
    File.open(SaveData.get_full_path(players[index].save_slot), "rb") { |file| players[index] = Marshal.load(file)[:player] }
    use.call(index)
  end
  use.call(0)
  original_a = players[0].party.first
  deposit_a = sessions[0].deposit(original_a)
  assert.call(deposit_a["status"] == "waiting" && !players[0].party.include?(original_a), "first real deposit waits with original safely locked")
  assert.call(service.deposits.length == 1 && sessions[0].own_escrow["entries"].first["pokemon"].equal?(original_a), "local original object remains in saved escrow")
  reject.call("friend-trade recovery cannot consume pool escrow") { KIFMultiplayer::TradeSession.new(clients[0]).recover }
  reject.call("one identity cannot submit a second local deposit") { sessions[0].deposit(players[0].party.first) }
  reject.call("pool pending prevents server switch") { clients[0].profile.server = "http://127.0.0.1:9999" }
  assert.call(KIFMultiplayer.trade_identity_locked?(clients[0].profile), "pool journal locks identity recovery to original account")
  use.call(1)
  original_b = players[1].party.first
  deposit_b = sessions[1].deposit(original_b)
  assert.call(deposit_b["status"] == "matched" && !sessions[1].pending, "second identity matches and durably receives first original")
  assert.call(players[1].party.any? { |pokemon| pokemon.snapshot == original_a.snapshot }, "matched recipient preserves all supported individual fields")
  use.call(0)
  reload_player.call(0)
  clients[0].fail_before_for = "/ack"
  reject.call("disconnect after local receipt save leaves pending ack") { sessions[0].recover }
  count_after_save = players[0].party.length
  assert.call(players[0].party.any? { |pokemon| pokemon.snapshot == original_b.snapshot }, "restart receives original server match rather than rerolling")
  clients[0].profile.account.delete("pool_pending")
  sessions[0].recover
  assert.call(players[0].party.length == count_after_save && !sessions[0].pending, "saved applied marker rebuilds lost pool journal without duplicate receipt")
  assert.call(service.deposits.values.all? { |deposit| deposit["status"] == "completed" }, "independent recipients acknowledge unique original match")
  returned_original = players[0].party.first
  waiting = sessions[0].deposit(returned_original)
  result = sessions[0].withdraw
  assert.call(result["status"] == "withdrawn" && players[0].party.include?(returned_original), "unmatched withdrawal returns exact original object")
  assert.call(service.deposits[waiting["deposit_id"]]["final_status"] == "withdrawn" && !sessions[0].pending, "withdrawal ack preserves unique terminal reason")
  expired_original = players[0].party.first
  waiting = sessions[0].deposit(expired_original)
  service.now += 86_401
  result = sessions[0].recover
  assert.call(result["status"] == "expired" && players[0].party.include?(expired_original), "server-clock expiry returns original without loss")
  # A crash after escrow save but before POST uses the original journaled ID.
  clients[0].fail_before_for = ["POST", "/v1/pool/deposits"]
  unsent_original = players[0].party.first
  reject.call("unsent deposit preserves durable journal") { sessions[0].deposit(unsent_original) }
  unsent_id = sessions[0].pending["deposit_id"]
  assert.call(!service.deposits.key?(unsent_id) && sessions[0].own_escrow, "unsent operation has no phantom server asset")
  restored = sessions[0].recover
  assert.call(restored["deposit_id"] == unsent_id && service.deposits.key?(unsent_id), "recovery submits the exact original deposit ID")
  sessions[0].withdraw
  # A failed local save cannot cause a remote deposit.
  broken = KIFMultiplayer::PoolSession.new(clients[0], TradeBrokenSave.new)
  before_deposits = service.deposits.length
  source = players[0].party.first
  reject.call("disk failure prevents server deposit") { broken.deposit(source) }
  assert.call(service.deposits.length == before_deposits && players[0].party.include?(source), "failed save preserves original party and no remote transfer")
  sessions[0].recover
  assert.call(!sessions[0].pending, "preparing-only failed-save journal safely clears after authoritative not-found")
  # A pending hosted-zone deposit must be detected before any local locking.
  hosted_id = "pool_" + "f" * 32
  service.deposits[hosted_id] = { "deposit_id" => hosted_id, "owner_id" => clients[0].player_id, "source" => "server_managed", "status" => "waiting", "expires_at" => service.now + 86_400 }
  before_cross_zone = players[0].party.dup
  reject.call("hosted-zone pending deposit blocks local-zone submission") { sessions[0].deposit(players[0].party.first) }
  assert.call(players[0].party == before_cross_zone && sessions[0].escrow.nil?, "cross-zone rejection happens before local original is locked")
  service.deposits.delete(hosted_id)
  # Match wins the withdraw race; the client must receive the committed match.
  race_a = players[0].party.first
  waiting = sessions[0].deposit(race_a)
  use.call(1)
  race_b = players[1].party.first
  sessions[1].deposit(race_b)
  use.call(0)
  result = sessions[0].withdraw
  assert.call(result["receipt"]["kind"] == "exchange" && players[0].party.any? { |pokemon| pokemon.snapshot == race_b.snapshot }, "withdraw after matching receives unique exchange instead of returning original")
  assert.call(!players[0].party.any? { |pokemon| pokemon.personalID == race_a.personalID }, "matched original is removed exactly once")
  # Profile reload does not retain an in-memory-only completion state.
  saved = KIFMultiplayer::Profile.new(clients[0].profile.path)
  assert.call(!saved.account["pool_pending"], "completed pool journal removal persists to disk")
  original_save = clients[0].profile.method(:save)
  failed = false
  clients[0].profile.define_singleton_method(:save) do
    if !failed && account["pool_pending"] && account["pool_pending"]["stage"] == "locked"
      failed = true
      raise IOError, "profile failed after pool atomic escrow save"
    end
    original_save.call
  end
  source = players[0].party.first
  reject.call("pool stage profile failure after atomic escrow is recoverable") { sessions[0].deposit(source) }
  id = sessions[0].pending["deposit_id"]
  assert.call(!service.deposits.key?(id) && sessions[0].own_escrow, "unsent pool escrow survives profile-stage failure")
  sessions[0].recover
  assert.call(service.deposits.key?(id) && sessions[0].pending["deposit_id"] == id, "pool retry uses one original deposit after failed profile save")
  old_path = SaveData.get_full_path(players[0].save_slot)
  old_bytes = File.binread(old_path)
  players[0].save_slot = "pool-saveas"
  KIFMultiplayer::TradeSave.new.persist
  export = codec.method(:export)
  codec.define_singleton_method(:export) { |_value| raise KIFMultiplayer::Error, "current offline formatter changed" }
  sessions[0].recover
  codec.define_singleton_method(:export, export)
  assert.call(sessions[0].pending["save_path"] == File.expand_path(SaveData.get_full_path("pool-saveas")), "pool migrates to durably saved same-lineage slot")
  assert.call(File.binread(old_path) == old_bytes, "pool slot migration leaves older file unchanged")
  failed = false
  clients[0].profile.define_singleton_method(:save) do
    if !failed && account["pool_pending"] && account["pool_pending"]["stage"] == "applied"
      failed = true
      raise IOError, "profile failed after pool atomic return save"
    end
    original_save.call
  end
  reject.call("pool profile failure after original return is reproduced") { sessions[0].withdraw }
  count = players[0].party.length
  assert.call(players[0].party.include?(source) && sessions[0].escrow.nil? && sessions[0].pending, "pool original return remains durable without profile-stage success")
  source.snapshot["pokemon"]["name"] = "Trained after pool"
  players[0].save_slot = "pool-applied-saveas"
  KIFMultiplayer::TradeSave.new.persist
  validate = codec.method(:validate)
  codec.define_singleton_method(:validate) { |_value| raise KIFMultiplayer::Error, "data no longer supports a new import" }
  sessions[0].recover
  assert.call(!sessions[0].pending && players[0].party.length == count && source.snapshot["pokemon"]["name"] == "Trained after pool", "pool applied-marker SaveAs only acks despite changed local import registry")
  codec.define_singleton_method(:validate, validate)
  clients[0].profile.define_singleton_method(:save, original_save)
  assert.call(File.binread(old_path) == old_bytes, "pool receipt and applied migration never overwrite prior source slot")
  source = players[0].party.first
  waiting = sessions[0].deposit(source)
  source.snapshot["pokemon"]["name"] = "Local formatter changed"
  validate = codec.method(:validate)
  codec.define_singleton_method(:validate) { |_value| raise KIFMultiplayer::Error, "old registered data unavailable after offline option change" }
  sessions[0].withdraw
  codec.define_singleton_method(:validate, validate)
  assert.call(players[0].party.include?(source) && !sessions[0].pending && sessions[0].escrow.nil?, "authoritative pool return restores exact original despite changed local formatter or registry")
  waiting = sessions[0].deposit(players[0].party.first)
  use.call(1); sessions[1].deposit(players[1].party.first)
  use.call(0)
  receipt = service.deposits[waiting["deposit_id"]]["receipt"]
  correct_hash = receipt["received_hash"]
  receipt["received_hash"] = "0" * 64
  reject.call("first pool receipt with contradictory received hash is rejected") { sessions[0].recover }
  assert.call(sessions[0].own_escrow && sessions[0].pending && players[0].party.length == 2, "invalid hash cannot clear original escrow or add incoming Pokemon")
  receipt["received_hash"] = correct_hash
  clients[0].fail_before_for = "/ack"
  reject.call("pool ack disconnect leaves marker for hash regression") { sessions[0].recover }
  party_bytes = Marshal.dump(players[0].party)
  receipt["received_hash"] = "0" * 64
  reject.call("applied pool receipt with contradictory received hash is rejected") { sessions[0].recover }
  assert.call(Marshal.dump(players[0].party) == party_bytes && sessions[0].pending, "tampered applied receipt cannot mutate durable party or discard recovery journal")
  receipt["received_hash"] = correct_hash
  sessions[0].recover
  assert.call(!sessions[0].pending && Marshal.dump(players[0].party) == party_bytes, "correct original hash restores ack-only recovery")
  log.puts("POOL_TEST_PASS checks=#{checks}")
  puts("POOL_TEST_PASS checks=#{checks} evidence=#{TRADE_TEST_DIR}")
rescue StandardError => error
  log.puts("POOL_TEST_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  raise
ensure
  log.close
end
