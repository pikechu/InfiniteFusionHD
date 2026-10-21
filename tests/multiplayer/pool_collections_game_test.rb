# Real two-Game.exe integration scenario. No synthetic compatibility or HTTP
# service is used. Called after normal game database/map initialization.
module KIFMultiplayerPoolCollectionsGameTest
  def self.run(log)
    raise "Isolated save directory required" unless ENV["KIF_MULTIPLAYER_SAVE_DIR"] && File.expand_path(System.data_directory) == File.expand_path(ENV["KIF_MULTIPLAYER_SAVE_DIR"])
    require "digest/sha2"
    host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
    role, peer_role = host ? ["host", "guest"] : ["guest", "host"]
    base = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
    own_file, peer_file = base + ".#{role}.json", base + ".#{peer_role}.json"
    own = { "pid" => Process.pid, "role" => role }
    write = lambda do |values|
      own.merge!(values)
      temporary = own_file + ".tmp"
      File.open(temporary, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump(own)); file.flush; file.fsync }
      File.rename(temporary, own_file)
    end
    read_peer = lambda { File.file?(peer_file) ? KIFMultiplayer::WireJSON.parse(File.binread(peer_file)) : {} }
    wait = lambda do |key|
      deadline = KIFMultiplayer.monotonic + 180
      loop do
        peer = read_peer.call
        break peer if peer[key]
        raise "Peer #{peer_role} did not reach #{key}" if KIFMultiplayer.monotonic >= deadline
        KIFMultiplayer.pump
      end
    end
    checks = 0
    assert = lambda do |condition, message|
      raise "POOL_COLLECTIONS_GAME_FAIL #{message}" unless condition
      checks += 1
      log.call("POOL_COLLECTIONS_GAME_PASS #{message}")
    end
    client = KIFMultiplayer::Client.new
    client.connect(host ? "Pool Native Host" : "Pool Native Guest")
    compatibility = client.compatibility
    log.call("VERIFIED_BUILD player=#{client.player_id} compatibility=#{KIFMultiplayer::WireJSON.dump(compatibility)}")
    $Trainer.save_slot = "Pool Native Test"
    $Trainer.party = (host ? [:BULBASAUR, :CHARMANDER, :SQUIRTLE] : [:PIKACHU, :EEVEE, :SANDSHREW]).map.with_index do |species, index|
      pokemon = Pokemon.new(species, 23 + index, $Trainer, false, false)
      pokemon.name = "#{role} #{index + 1}"
      pokemon.moves = [Pokemon::Move.new(:TACKLE), Pokemon::Move.new(:TOXIC)]
      pokemon.moves[0].ppup = 2
      pokemon.moves[0].pp = 3
      pokemon.nature = :HARDY
      pokemon.item = :LEFTOVERS
      pokemon.shiny = index == 0
      pokemon.hp = [pokemon.totalhp / 2, 1].max
      pokemon
    end
    source = $Trainer.party.first
    source_snapshot = KIFMultiplayer::TradeCodec.export(source)
    untouched = $Trainer.party.drop(1).map { |pokemon| Marshal.dump(pokemon) }
    pool = KIFMultiplayer::PoolSession.new(client)
    write.call("player_id" => client.player_id, "local_snapshot" => source_snapshot)
    if host
      deposit = pool.deposit(source)
      assert.call(deposit["status"] == "waiting" && pool.pending, "host local original locked before remote matching")
      write.call("local_deposit_id" => deposit["deposit_id"])
      peer = wait.call("local_received")
      pool.recover
    else
      peer = wait.call("local_deposit_id")
      deposit = pool.deposit(source)
      assert.call(deposit["receipt"] && deposit["receipt"]["kind"] == "exchange", "guest local deposit matches real remote identity")
    end
    peer = read_peer.call
    received = $Trainer.party.find { |pokemon| KIFMultiplayer::TradeCodec.export(pokemon) == peer["local_snapshot"] }
    assert.call(!!received && !pool.pending && pool.escrow.nil?, "received exact remote individual with durable application and ack")
    assert.call(!$Trainer.party.any? { |pokemon| KIFMultiplayer::TradeCodec.export(pokemon) == source_snapshot }, "outgoing local individual removed once")
    assert.call(untouched.all? { |bytes| $Trainer.party.any? { |pokemon| Marshal.dump(pokemon) == bytes } }, "unoffered original individuals unchanged")
    saved = SaveData.get_data_from_file(SaveData.get_full_path($Trainer.save_slot))
    saved_player = saved[:kuray_player] || saved[:player]
    assert.call(saved_player.party.any? { |pokemon| KIFMultiplayer::TradeCodec.export(pokemon) == peer["local_snapshot"] }, "received remote individual verified by rereading real disk save")
    write.call("local_received" => true)
    if host
      returned = $Trainer.party.first
      pool.deposit(returned)
      result = pool.withdraw
      assert.call(result["receipt"]["kind"] == "return" && $Trainer.party.include?(returned), "unmatched real HTTP withdrawal restores exact original object")
      write.call("withdraw_done" => true)
    else
      wait.call("withdraw_done")
    end
    party_before_hosted = Digest::SHA256.hexdigest(Marshal.dump([$Trainer, $PokemonStorage]))
    collection = KIFMultiplayer::CollectionClient.new(client)
    asset = collection.starter.first
    assert.call(asset && asset["source"] == "server_catalog" && asset["owner_id"] == client.player_id, "server starter has authoritative source and owner")
    assert.call(collection.starter.length == 1, "repeated real starter request grants once")
    showcase = collection.publish(asset["id"])["showcase"]
    assert.call(showcase && showcase["source"] == "server_managed", "hosted showcase published from authoritative server snapshot")
    write.call("asset_id" => asset["id"])
    trades = KIFMultiplayer::ManagedTradeSession.new(client)
    if host
      trade = trades.create
      write.call("managed_trade_code" => trade["code"])
      wait.call("managed_offer_ready")
      trade = trades.offer(trade["code"], asset["id"])
      trades.confirm(trade)
      write.call("host_confirmed" => true)
      wait.call("managed_committed")
      trades.recover
      write.call("managed_host_acked" => true)
    else
      peer = wait.call("managed_trade_code")
      trade = trades.join(peer["managed_trade_code"])
      trades.offer(trade["code"], asset["id"])
      write.call("managed_offer_ready" => true)
      wait.call("host_confirmed")
      trade = trades.get(trade["code"])
      result = trades.confirm(trade)
      assert.call(%w[committed completed].include?(result["status"]), "second real hosted confirmation commits one ownership swap")
      write.call("managed_committed" => true)
      wait.call("managed_host_acked")
    end
    peer = read_peer.call
    received_asset = collection.refresh.first
    assert.call(received_asset["id"] == peer["asset_id"] && received_asset["owner_id"] == client.player_id, "real hosted friend swap changes unique server owner")
    assert.call(Digest::SHA256.hexdigest(Marshal.dump([$Trainer, $PokemonStorage])) == party_before_hosted, "hosted grant showcase and friend swap never modify main save objects")
    managed_pool = KIFMultiplayer::ManagedPoolSession.new(client)
    if host
      deposit = managed_pool.deposit(received_asset["id"])
      assert.call(deposit["status"] == "waiting", "server-managed pool waits in separate source zone")
      write.call("managed_pool_id" => deposit["deposit_id"])
      wait.call("managed_pool_received")
      managed_pool.recover
    else
      wait.call("managed_pool_id")
      deposit = managed_pool.deposit(received_asset["id"])
      assert.call(deposit["receipt"] && deposit["receipt"]["kind"] == "exchange", "server-managed pool matches authoritative assets")
      write.call("managed_pool_received" => true)
    end
    final_assets = collection.refresh
    assert.call(final_assets.length == 1 && final_assets[0]["id"] == asset["id"], "second hosted swap returns sole original asset without minting")
    assert.call(!managed_pool.deposit_id && !trades.code, "both hosted transactions finish and release local metadata locks")
    assert.call(Digest::SHA256.hexdigest(Marshal.dump([$Trainer, $PokemonStorage])) == party_before_hosted, "server-managed pool leaves party storage and saved local transaction markers unchanged")
    write.call("finished" => true, "checks" => checks, "final_asset_id" => final_assets[0]["id"])
    log.call("POOL_COLLECTIONS_GAME_TEST_PASS checks=#{checks} role=#{role} player=#{client.player_id}")
    checks
  end
end
