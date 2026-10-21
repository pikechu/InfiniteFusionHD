# Called after the real game scripts, database, trainer and map are initialized.
# Every object created here is test-only; no party or storage slot is replaced.
module KIFMultiplayerClientGameTest
  def self.run(log)
    checks = 0
    assert = lambda do |condition, description|
      raise "CLIENT_GAME_TEST_FAIL #{description}" unless condition
      checks += 1
      log.call("CLIENT_GAME_PASS #{description}")
    end
    original = Pokemon.new(:BULBASAUR, 23, $Trainer, false, false)
    original.name = "Codec Test"
    original.moves = [Pokemon::Move.new(:TACKLE), Pokemon::Move.new(:TOXIC)]
    original.moves[0].ppup = 3
    original.moves[0].pp = 1
    original.item = :LEFTOVERS
    original.nature = :HARDY
    original.nature_for_stats = :MODEST
    original.hiddenPowerType = :FIRE
    original.iv[:HP] = 31
    original.ivMaxed[:HP] = true
    original.shiny = true
    original.head_shiny = true
    original.body_shiny = true
    original.head_shinyhue = 137
    original.head_nickname = "Private Head"
    original.shinyKRS = [0, 1, 2, 0, 1, 2, 0, 1, 2]
    original.size_category = :AVERAGE
    original.sprite_scale = 1.25
    original.hp = [original.totalhp / 2, 1].max
    before = Marshal.dump(original) # Trusted local object, never wire input.
    snapshot = KIFMultiplayer::Snapshot.export(original)
    assert.call(Marshal.dump(original) == before, "snapshot export preserves real original Pokemon including lazy attributes")
    assert.call(snapshot["appearance"]["head_shinyhue"] == 137 && snapshot["appearance"]["size_category"] == "AVERAGE", "real custom shiny hue and symbolic body size encoded")
    assert.call(snapshot["iv_maxed"]["HP"] == true && snapshot["nature_for_stats"] == "MODEST" && snapshot["hidden_power_type"] == "FIRE", "hyper training mint nature and hidden power preserved")
    wire = KIFMultiplayer::WireJSON.dump(snapshot)
    imported = KIFMultiplayer::Snapshot.import(KIFMultiplayer::WireJSON.parse(wire))
    assert.call(imported != original && imported.level == 50 && imported.hp == imported.totalhp, "real temporary Pokemon normalized to level 50 and healed")
    assert.call(imported.moves[0].pp == imported.moves[0].total_pp && imported.moves[0].ppup == 3, "temporary moves restore PP and preserve PP Ups")
    assert.call(imported.species == original.species && imported.personalID == original.personalID && imported.owner.id == original.owner.id, "real species personal id and original trainer round trip")
    assert.call(imported.item_id == :LEFTOVERS && imported.nature_for_stats_id == :MODEST && imported.ivMaxed[:HP], "battle item mint and hyper training round trip")
    assert.call(imported.head_shinyhue == 137 && imported.sprite_scale == 1.25 && imported.size_category == :AVERAGE, "real custom appearance round trip")
    assert.call(Marshal.dump(original) == before, "temporary import leaves original HP PP level item and individual values untouched")
    imported.iv[:HP] = 0
    imported.moves[0].pp = 0
    imported.shinyKRS[0] = 99
    assert.call(original.iv[:HP] == 31 && original.moves[0].pp == 1 && original.shinyKRS[0] == 0, "imported IV move and appearance arrays do not alias source")
    public_data = KIFMultiplayer::Snapshot.public_snapshot(snapshot)
    assert.call(!public_data.key?("name") && !public_data.key?("owner") && !public_data["appearance"].key?("head_nickname"), "real showcase default privacy projection")
    assert.call(public_data["appearance"]["head_shinyhue"] == 137, "showcase retains supported shiny color")
    begin
      KIFMultiplayer::Snapshot.validate(snapshot.merge("species" => "UNKNOWN_SPECIES_MUST_NOT_FALLBACK"))
      raise "Unsupported species fell back silently"
    rescue KIFMultiplayer::Error => error
      assert.call(error.code == "invalid_pokemon", "real permissive Species.get fallback is blocked")
    end
    fusion = Pokemon.new(:B1H4, 25, $Trainer, true, false)
    fusion_before = Marshal.dump(fusion)
    fusion_snapshot = KIFMultiplayer::Snapshot.export(fusion)
    fusion_imported = KIFMultiplayer::Snapshot.import(fusion_snapshot)
    assert.call(fusion_imported.species == :B1H4 && fusion_imported.level == 50, "real fused species snapshot creates battle-ready temporary fusion")
    assert.call(Marshal.dump(fusion) == fusion_before, "fusion snapshot preserves source lazy data")
    client = KIFMultiplayer::Client.new
    compatibility = client.compatibility
    assert.call(compatibility["protocol"] == KIFMultiplayer::PROTOCOL && compatibility["rules_version"] == KIFMultiplayer::RULES_VERSION, "real code and data manifest fully verified before room compatibility")
    log.call("CLIENT_GAME_TEST_PASS checks=#{checks} ruby=#{RUBY_VERSION}")
    checks
  end
end
