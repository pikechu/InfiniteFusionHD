# Standalone native probe: no account, server, or player's save is loaded.
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  pokemon = Pokemon.new(:B1H4, 25, $Trainer, false, false)
  pokemon.moves = [Pokemon::Move.new(:TACKLE)]
  pokemon.personalID = 1
  pokemon.instance_variable_set(:@ability, nil)
  pokemon.instance_variable_set(:@ability_index, 1)
  pokemon.instance_variable_set(:@ability2, nil)
  pokemon.instance_variable_set(:@ability2_index, nil)
  before = Marshal.dump(pokemon)
  $game_switches[SWITCH_DOUBLE_ABILITIES] = false
  disabled = KIFMultiplayer::TradeCodec.export(pokemon)
  $game_switches[SWITCH_DOUBLE_ABILITIES] = true
  enabled = KIFMultiplayer::TradeCodec.export(pokemon)
  test.log("DOUBLE_ABILITY_PROBE disabled=#{disabled['pokemon']['ability2'].inspect}/#{disabled['pokemon']['ability2_index'].inspect} enabled=#{enabled['pokemon']['ability2'].inspect}/#{enabled['pokemon']['ability2_index'].inspect} original_unchanged=#{Marshal.dump(pokemon) == before}")
  test.check(disabled == enabled, "trade snapshot is independent of offline double-ability option")
  test.check(KIFMultiplayer::TradeCodec.export(KIFMultiplayer::TradeCodec.import(disabled)) == disabled, "snapshot created with option disabled imports after option enabled")
  legacy = KIFMultiplayer::TradeCodec.copy(disabled)
  legacy["pokemon"] = KIFMultiplayer::Snapshot.export(pokemon)
  entry = { "pokemon" => pokemon, "snapshot" => legacy }
  test.check(legacy["pokemon"]["ability2"] && KIFMultiplayer::TradeCodec.entry_matches?(entry), "trusted legacy lazy second-ability quote remains recoverable")
  test.check(!KIFMultiplayer::TradeCodec.entry_matches?(entry.merge("codec_version" => 2)), "new codec entries cannot use legacy formatter allowance")
  legacy["pokemon"]["name"] = "Different individual"
  test.check(!KIFMultiplayer::TradeCodec.entry_matches?(entry), "legacy formatter migration still rejects changed individual fields")
  $game_switches[SWITCH_NO_LEVELS_MODE] = false
  normal = KIFMultiplayer::TradeCodec.export(pokemon)
  $game_switches[SWITCH_NO_LEVELS_MODE] = true
  no_levels = KIFMultiplayer::TradeCodec.export(pokemon)
  test.check(normal == no_levels && Marshal.dump(pokemon) == before, "primary lazy ability and original are independent of offline no-level option")
  legacy = KIFMultiplayer::TradeCodec.copy(normal)
  legacy["pokemon"] = KIFMultiplayer::Snapshot.export(pokemon)
  entry = { "pokemon" => pokemon, "snapshot" => legacy }
  test.check(legacy["pokemon"]["ability"] != normal["pokemon"]["ability"] && KIFMultiplayer::TradeCodec.entry_matches?(entry), "trusted legacy no-level primary and lazy second quote remains recoverable")
  test.check(!KIFMultiplayer::TradeCodec.entry_matches?(entry.merge("codec_version" => 2)), "new entries refuse alternate legacy no-level primary")
  test.log("TRADE_OPTION_NATIVE_PASS")
  exit!(0)
rescue Exception => error
  KIFMultiplayerFeatureTest.log("TRADE_OPTION_NATIVE_FAIL #{error.class}: #{error.message}") if defined?(KIFMultiplayerFeatureTest)
  exit!(1)
end
