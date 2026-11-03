begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  success = false
  path = ENV.fetch("KIF_WHOLE_ROLLBACK_FIXTURE")
  restored = KIFMultiplayer::CloudCodec.unpack(KIFMultiplayer::WireJSON.parse(File.read(path)))
  test.check(restored[:kuray_player].money == 3000, "WHOLE_ROLLBACK_ACTIVE_PLAYER_RESTORED")
  test.check(restored[:player].money == 3000, "WHOLE_ROLLBACK_VANILLA_PLAYER_RESTORED")
  test.check(SaveData.valid?(restored), "WHOLE_ROLLBACK_NATIVE_SAVE_VALID")
  test.log("WHOLE_ROLLBACK_GAME_PASS checks=3")
  success = true
rescue Exception => error
  $kif_test_log.call("WHOLE_ROLLBACK_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(success ? 0 : 1)
end
