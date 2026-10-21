# Called by the real initialized Game.exe harness, never against a player save.
module KIFMultiplayerTradeGameTest
  def self.run(log)
    test_directory = ENV["KIF_MULTIPLAYER_SAVE_DIR"]
    raise "Trade native test requires an isolated test save directory" unless test_directory && File.directory?(test_directory)
    expected_directory = File.expand_path(test_directory).tr("\\", "/").sub(/\/+\z/, "")
    actual_directory = File.expand_path(System.data_directory).tr("\\", "/").sub(/\/+\z/, "")
    raise "Trade test isolation is not active" unless expected_directory == actual_directory
    checks = 0
    assert = lambda do |condition, description|
      raise "TRADE_GAME_TEST_FAIL #{description}" unless condition
      checks += 1
      log.call("TRADE_GAME_PASS #{description}")
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
    codec = KIFMultiplayer::TradeCodec
    pokemon = Pokemon.new(:BULBASAUR, 23, $Trainer, false, false)
    pokemon.name = "Trade Codec"
    pokemon.moves = [Pokemon::Move.new(:TACKLE), Pokemon::Move.new(:TOXIC)]
    pokemon.moves[0].ppup = 3
    pokemon.moves[0].pp = 1
    pokemon.moves[1].pp = 2
    pokemon.item = :LEFTOVERS
    pokemon.nature = :HARDY
    pokemon.nature_for_stats = :MODEST
    pokemon.hiddenPowerType = :FIRE
    pokemon.personalID = 0xffffffff
    pokemon.first_moves = [:TOXIC, :TACKLE]
    pokemon.owner = Pokemon::Owner.new(0xfffffffe, "Trade Original OT", 1, 2)
    pokemon.exp = pokemon.exp + 17
    pokemon.shiny = true
    pokemon.head_shiny = true
    pokemon.body_shiny = true
    pokemon.shinyKRS = [0, 1, 2, 0, 1, 2, 0, 1, 2]
    pokemon.head_shinyhue = 137
    pokemon.body_shinyhue = -92
    pokemon.head_nickname = "Head Nickname"
    pokemon.size_category = :AVERAGE
    pokemon.sprite_scale = 1.25
    pokemon.ivMaxed[:HP] = true
    pokemon.ev[:ATTACK] = 252
    pokemon.glitter = true
    pokemon.imported = true
    pokemon.force_disobey = true
    pokemon.obtain_text = "独立交换测试"
    pokemon.obtain_level = 7
    pokemon.cool, pokemon.beauty, pokemon.cute = 11, 22, 33
    pokemon.smart, pokemon.tough, pokemon.sheen = 44, 55, 66
    pokemon.pokerus = 17
    pokemon.markings = 31
    pokemon.kuray_no_evo = 1
    pokemon.exp_when_fused_head, pokemon.exp_when_fused_body, pokemon.exp_gained_since_fused = 12_345, 23_456, 789
    pokemon.body_original_ability_index, pokemon.head_original_ability_index = 0, 2
    pokemon.instance_variable_set(:@timeReceived, 0xffffffff)
    pokemon.instance_variable_set(:@timeEggHatched, 1_600_000_000)
    pokemon.instance_variable_set(:@time_form_set, 1_700_000_000)
    pokemon.instance_variable_set(:@ability2, :LEVITATE)
    pokemon.instance_variable_set(:@ability2_index, 2)
    pokemon.instance_variable_set(:@status, :POISON)
    pokemon.statusCount = 2
    pokemon.calc_stats
    pokemon.hp = [pokemon.totalhp / 2, 1].max
    before = Marshal.dump(pokemon)
    snapshot = codec.export(pokemon)
    assert.call(Marshal.dump(pokemon) == before, "export does not mutate real original or lazy fields")
    imported = codec.import(KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(snapshot)))
    assert.call(codec.export(imported) == snapshot, "real full Pokemon trade snapshot round trips losslessly")
    assert.call(imported.exp == pokemon.exp && imported.level == pokemon.level, "exact experience and original level preserved")
    assert.call(imported.hp == pokemon.hp && imported.status == :POISON && imported.statusCount == 2, "current HP poison and toxic count preserved")
    assert.call(imported.moves.map(&:pp) == [1, 2] && imported.moves[0].ppup == 3, "depleted PP and PP Ups preserved without healing")
    assert.call(imported.instance_variable_get(:@ability2) == :LEVITATE && imported.instance_variable_get(:@ability2_index) == 2, "stored second ability preserved independently of local double-ability option")
    assert.call(imported.personalID == 0xffffffff && imported.owner.id == 0xfffffffe && imported.owner.name == "Trade Original OT", "unsigned identity and original trainer preserved")
    assert.call(imported.nature_for_stats_id == :MODEST && imported.ivMaxed[:HP] && imported.ev[:ATTACK] == 252, "mint hyper training IV EV preserved")
    assert.call(imported.item_id == :LEFTOVERS && imported.hiddenPowerType == :FIRE, "held item and hidden power type preserved")
    assert.call(imported.head_shinyhue == 137 && imported.body_shinyhue == -92 && imported.head_nickname == "Head Nickname", "fusion shiny colors and head nickname preserved")
    assert.call(imported.sprite_scale == 1.25 && imported.size_category == :AVERAGE && imported.glitter, "supported size and glitter preserved")
    codec::FIELDS.each do |field|
      assert.call(codec.export(imported)["preserved"][field] == snapshot["preserved"][field], "preserved individual field #{field}")
    end
    imported.moves[0].pp = 0
    imported.iv[:HP] = 0
    imported.shinyKRS[0] = 2
    assert.call(Marshal.dump(pokemon) == before, "received move IV and appearance arrays do not alias source")
    broken = pokemon.clone
    broken.kuraycustomfile = "Graphics/CustomBattlers/private.png"
    reject.call("custom local image paths explicitly refused before trade") { codec.export(broken) }
    broken = pokemon.clone
    broken.instance_variable_set(:@unadapted_identity_field, "must not disappear")
    reject.call("unknown individual identity fields refused") { codec.export(broken) }
    broken = pokemon.clone
    broken.hat = "hat.png"
    reject.call("unsupported hat explicitly refused") { codec.export(broken) }
    broken = codec.copy(snapshot)
    broken["pokemon"]["moves"][0]["pp"] = 99
    reject.call("PP outside local move maximum refused before confirmation") { codec.import(broken) }
    broken = codec.copy(snapshot)
    broken["preserved"]["exp"] = 1
    reject.call("experience and declared level mismatch refused") { codec.import(broken) }
    fusion = Pokemon.new(:B1H4, 25, $Trainer, true, false)
    fusion_snapshot = codec.export(fusion)
    assert.call(codec.export(codec.import(fusion_snapshot)) == fusion_snapshot, "real fusion receives exact supported genetics and appearance")

    # Exercise the actual registered SaveData serialization and atomic replace,
    # including this game's :player/:kuray_player compatibility save values.
    original_trainer = $Trainer
    begin
      $Trainer = original_trainer.clone
      $Trainer.party = [pokemon]
      $Trainer.save_slot = "Trade Codec Test"
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_save_id, "native_codec_save")
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, { "entries" => [{ "pokemon" => pokemon, "snapshot" => snapshot }] })
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_applied, { "native_tx" => { "received_hash" => codec.digest(snapshot) } })
      store = KIFMultiplayer::TradeSave.new
      store.persist
      first_bytes = File.binread(store.path)
      stored = SaveData.get_data_from_file(store.path)
      saved_player = stored[:kuray_player] || stored[:player]
      assert.call(saved_player.instance_variable_get(:@kif_multiplayer_trade_escrow)["entries"].first["snapshot"] == snapshot, "real full save preserves original escrow and fixed snapshot")
      assert.call(saved_player.instance_variable_get(:@kif_multiplayer_trade_applied).key?("native_tx"), "real full save preserves transaction application marker")
      assert.call(stored.key?(:player) && stored.key?(:kuray_player) && stored.key?(:storage_system) && stored.key?(:kuray_storage_system), "atomic save retains registered vanilla and modded save values")
      $Trainer.party = [codec.import(snapshot)]
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, nil)
      store.persist
      second_bytes = File.binread(store.path)
      stored = SaveData.get_data_from_file(store.path)
      saved_player = stored[:kuray_player] || stored[:player]
      assert.call(first_bytes != second_bytes && saved_player.instance_variable_get(:@kif_multiplayer_trade_escrow).nil?, "Windows runtime atomically replaces an existing save file")
      assert.call(codec.export(saved_player.party.first) == snapshot && saved_player.instance_variable_get(:@kif_multiplayer_trade_applied).key?("native_tx"), "received individual and applied marker are durable together")
      assert.call(Dir.glob(store.path + ".mp-trade-*.tmp").empty?, "native atomic save leaves no unfinished temporary file")
    ensure
      $Trainer = original_trainer
    end
    log.call("TRADE_GAME_TEST_PASS checks=#{checks} ruby=#{RUBY_VERSION}")
    checks
  end
end
