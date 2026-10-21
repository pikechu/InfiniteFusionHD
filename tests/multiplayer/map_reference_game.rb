# Native map resource lifetime probe; no battle/network/scene updates execute.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  $scene = map_scene = Scene_Map.new
  map_scene.createSpritesets
  renderer = map_scene.map_renderer
  counts = lambda do
    {"tilesets" => renderer.tilesets.instance_variable_get(:@load_counts).dup,
     "autotiles" => renderer.autotiles.instance_variable_get(:@load_counts).dup}
  end
  before = counts.call
  KIFMultiplayer::BattlePresentation.with(Object.new) do
    test.check(!$scene.is_a?(Scene_Map), "battle body cannot update original map")
  end
  after = counts.call
  test.log("NATIVE_MAP_REFERENCES before=#{KIFMultiplayer::WireJSON.dump(before)} after=#{KIFMultiplayer::WireJSON.dump(after)}")
  File.write(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "map-reference-evidence.json"),
             KIFMultiplayer::WireJSON.dump({"pid" => Process.pid, "before" => before, "after" => after, "balanced" => before == after}))
  test.check($scene.equal?(map_scene) && before == after, "real tileset/autotile references balance after map sprites are recreated")
  test.log("MAP_REFERENCE_NATIVE_PASS")
  passed = true
rescue Exception => error
  $kif_test_log.call("MAP_REFERENCE_NATIVE_FAIL #{error.class}: #{error.message}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
