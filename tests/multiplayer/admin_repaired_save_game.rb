begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  success = false
  path = ENV.fetch("KIF_ADMIN_REPAIRED_FIXTURE")
  document = KIFMultiplayer::WireJSON.parse(File.binread(path))
  data = KIFMultiplayer::CloudCodec.unpack(document)
  active = data[:kuray_player] || data[:player]
  test.check(active.is_a?(Player) && active.money == 123456, "ADMIN_REPAIRED_ACTIVE_PLAYER_MONEY")
  test.check(data[:player].money == 123456, "ADMIN_REPAIRED_VANILLA_PLAYER_MONEY")
  test.check(SaveData.valid?(data), "ADMIN_REPAIRED_NATIVE_SAVE_VALID")
  test.log("ADMIN_REPAIRED_SAVE_PASS")
  success = true
rescue Exception => error
  $kif_test_log.call("ADMIN_REPAIRED_SAVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(success ? 0 : 1)
end
