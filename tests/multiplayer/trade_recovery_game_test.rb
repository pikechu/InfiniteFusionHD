# Real registered SaveData and Pokemon regression, using an isolated harness.
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  codec = KIFMultiplayer::TradeCodec
  load "tests/multiplayer/trade_game_test.rb"
  KIFMultiplayerTradeGameTest.run(test.method(:log))
  original_trainer = $Trainer
  $Trainer = original_trainer.clone
  $Trainer.party = [Pokemon.new(:BULBASAUR, 23, $Trainer, false, false), Pokemon.new(:CHARMANDER, 23, $Trainer, false, false)]
  pokemon = Pokemon.new(:B1H4, 25, $Trainer, false, false)
  pokemon.moves = [Pokemon::Move.new(:TACKLE)]
  pokemon.instance_variable_set(:@ability2, nil)
  pokemon.instance_variable_set(:@ability2_index, nil)
  $game_switches[SWITCH_DOUBLE_ABILITIES] = true
  snapshot = codec.export(pokemon)
  legacy = codec.copy(snapshot)
  legacy["pokemon"] = KIFMultiplayer::Snapshot.export(pokemon)
  entry = { "pokemon" => pokemon, "snapshot" => legacy, "hash" => codec.digest(legacy), "location" => ["party", 0], "offer_id" => "legacy_offer" }
  test.check(codec.entry_matches?(entry), "old second-ability quote validates against exact trusted original")
  $game_switches[SWITCH_DOUBLE_ABILITIES] = false
  test.check(codec.entry_matches?(entry), "legacy locked quote can recover after offline double-ability toggle")
  test.check(Marshal.load(Marshal.dump(entry))["snapshot"] == legacy, "legacy migration uses durable unmodified quote")

  $Trainer.save_slot = "Trade Recovery Original"
  $Trainer.instance_variable_set(:@kif_multiplayer_trade_save_id, "native_recovery_lineage")
  profile = KIFMultiplayer::Profile.new(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "native-recovery.json"))
  identity = "native_recovery_owner"
  profile.account["identity"] = { "id" => identity }
  client = Object.new
  client.define_singleton_method(:profile) { profile }
  client.define_singleton_method(:server) { profile.server }
  client.define_singleton_method(:player_id) { identity }
  acknowledgements = 0
  client.define_singleton_method(:request) do |method, path, body = {}|
    raise "unexpected network request" unless method == "POST" && path == "/v1/trades/NATIVE01/ack" && body["transaction_id"] == "native_recovery_tx"
    acknowledgements += 1
    {}
  end
  session = KIFMultiplayer::TradeSession.new(client)
  store = session.store
  record = { "code" => "NATIVE01", "server" => client.server, "player_id" => identity,
    "save_path" => File.expand_path(store.path), "save_id" => "native_recovery_lineage", "stage" => "locked" }
  profile.account["trade_pending"] = record.dup
  profile.save
  $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, record.merge("entries" => [entry]))
  store.persist
  original_path = store.path
  original_bytes = File.binread(original_path)
  $Trainer.save_slot = "Trade Recovery SaveAs"
  store.persist
  export = codec.method(:export)
  codec.define_singleton_method(:export) { |_data| raise "SaveAs proof must not depend on current formatter" }
  session.check_binding
  codec.define_singleton_method(:export, export)
  test.check(session.pending["save_path"] == File.expand_path(store.path), "native registered SaveData SaveAs proves exact legacy escrow then migrates journal")
  test.check(File.binread(original_path) == original_bytes, "native escrow SaveAs migration never overwrites old slot")

  received = codec.copy(snapshot)
  transaction_id = "native_recovery_tx"
  marker = { "code" => record["code"], "server" => client.server, "player_id" => identity,
    "offered_hash" => codec.digest(legacy), "received_hash" => codec.digest(received) }
  $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, nil)
  $Trainer.instance_variable_set(:@kif_multiplayer_trade_applied, { transaction_id => marker })
  $Trainer.party.first.name = "Offline Trained"
  $Trainer.save_slot = "Trade Recovery Applied SaveAs"
  store.persist
  session.check_binding
  test.check(session.pending["save_path"] == File.expand_path(store.path), "native applied marker permits durable same-lineage SaveAs")
  party_before = Marshal.dump($Trainer.party)
  receipt = { "source" => "local_casual", "owner_id" => identity, "transaction_id" => transaction_id,
    "received_snapshot" => received, "received_hash" => "remote_received_hash", "offered_hash" => marker["offered_hash"] }
  trade = { "code" => "NATIVE01", "transaction_id" => transaction_id, "receipt" => receipt,
    "offers" => { identity => { "snapshot" => legacy, "hash" => marker["offered_hash"] }, "remote" => { "snapshot" => received, "hash" => "remote_received_hash" } } }
  import = codec.method(:import)
  codec.define_singleton_method(:import) { |_data| raise "applied recovery must not reimport" }
  session.receive(trade)
  codec.define_singleton_method(:import, import)
  test.check(acknowledgements == 1 && !session.pending, "native applied marker completes only original ack")
  test.check(Marshal.dump($Trainer.party) == party_before && $Trainer.party.first.name == "Offline Trained", "native ack preserves trained individual and all party data")
  test.check(File.binread(original_path) == original_bytes, "native final ack leaves source save byte-for-byte unchanged")
  test.log("TRADE_RECOVERY_NATIVE_PASS ruby=#{RUBY_VERSION}")
  exit!(0)
rescue Exception => error
  KIFMultiplayerFeatureTest.log("TRADE_RECOVERY_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join('\n')}") if defined?(KIFMultiplayerFeatureTest)
  exit!(1)
end
