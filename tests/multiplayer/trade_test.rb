# Standalone transaction fault tests. Every file lives under temp/multiplayer.
# The real Pokemon codec is additionally exercised by trade_game_test.rb.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/006_Trade.rb"
require "fileutils"
require "digest/sha2"
TRADE_TEST_DIR = File.join(root, "temp", "multiplayer", "trade-unit", "run-#{Process.pid}-#{Time.now.to_i}")
FileUtils.mkdir_p(TRADE_TEST_DIR)

module GameData
  class TradeRegistry
    def self.exists?(id); %w[TESTMON HARDY OVERGROW TACKLE TOXIC LEFTOVERS POKEBALL FIRE CHAMPION].include?(id.to_s); end
  end
  Species = Class.new(TradeRegistry)
  Species.const_set(:DATA, { :TESTMON => true })
  Nature = Class.new(TradeRegistry)
  Ability = Class.new(TradeRegistry)
  Item = Class.new(TradeRegistry)
  Move = Class.new(TradeRegistry)
  Type = Class.new(TradeRegistry)
  Ribbon = Class.new(TradeRegistry)
end
NB_POKEMON = 501

def trade_test_snapshot(id)
  stats = KIFMultiplayer::Snapshot::STATS
  base = { "version" => 1, "species" => "TESTMON", "level" => 42, "form" => 0,
    "name" => "Trade #{id}", "gender" => 1, "personal_id" => id, "nature" => "HARDY", "nature_for_stats" => nil,
    "ability" => "OVERGROW", "ability_index" => 0, "ability2" => nil, "ability2_index" => nil,
    "item" => "LEFTOVERS", "moves" => [{ "id" => "TACKLE", "pp" => 7, "ppup" => 3 }],
    "iv" => stats.each_with_object({}) { |s, h| h[s] = 31 }, "ev" => stats.each_with_object({}) { |s, h| h[s] = 0 },
    "iv_maxed" => stats.each_with_object({}) { |s, h| h[s] = false }, "happiness" => 200,
    "shiny" => true, "hidden_power_type" => "FIRE",
    "appearance" => { "head_shinyhue" => 137, "shinyKRS" => [0, 1, 2, 0, 1, 2, 0, 1, 2], "sprite_scale" => 1.25, "size_category" => "AVERAGE" },
    "owner" => { "id" => 0xffffffff, "name" => "Original Trainer", "gender" => 0, "language" => 2 } }
  values = {}
  KIFMultiplayer::TradeCodec::INTEGER_FIELDS.each { |key, range| values[key] = [range[0], 0].max }
  KIFMultiplayer::TradeCodec::OPTIONAL_INTEGER_FIELDS.each_key { |key| values[key] = nil }
  values.merge!("exp" => 74_088, "hp" => 70, "obtain_level" => 5, "status" => "POISON",
    "status_count" => 2, "poke_ball" => "POKEBALL", "first_moves" => ["TACKLE", "TOXIC"], "ribbons" => ["CHAMPION"],
    "obtain_text" => "独立测试", "veryunique" => "local_#{id}", "glitter" => true,
    "force_disobey" => false, "imported" => true, "type1kuray" => nil, "type2kuray" => nil, "sprite_asset" => nil, "old_sprite_asset" => nil)
  { "version" => 1, "pokemon" => base, "preserved" => values }
end

class TradeTestPokemon
  attr_reader :snapshot
  def initialize(snapshot); @snapshot = KIFMultiplayer::TradeCodec.copy(snapshot); end
  def hp; @snapshot["preserved"]["hp"]; end
  def egg?; false; end
  def personalID; @snapshot["pokemon"]["personal_id"]; end
end
class TradeTestPlayer
  attr_accessor :party, :save_slot
  def initialize(id)
    @party = (1..3).map { |i| TradeTestPokemon.new(trade_test_snapshot(id * 100 + i)) }
    @save_slot = "actor-#{id}"
  end
end
class TradeTestStorage
  def initialize; @boxes = Array.new(2) { Array.new(3) }; end
  def maxBoxes; @boxes.length; end
  def maxPokemon(box); @boxes[box].length; end
  def [](box, slot); @boxes[box][slot]; end
  def []=(box, slot, pokemon); @boxes[box][slot] = pokemon; end
end
module SaveData
  def self.get_full_path(slot); File.join(TRADE_TEST_DIR, "#{slot}.rxdata"); end
  def self.compile_save_hash; { :player => $Trainer, :storage => $PokemonStorage }; end
  def self.get_data_from_file(path); File.open(path, "rb") { |file| Marshal.load(file) }; end
end
class TradeBrokenSave < KIFMultiplayer::TradeSave
  def persist; raise IOError, "injected full disk before durable rename"; end
end

# This fake isolates local crash recovery from HTTP (covered by service tests).
# It models an independent service clock/state and never writes a game save.
class TradeTestService
  attr_accessor :trades, :ack_calls
  def initialize; @trades, @counter, @ack_calls = {}, 0, 0; end
  def view(trade, owner)
    result = KIFMultiplayer::TradeCodec.copy(trade.reject { |key, _| key == "receipts" })
    result["receipt"] = trade["receipts"][owner] if trade["receipts"]
    result
  end
  def request(owner, method, path, body)
    parts = path.split("/").reject(&:empty?)
    if parts.length == 2
      return { "trades" => @trades.values.select { |trade| trade["members"].include?(owner) }.map { |trade| view(trade, owner) } } if method == "GET"
      @counter += 1
      code = "T%05d" % @counter
      trade = { "code" => code, "status" => "waiting", "members" => [owner], "offers" => {}, "confirmations" => [], "revision" => 1, "acked" => [] }
      @trades[code] = trade
      return { "trade" => view(trade, owner) }
    end
    trade = @trades.fetch(parts[2])
    action = parts[3]
    if action == "join"
      trade["members"] << owner unless trade["members"].include?(owner)
      trade["status"] = "offering"
    elsif !trade["members"].include?(owner)
      raise KIFMultiplayer::Error, "not a member"
    elsif method == "GET"
      return { "trade" => view(trade, owner) }
    elsif action == "offer"
      raise KIFMultiplayer::Error, "already committed" unless %w[waiting offering].include?(trade["status"])
      snapshot = KIFMultiplayer::TradeCodec.copy(body["snapshot"])
      trade["offers"][owner] = { "snapshot" => snapshot, "offer_id" => body["offer_id"], "hash" => KIFMultiplayer::TradeCodec.digest(snapshot) }
      trade["confirmations"] = []
      trade["revision"] += 1
    elsif action == "confirm"
      raise KIFMultiplayer::Error, "stale revision" unless trade["revision"] == body["revision"]
      hashes = trade["offers"].each_with_object({}) { |(id, offer), result| result[id] = offer["hash"] }
      raise KIFMultiplayer::Error, "stale offers" unless hashes.length == 2 && hashes == body["offer_hashes"]
      trade["confirmations"] << owner unless trade["confirmations"].include?(owner)
      if trade["confirmations"].length == 2
        trade["status"], trade["transaction_id"], trade["receipts"] = "committed", "tx_#{trade['code']}", {}
        trade["members"].each do |id|
          other = (trade["members"] - [id]).first
          trade["receipts"][id] = { "transaction_id" => trade["transaction_id"], "source" => "local_casual", "owner_id" => id, "offered_hash" => trade["offers"][id]["hash"], "received_snapshot" => trade["offers"][other]["snapshot"], "received_hash" => trade["offers"][other]["hash"] }
        end
      end
    elsif action == "cancel"
      raise KIFMultiplayer::Error, "already committed" unless %w[waiting offering].include?(trade["status"])
      trade["status"] = "cancelled"
    elsif action == "ack"
      @ack_calls += 1
      raise KIFMultiplayer::Error, "wrong transaction" unless trade["transaction_id"] == body["transaction_id"]
      trade["acked"] << owner unless trade["acked"].include?(owner)
      trade["status"] = "completed" if trade["acked"].length == 2
    end
    { "trade" => view(trade, owner) }
  end
end
class TradeTestClient
  attr_reader :profile, :player_id
  attr_accessor :lose_next_response
  attr_accessor :lose_response_for, :fail_before_for
  def initialize(service, id)
    @service, @player_id = service, "player_#{id}"
    @profile = KIFMultiplayer::Profile.new(File.join(TRADE_TEST_DIR, "actor-#{id}.json"))
    @profile.account["identity"] = { "id" => @player_id }
    @profile.save
  end
  def server; @profile.server; end
  def compatibility; {}; end
  def recover_pending; nil; end
  def request(method, path, body = {})
    fail_match = @fail_before_for.is_a?(Array) ? (method == @fail_before_for[0] && path.end_with?(@fail_before_for[1])) : (@fail_before_for && path.end_with?(@fail_before_for))
    if fail_match
      @fail_before_for = nil
      raise KIFMultiplayer::UncertainRequest.new("injected disconnect before request", "network_timeout")
    end
    result = @service.request(@player_id, method, path, body)
    if @lose_next_response || (@lose_response_for && path.end_with?(@lose_response_for))
      @lose_next_response = false
      @lose_response_for = nil
      raise KIFMultiplayer::UncertainRequest.new("injected response lost after commit", "network_timeout")
    end
    result
  end
end

unless ENV["KIF_TRADE_FIXTURES_ONLY"] == "1"
checks = 0
log = File.open(File.join(TRADE_TEST_DIR, "trade-test.log"), "w")
assert = lambda do |condition, description|
  raise "FAIL #{description}" unless condition
  checks += 1
  log.puts("PASS #{description}")
  log.flush
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
  codec = KIFMultiplayer::TradeCodec
  fixture = trade_test_snapshot(0xffffffff)
  assert.call(codec.validate(fixture) == fixture, "full fixed trade schema accepts supported individual")
  fixture["preserved"].each_key do |key|
    broken = codec.copy(fixture)
    broken["preserved"].delete(key)
    reject.call("missing preserved #{key} rejected before confirmation") { codec.validate(broken) }
  end
  reject.call("unknown wire data rejected") { codec.validate(fixture.merge("script" => "eval")) }
  reject.call("unsupported trade version rejected") { codec.validate(fixture.merge("version" => 2)) }
  broken = codec.copy(fixture); broken["preserved"]["exp"] = -1
  reject.call("negative experience rejected") { codec.validate(broken) }
  broken = codec.copy(fixture); broken["preserved"]["ribbons"] = ["BAD_RIBBON"]
  reject.call("unsupported ribbon rejected") { codec.validate(broken) }
  broken = codec.copy(fixture); broken["preserved"]["obtain_text"] = "bad\ntext"
  reject.call("control characters rejected") { codec.validate(broken) }
  # The actual conversion is separately exercised against real GameData/Pokemon.
  codec.define_singleton_method(:export) { |pokemon| copy(validate(pokemon.snapshot)) }
  codec.define_singleton_method(:import) { |snapshot| TradeTestPokemon.new(validate(snapshot)) }
  service = TradeTestService.new
  players = [TradeTestPlayer.new(1), TradeTestPlayer.new(2)]
  storages = [TradeTestStorage.new, TradeTestStorage.new]
  clients = [TradeTestClient.new(service, 1), TradeTestClient.new(service, 2)]
  sessions = clients.map { |client| KIFMultiplayer::TradeSession.new(client) }
  use = lambda { |index| $Trainer, $PokemonStorage = players[index], storages[index] }
  disk_player = lambda { |index| File.open(SaveData.get_full_path(players[index].save_slot), "rb") { |file| Marshal.load(file)[:player] } }
  use.call(0)
  KIFMultiplayer::TradeSave.new.persist
  original = players[0].party.first
  before_disk = File.binread(SaveData.get_full_path(players[0].save_slot))
  trade = sessions[0].create
  failed = KIFMultiplayer::TradeSession.new(clients[0], TradeBrokenSave.new)
  reject.call("failed atomic save prevents quote upload") { failed.offer(trade["code"], original) }
  assert.call(players[0].party.first.equal?(original) && failed.escrow.nil?, "failed save restores exact party object and escrow")
  assert.call(File.binread(SaveData.get_full_path(players[0].save_slot)) == before_disk, "failed save leaves previous disk save byte-for-byte intact")
  assert.call(service.trades[trade["code"]]["offers"].empty?, "save failure cannot create remote quote")
  sessions[0].recover
  assert.call(!sessions[0].pending, "preparing journal safely recovers when service confirms no uploaded quote")
  use.call(1); sessions[1].join(trade["code"])
  use.call(0); trade = sessions[0].offer(trade["code"], original)
  assert.call(!players[0].party.include?(original) && sessions[0].escrow["entries"][0]["pokemon"].equal?(original), "offered original is locked outside usable party and remains exact object")
  persisted = disk_player.call(0)
  assert.call(persisted.party.length == 2 && persisted.instance_variable_get(:@kif_multiplayer_trade_escrow)["entries"].length == 1, "real save contains locked original before offer succeeds")
  assert.call(KIFMultiplayer.trade_identity_locked?(clients[0].profile), "pending trade locks identity and server")
  clients[0].profile.account.delete("trade_pending")
  assert.call(KIFMultiplayer.trade_identity_locked?(clients[0].profile), "saved escrow locks identity after journal deletion")
  sessions[0].recover
  assert.call(sessions[0].pending["code"] == trade["code"], "save escrow rebuilds lost profile journal")
  use.call(1)
  guest_original = players[1].party.first
  trade = sessions[1].offer(trade["code"], guest_original)
  stale = codec.copy(trade)
  use.call(0); sessions[0].confirm(trade)
  replacement = players[0].party.last
  trade = sessions[0].offer(trade["code"], replacement)
  assert.call(trade["confirmations"].empty?, "replacement clears both prior confirmations")
  assert.call(players[0].party.include?(original) && !players[0].party.include?(replacement), "confirmed quote replacement restores old original and locks new original atomically")
  use.call(1)
  reject.call("stale quote revision cannot confirm swapped offer") { sessions[1].confirm(stale) }
  trade = sessions[1].confirm(trade)
  use.call(0)
  trade = sessions[0].confirm(trade)
  assert.call(trade["status"] == "committed", "second current confirmation commits exactly one transaction")
  assert.call(sessions[0].escrow.nil? && !sessions[0].pending, "receipt saves original replacement and clears journal after ack")
  assert.call(players[0].party.any? { |p| p.snapshot == guest_original.snapshot }, "received individual preserves all supported fields")
  assert.call(!players[0].party.any? { |p| p.personalID == replacement.personalID }, "committed outgoing original is absent from active party")
  persisted = disk_player.call(0)
  transaction_id = trade["transaction_id"]
  assert.call(persisted.instance_variable_get(:@kif_multiplayer_trade_applied).key?(transaction_id), "applied transaction marker and received individual coexist in same durable save")
  use.call(1)
  # The second player restarts from the actual saved file after server commit.
  players[1] = disk_player.call(1)
  use.call(1)
  clients[1].lose_next_response = true
  reject.call("lost status response retains transaction journal") { sessions[1].recover }
  clients[1].lose_next_response = false
  sessions[1].recover
  assert.call(players[1].party.any? { |p| p.snapshot == replacement.snapshot }, "restart recovers committed original transaction")
  assert.call(service.trades[trade["code"]]["status"] == "completed", "both durable saves ack the same transaction")
  use.call(0)
  record = { "code" => trade["code"], "server" => clients[0].server, "player_id" => clients[0].player_id,
    "save_path" => sessions[0].active_path, "save_id" => players[0].instance_variable_get(:@kif_multiplayer_trade_save_id), "stage" => "applied" }
  clients[0].profile.account["trade_pending"] = record
  before_count = players[0].party.length
  before_ids = players[0].party.map(&:personalID)
  sessions[0].recover
  assert.call(players[0].party.length == before_count && players[0].party.map(&:personalID) == before_ids, "duplicate receipt cannot duplicate received Pokemon")
  assert.call(players[0].instance_variable_get(:@kif_multiplayer_trade_applied).length == 1, "repeated ack cannot duplicate application marker")
  # Commit succeeded on the service but the recipient's disk is unavailable.
  failure_trade = sessions[0].create
  failure_source_a = players[0].party.first
  sessions[0].offer(failure_trade["code"], failure_source_a)
  use.call(1)
  sessions[1].join(failure_trade["code"])
  failure_source_b = players[1].party.first
  failure_trade = sessions[1].offer(failure_trade["code"], failure_source_b)
  use.call(0); failure_trade = sessions[0].confirm(failure_trade)
  use.call(1)
  disk_before_commit = File.binread(SaveData.get_full_path(players[1].save_slot))
  broken_receiver = KIFMultiplayer::TradeSession.new(clients[1], TradeBrokenSave.new)
  reject.call("disk failure after server commit stops receipt ack") { broken_receiver.confirm(failure_trade) }
  assert.call(service.trades[failure_trade["code"]]["status"] == "committed" && service.trades[failure_trade["code"]]["acked"].empty?, "committed transaction remains pending during disk failure")
  assert.call(File.binread(SaveData.get_full_path(players[1].save_slot)) == disk_before_commit && sessions[1].escrow, "post-commit disk failure preserves original persisted escrow")
  assert.call(!players[1].party.any? { |p| p.personalID == failure_source_a.personalID }, "failed durable receipt does not retain generated Pokemon in memory")
  # Save succeeds, then the client disconnects before sending its ack.
  clients[1].fail_before_for = "/ack"
  reject.call("disconnect between durable save and ack retains applied journal") { sessions[1].recover }
  assert.call(sessions[1].pending["stage"] == "applied" && sessions[1].escrow.nil?, "saved application marker survives an unsent ack")
  players[1] = disk_player.call(1)
  use.call(1)
  clients[1].profile.account.delete("trade_pending")
  count_after_save = players[1].party.length
  sessions[1].recover
  assert.call(!sessions[1].pending && players[1].party.length == count_after_save, "saved applied marker restores a deleted journal and acks without generating a duplicate")
  use.call(0)
  corrupt_receipt = service.trades[failure_trade["code"]]["receipts"][clients[0].player_id]
  correct_owner = corrupt_receipt["owner_id"]
  corrupt_receipt["owner_id"] = clients[1].player_id
  reject.call("receipt for another recipient cannot be applied") { sessions[0].recover }
  assert.call(sessions[0].escrow && sessions[0].pending, "wrong-owner receipt preserves local locked original")
  corrupt_receipt["owner_id"] = correct_owner
  expected_received = corrupt_receipt["received_snapshot"]
  corrupt_receipt["received_snapshot"] = codec.copy(expected_received)
  corrupt_receipt["received_snapshot"]["pokemon"]["name"] = "Uninspected replacement"
  reject.call("receipt cannot substitute an uninspected individual") { sessions[0].recover }
  corrupt_receipt["received_snapshot"] = expected_received
  clients[0].lose_response_for = "/ack"
  reject.call("lost ack response after server commit preserves local recovery") { sessions[0].recover }
  count_after_lost_ack = players[0].party.length
  sessions[0].recover
  assert.call(players[0].party.length == count_after_lost_ack && !sessions[0].pending, "lost ack response repeats only ack and never receipt insertion")
  assert.call(service.trades[failure_trade["code"]]["status"] == "completed", "both post-fault recipients finish the original transaction")
  # Real cancellation and full-storage failure leave the locked source intact.
  cancel_trade = sessions[0].create
  cancelled_source = players[0].party.first
  sessions[0].offer(cancel_trade["code"], cancelled_source)
  returned = sessions[0].cancel(cancel_trade["code"])
  assert.call(returned["status"] == "cancelled" && players[0].party.include?(cancelled_source), "cancel before commit returns exact original and persists it")
  assert.call(!sessions[0].pending && sessions[0].escrow.nil?, "cancellation clears escrow and pending only after successful save")
  fresh = sessions[0].create
  source = players[0].party.first
  sessions[0].offer(fresh["code"], source)
  while players[0].party.length < 6
    players[0].party << TradeTestPokemon.new(trade_test_snapshot(9000 + players[0].party.length))
  end
  storages[0].maxBoxes.times { |box| storages[0].maxPokemon(box).times { |slot| storages[0][box, slot] = TradeTestPokemon.new(trade_test_snapshot(9500 + box * 3 + slot)) } }
  reject.call("full storage stops local cancel application safely") { sessions[0].cancel(fresh["code"]) }
  assert.call(sessions[0].pending && sessions[0].escrow["entries"].first["pokemon"].equal?(source), "full storage cannot lose locked original")
  players[0].party.pop
  sessions[0].recover
  assert.call(players[0].party.include?(source) && !sessions[0].pending, "freeing one slot resumes cancelled original recovery")
  # A different slot cannot apply a receipt or unlock the source.
  guarded = sessions[0].create
  sessions[0].offer(guarded["code"], players[0].party.first)
  players[0].save_slot = "other-slot"
  reject.call("different save slot cannot apply transaction") { sessions[0].recover }
  players[0].save_slot = "actor-1"
  sessions[0].cancel(guarded["code"])
  assert.call(Dir.glob(File.join(TRADE_TEST_DIR, "*.tmp")).empty?, "atomic saves leave no incomplete temporary files")
  log.puts("TRADE_TEST_PASS checks=#{checks}")
  puts("TRADE_TEST_PASS checks=#{checks} evidence=#{TRADE_TEST_DIR}")
rescue StandardError => error
  log.puts("TRADE_TEST_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  raise
ensure
  log.close
end
end
