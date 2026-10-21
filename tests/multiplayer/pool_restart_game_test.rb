# Real process crash after durable receipt save, followed by a second Game.exe
# using the same isolated profile/save. The transport fault is test-only.
module KIFMultiplayerPoolRestartGameTest
  def self.prepare_restart(log)
    return false if ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
    state_path = ENV.fetch("KIF_MULTIPLAYER_SCENARIO") + ".guest.json"
    state = File.file?(state_path) ? KIFMultiplayer::WireJSON.parse(File.binread(state_path)) : {}
    return false unless state["crash_after_save"]
    # Match the real game: load the ordinary save BEFORE opening multiplayer's
    # display scope. Save conversions/load_from legitimately read option getters.
    save_path = SaveData.get_full_path("Pool Restart Test")
    expected_prefix = File.expand_path(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")).tr("\\", "/") + "/"
    raise "Restart test path escaped isolation" unless File.expand_path(save_path).tr("\\", "/").start_with?(expected_prefix)
    disk = SaveData.read_from_file(save_path)
    # This diagnostic bootstrap already created a throwaway new game. A real
    # fresh process has not loaded even the bootup-only options yet. Reset ALL
    # registration loaded flags in this test, then use the genuine two stages.
    SaveData.instance_variable_get(:@values).each(&:mark_as_unloaded)
    SaveData.load_bootup_values(disk)
    SaveData.load_all_values(disk)
    unless $PokemonSystem.download_sprites == 0 && $PokemonSystem.shinyadvanced == 1
      raise "Ordinary restart load changed persisted system options"
    end
    @restart_preloaded = true
    log.call("POOL_RESTART_PRELOADED_BEFORE_UI pid=#{Process.pid} options=0/1")
    true
  end
  def self.run(log)
    require "digest/sha2"
    isolated = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
    raise "Pool restart requires the isolated test save directory" unless File.expand_path(System.data_directory) == File.expand_path(isolated)
    host = ENV.fetch("KIF_MULTIPLAYER_PROFILE").include?("host")
    role, other = host ? ["host", "guest"] : ["guest", "host"]
    scenario = ENV.fetch("KIF_MULTIPLAYER_SCENARIO")
    own_path, peer_path = scenario + ".#{role}.json", scenario + ".#{other}.json"
    own = File.file?(own_path) ? KIFMultiplayer::WireJSON.parse(File.binread(own_path)) : {}
    write = lambda do |fields|
      own.merge!(fields)
      File.open(own_path + ".tmp", "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump(own)); file.flush; file.fsync }
      File.rename(own_path + ".tmp", own_path)
    end
    wait = lambda do |key|
      deadline = KIFMultiplayer.monotonic + 180
      loop do
        data = File.file?(peer_path) ? KIFMultiplayer::WireJSON.parse(File.binread(peer_path)) : {}
        break data if data[key]
        raise "Timeout waiting for #{other} #{key}" if KIFMultiplayer.monotonic >= deadline
        KIFMultiplayer.pump
      end
    end
    checks = 0
    assert = lambda { |ok, message| raise("POOL_RESTART_FAIL #{message}") unless ok; checks += 1; log.call("POOL_RESTART_PASS #{message}") }
    saved_options = lambda do |disk|
      system = disk[:kuray_pokemon_system_file] || disk[:pokemon_system]
      system && system.instance_variable_get(:@download_sprites) == 0 && system.instance_variable_get(:@shinyadvanced) == 1
    end
    # Diagnose bounded waits without widening them or changing production
    # behavior. Each wrapper calls the actual implementation exactly once.
    phase, phase_started, diagnostics_done = "setup", KIFMultiplayer.monotonic, false
    timed = lambda do |name, &action|
      previous = phase
      phase, phase_started = name, KIFMultiplayer.monotonic
      log.call("POOL_RESTART_STAGE_BEGIN #{name}")
      begin
        action.call
      ensure
        log.call("POOL_RESTART_STAGE_END #{name} elapsed=#{(KIFMultiplayer.monotonic - phase_started).round(3)}")
        phase, phase_started = previous, KIFMultiplayer.monotonic
      end
    end
    client_timing = Module.new do
      define_method(:compatibility) { timed.call("Client.compatibility") { super() } }
    end
    save_timing = Module.new do
      define_method(:persist) { timed.call("TradeSave.persist") { super() } }
    end
    codec_timing = Module.new do
      define_method(:export) { |pokemon| timed.call("TradeCodec.export") { super(pokemon) } }
      define_method(:import) { |snapshot| timed.call("TradeCodec.import") { super(snapshot) } }
    end
    KIFMultiplayer::Client.prepend(client_timing)
    KIFMultiplayer::TradeSave.prepend(save_timing)
    KIFMultiplayer::TradeCodec.singleton_class.prepend(codec_timing)
    watchdog = Thread.new do
      loop do
        sleep 15
        break if diagnostics_done
        if KIFMultiplayer.monotonic - phase_started >= 45
          workers = KIFMultiplayer.respond_to?(:network_workers) ? KIFMultiplayer.network_workers.map { |worker| worker.status } : []
          log.call("POOL_RESTART_DIAGNOSTIC phase=#{phase} seconds=#{(KIFMultiplayer.monotonic - phase_started).round(1)} worker_status=#{workers.inspect} main_stack=#{Thread.main.backtrace.take(8).join(' | ')}")
        end
      end
    end
    $Trainer.save_slot = "Pool Restart Test"
    if !host && own["crash_after_save"]
      save_path = SaveData.get_full_path("Pool Restart Test")
      expected_prefix = File.expand_path(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")).tr("\\", "/") + "/"
      raise "Restart test path escaped isolation" unless File.expand_path(save_path).tr("\\", "/").start_with?(expected_prefix)
      raise "Restart save must load before the multiplayer UI scope" unless @restart_preloaded
      disk = SaveData.get_data_from_file(save_path)
      assert.call(saved_options.call(disk), "pre-restart durable save retains original UI options rather than temporary display values")
      count_before = $Trainer.party.length
      marker_before = $Trainer.instance_variable_get(:@kif_multiplayer_trade_applied)
      party_before = Digest::SHA256.hexdigest(Marshal.dump($Trainer.party))
      markers_before = Marshal.dump(marker_before)
      assert.call(marker_before && marker_before.key?(own["transaction_id"]), "restarted actual Game.exe reads durable transaction marker")
      client = KIFMultiplayer::Client.new
      client.connect("Pool Restart Guest")
      compatibility = client.compatibility
      assert.call(client.transport.backend == :core_socket, "restarted client uses production safe Socket transport")
      pool = KIFMultiplayer::PoolSession.new(client)
      pool.recover
      host_state = wait.call("deposit_id")
      assert.call($Trainer.party.length == count_before && count_before == 3, "process restart does not duplicate received individual")
      assert.call($Trainer.party.any? { |pokemon| KIFMultiplayer::TradeCodec.export(pokemon) == host_state["snapshot"] }, "restarted real save retains exact received remote Pokemon")
      assert.call(!pool.pending && pool.escrow.nil? && pool.applied.length == 1, "restart acks original transaction and retains one application")
      assert.call(Process.pid != own["first_pid"], "recovery runs in a distinct Game.exe process")
      assert.call(Digest::SHA256.hexdigest(Marshal.dump($Trainer.party)) == party_before && Marshal.dump(pool.applied) == markers_before, "restart only acknowledges without changing received party or application markers")
      assert.call(!client.profile.account["pending"], "restart clears generic uncertain acknowledgement journal")
      write.call("restart_done" => true, "restarted_pid" => Process.pid, "finished" => true, "checks" => checks,
        "player_id" => client.player_id, "party_count" => $Trainer.party.length, "marker_count" => pool.applied.length,
        "pending" => !!pool.pending, "escrow" => !!pool.escrow, "backend" => client.transport.backend.to_s,
        "data_hash" => compatibility["data_hash"], "party_unchanged_during_recovery" => true, "saved_ui_options_preserved" => true)
      log.call("POOL_RESTART_GAME_TEST_PASS role=guest first_pid=#{own['first_pid']} restarted_pid=#{Process.pid} tx=#{own['transaction_id']}")
      diagnostics_done = true
      return
    end
    $Trainer.party = (host ? [:BULBASAUR, :CHARMANDER, :SQUIRTLE] : [:PIKACHU, :EEVEE, :SANDSHREW]).map.with_index do |species, index|
      pokemon = Pokemon.new(species, 25 + index, $Trainer, false, false)
      pokemon.name = "Restart #{role} #{index}"
      pokemon.moves = [Pokemon::Move.new(:TACKLE), Pokemon::Move.new(:TOXIC)]
      pokemon.moves[0].ppup = 1
      pokemon.moves[0].pp = 2
      pokemon.nature = :HARDY
      pokemon.item = :LEFTOVERS
      pokemon
    end
    source = $Trainer.party.first
    snapshot = KIFMultiplayer::TradeCodec.export(source)
    client = KIFMultiplayer::Client.new
    client.connect(host ? "Pool Restart Host" : "Pool Restart Guest")
    compatibility = client.compatibility
    assert.call(client.transport.backend == :core_socket, "actual client uses production safe Socket transport")
    if host
      pool = KIFMultiplayer::PoolSession.new(client)
      deposit = pool.deposit(source)
      write.call("deposit_id" => deposit["deposit_id"], "snapshot" => snapshot, "first_pid" => Process.pid)
      peer = wait.call("restart_done")
      result = pool.recover
      assert.call(result["transaction_id"] == peer["transaction_id"], "both actual clients recover the same committed pool transaction")
      assert.call($Trainer.party.any? { |pokemon| KIFMultiplayer::TradeCodec.export(pokemon) == peer["snapshot"] }, "host receives restarted peer original exactly once")
      assert.call($Trainer.party.length == 3 && pool.applied.length == 1 && !pool.pending, "host final state contains one durable received individual")
      assert.call(saved_options.call(SaveData.get_data_from_file(SaveData.get_full_path($Trainer.save_slot))), "host atomic receipt save preserves ordinary system options inside real UI scope")
      write.call("finished" => true, "checks" => checks, "transaction_id" => result["transaction_id"],
        "player_id" => client.player_id, "party_count" => $Trainer.party.length, "marker_count" => pool.applied.length,
        "pending" => !!pool.pending, "escrow" => !!pool.escrow, "backend" => client.transport.backend.to_s,
        "data_hash" => compatibility["data_hash"], "saved_ui_options_preserved" => true)
      log.call("POOL_RESTART_GAME_TEST_PASS role=host pid=#{Process.pid} tx=#{result['transaction_id']}")
    else
      wait.call("deposit_id")
      base_transport = client.transport
      fault_transport = Object.new
      fault_transport.define_singleton_method(:call) do |method, url, body, token, timeout|
        raise IOError, "test disconnect before pool acknowledgement" if method == "POST" && url.end_with?("/ack")
        base_transport.call(method, url, body, token, timeout)
      end
      client = KIFMultiplayer::Client.new(client.profile, fault_transport)
      pool = KIFMultiplayer::PoolSession.new(client)
      begin
        pool.deposit(source)
        raise "Expected the post-save acknowledgement fault"
      rescue KIFMultiplayer::UncertainRequest
        assert.call(pool.pending && pool.pending["stage"] == "applied" && pool.escrow.nil?, "real receipt is saved before interrupted acknowledgement")
        transaction_id = pool.applied.keys.first
        disk = SaveData.get_data_from_file(SaveData.get_full_path($Trainer.save_slot))
        disk_player = disk[:kuray_player] || disk[:player]
        assert.call(disk_player.instance_variable_get(:@kif_multiplayer_trade_applied).key?(transaction_id), "pre-crash real disk save contains application marker")
        assert.call(saved_options.call(disk), "pre-crash atomic save inside UI scope preserves original system options")
        write.call("crash_after_save" => true, "first_pid" => Process.pid, "snapshot" => snapshot, "transaction_id" => transaction_id,
          "pre_crash_checks" => checks, "player_id" => client.player_id)
        log.call("POOL_RESTART_REQUIRED first_pid=#{Process.pid} tx=#{transaction_id}")
        exit!(1) # This deliberate interruption is the one expected nonzero exit.
      end
    end
    diagnostics_done = true
  end
end
