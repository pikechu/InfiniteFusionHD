# Crash/save-as regressions: fake transport, real isolated save/profile files.
ENV["KIF_TRADE_FIXTURES_ONLY"] = "1"
load File.expand_path("trade_test.rb", __dir__)
codec = KIFMultiplayer::TradeCodec
codec.define_singleton_method(:export) { |pokemon| copy(validate(pokemon.snapshot)) }
codec.define_singleton_method(:import) { |snapshot| TradeTestPokemon.new(validate(snapshot)) }

checks = 0
assert = lambda do |value, description|
  raise "FAIL #{description}" unless value
  checks += 1
  puts "PASS #{description}"
end
reject = lambda do |description, &block|
  error = nil
  begin; block.call; rescue StandardError => failure; error = failure; end
  assert.call(error, description)
  error
end
service = TradeTestService.new
players = [TradeTestPlayer.new(801), TradeTestPlayer.new(802)]
boxes = [TradeTestStorage.new, TradeTestStorage.new]
clients = [TradeTestClient.new(service, 801), TradeTestClient.new(service, 802)]
sessions = clients.map { |client| KIFMultiplayer::TradeSession.new(client) }
use = lambda { |i| $Trainer, $PokemonStorage = players[i], boxes[i] }
use.call(0)
trade = sessions[0].create
use.call(1); sessions[1].join(trade["code"])
use.call(0)
profile = clients[0].profile
original_save = profile.method(:save)
failed = false
profile.define_singleton_method(:save) do
  if !failed && account["trade_pending"] && account["trade_pending"]["stage"] == "locked"
    failed = true
    raise IOError, "injected profile failure after durable escrow"
  end
  original_save.call
end
original = players[0].party.first
reject.call("profile failure reproduced after atomic escrow before upload") { sessions[0].offer(trade["code"], original) }
assert.call(sessions[0].escrow && !players[0].party.include?(original), "durable original stays quarantined after profile failure")
assert.call(service.trades[trade["code"]]["offers"].empty?, "profile failure occurred before first offer HTTP")
sessions[0].recover
assert.call(service.trades[trade["code"]]["offers"].key?(clients[0].player_id), "recovery resumes exact durable unsent quote")

# The save succeeds but the separate profile write fails. Solo progress after
# that point must survive recovery, even if a new import is no longer possible.
use.call(1); trade = sessions[1].offer(trade["code"], players[1].party.first)
use.call(1); sessions[1].confirm(trade)
use.call(0)
failed = false
profile.define_singleton_method(:save) do
  if !failed && account["trade_pending"] && account["trade_pending"]["stage"] == "applied"
    failed = true
    raise IOError, "injected profile failure after durable receipt"
  end
  original_save.call
end
reject.call("profile failure after atomic receipt reproduced") { sessions[0].confirm(trade) }
transaction_id = service.trades[trade["code"]]["transaction_id"]
assert.call(sessions[0].escrow.nil? && sessions[0].applied.key?(transaction_id), "main save remains committed when later profile write fails")
assert.call(sessions[0].pending["stage"] != "applied", "failed profile write rolls memory journal back to disk version")
received = players[0].party.find { |pokemon| pokemon.personalID / 100 == 802 }
received.snapshot["pokemon"]["name"] = "Trained offline"
players[0].party.last.snapshot["pokemon"]["name"] = "Other solo progress"
KIFMultiplayer::TradeSave.new.persist
import = codec.method(:import)
codec.define_singleton_method(:import) { |_snapshot| raise KIFMultiplayer::Error, "new import unavailable after local data change" }
sessions[0].recover
assert.call(!sessions[0].pending && players[0].party.length == 3, "applied receipt recovery only acks and never reimports or duplicates")
assert.call(players[0].party.include?(received) && received.snapshot["pokemon"]["name"] == "Trained offline", "offline changes to received individual survive ack recovery")
codec.define_singleton_method(:import, import)
use.call(1); sessions[1].recover

# Same-lineage SaveAs is safe only when the new slot already contains the exact
# escrow/marker. Neither missing/new unrelated files nor copied identity IDs
# alone are evidence of a usable original.
use.call(0)
trade = sessions[0].create
sessions[0].offer(trade["code"], players[0].party.first)
old_slot = players[0].save_slot
old_path = SaveData.get_full_path(old_slot)
old_bytes = File.binread(old_path)
players[0].save_slot = "same-lineage-escrow"
reject.call("unsaved SaveAs cannot migrate journal") { sessions[0].recover }
assert.call(sessions[0].pending["save_path"] == File.expand_path(old_path), "failed SaveAs proof leaves original journal path unchanged")
KIFMultiplayer::TradeSave.new.persist
new_path = SaveData.get_full_path(players[0].save_slot)
saved_binding = players[0].instance_variable_get(:@kif_multiplayer_trade_save_id)
players[0].instance_variable_set(:@kif_multiplayer_trade_save_id, "different-lineage")
reject.call("different in-memory save UUID cannot migrate") { sessions[0].recover }
players[0].instance_variable_set(:@kif_multiplayer_trade_save_id, saved_binding)
saved_escrow = players[0].instance_variable_get(:@kif_multiplayer_trade_escrow)
players[0].instance_variable_set(:@kif_multiplayer_trade_escrow, saved_escrow.merge("code" => "OTHER"))
reject.call("other transaction escrow cannot use same UUID") { sessions[0].recover }
players[0].instance_variable_set(:@kif_multiplayer_trade_escrow, saved_escrow)
saved_journal = codec.copy(sessions[0].pending)
sessions[0].pending["player_id"] = "different-owner"
reject.call("other identity cannot migrate SaveAs") { sessions[0].recover }
sessions[0].pending.replace(saved_journal)
sessions[0].pending["server"] = "http://127.0.0.1:9999"
reject.call("other server cannot migrate SaveAs") { sessions[0].recover }
sessions[0].pending.replace(saved_journal)

# The actual durable file, not merely the currently loaded object, is checked.
persisted = SaveData.get_data_from_file(new_path)
persisted[:player].instance_variable_set(:@kif_multiplayer_trade_save_id, "wrong-durable-lineage")
File.binwrite(new_path, Marshal.dump(persisted))
reject.call("same memory UUID with different durable lineage cannot migrate") { sessions[0].recover }
KIFMultiplayer::TradeSave.new.persist
persisted = SaveData.get_data_from_file(new_path)
persisted[:player].instance_variable_get(:@kif_multiplayer_trade_escrow)["entries"].first["pokemon"].snapshot["pokemon"]["name"] = "different durable raw Pokemon"
File.binwrite(new_path, Marshal.dump(persisted))
reject.call("matching UUID and frozen quote cannot hide different durable original object") { sessions[0].recover }
KIFMultiplayer::TradeSave.new.persist
profile.define_singleton_method(:save) { raise IOError, "migration profile write failure" }
reject.call("SaveAs profile migration failure stays locked") { sessions[0].recover }
assert.call(sessions[0].pending["save_path"] == File.expand_path(old_path), "failed journal migration rolls in-memory path back")
profile.define_singleton_method(:save, original_save)
sessions[0].recover
assert.call(sessions[0].pending["save_path"] == File.expand_path(new_path), "durable same-lineage SaveAs migrates only profile path")
assert.call(File.binread(old_path) == old_bytes, "SaveAs recovery never overwrites previous slot")
players[0].party.last.snapshot["pokemon"]["name"] = "New slot progress"
sessions[0].cancel(trade["code"])
assert.call(SaveData.get_data_from_file(new_path)[:player].party.last.snapshot["pokemon"]["name"] == "New slot progress", "cancel preserves newer offline progress in active SaveAs slot")
assert.call(File.binread(old_path) == old_bytes, "cancel after migration leaves old slot untouched")

# Applied marker path also migrates without inspecting the now-trained Pokemon.
trade = sessions[0].create
use.call(1); sessions[1].join(trade["code"])
use.call(0); sessions[0].offer(trade["code"], players[0].party.first)
use.call(1); trade = sessions[1].offer(trade["code"], players[1].party.first); sessions[1].confirm(trade)
use.call(0); clients[0].fail_before_for = "/ack"
reject.call("ack disconnect leaves durable applied marker") { sessions[0].confirm(trade) }
old_path = SaveData.get_full_path(players[0].save_slot)
old_bytes = File.binread(old_path)
players[0].save_slot = "same-lineage-applied"
players[0].party.first.snapshot["pokemon"]["name"] = "Evolved after trade"
KIFMultiplayer::TradeSave.new.persist
codec.define_singleton_method(:import) { |_snapshot| raise KIFMultiplayer::Error, "cannot import after option change" }
sessions[0].recover
assert.call(!sessions[0].pending && players[0].party.length == 3 && players[0].party.first.snapshot["pokemon"]["name"] == "Evolved after trade", "durable applied marker SaveAs supports trained individual and ack only")
assert.call(File.binread(old_path) == old_bytes, "applied SaveAs ack does not touch previous slot")
codec.define_singleton_method(:import, import)
use.call(1); sessions[1].recover

# Profile deletion can fail after a successful ack. Keep the old in-memory
# pointer, then retry only the ack; never create a replacement transaction.
use.call(0)
trade = sessions[0].create
sessions[0].offer(trade["code"], players[0].party.first)
failed = false
profile.define_singleton_method(:save) do
  if !failed && !account["trade_pending"]
    failed = true
    raise IOError, "clear journal write failure"
  end
  original_save.call
end
reject.call("cancel journal cleanup write can fail after safe return") { sessions[0].cancel(trade["code"]) }
assert.call(sessions[0].pending && sessions[0].escrow.nil? && players[0].party.length == 3, "cleanup failure keeps memory lock while exact original is already safe")
sessions[0].recover
assert.call(!sessions[0].pending && players[0].party.length == 3, "cleanup retry clears only journal without duplicate original")
profile.define_singleton_method(:save, original_save)

# A commit that races cancellation is queried and applied, never released.
trade = sessions[0].create
use.call(1); sessions[1].join(trade["code"])
use.call(0); outgoing = players[0].party.first; sessions[0].offer(trade["code"], outgoing)
use.call(1); trade = sessions[1].offer(trade["code"], players[1].party.first)
use.call(0); sessions[0].confirm(trade)
request = service.method(:request)
race = false
service.define_singleton_method(:request) do |owner, method, path, body|
  if !race && method == "POST" && path.end_with?("/cancel")
    race = true
    remote = trades[trade["code"]]
    hashes = remote["offers"].each_with_object({}) { |(id, offer), result| result[id] = offer["hash"] }
    request.call(clients[1].player_id, "POST", "/v1/trades/#{trade['code']}/confirm", { "revision" => remote["revision"], "offer_hashes" => hashes })
    raise KIFMultiplayer::Error.new("commit won cancel race", "trade_closed")
  end
  request.call(owner, method, path, body)
end
result = sessions[0].cancel(trade["code"])
assert.call(result["status"] == "committed" && sessions[0].escrow.nil? && !sessions[0].pending, "cancellation race queries unique committed receipt and finishes")
assert.call(!players[0].party.include?(outgoing) && players[0].party.length == 3, "cancellation race cannot return committed outgoing original")

puts "TRANSACTION_RECOVERY_PASS #{checks} checks #{TRADE_TEST_DIR}"
