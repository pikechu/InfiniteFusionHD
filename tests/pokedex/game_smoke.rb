# Explicit isolated Game.exe probe. No normal player saves or external network.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  check = KIFMultiplayerFeatureTest.method(:check)
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  real_path = Settings::CUSTOM_DEX_ENTRIES_PATH
  original_digest = Digest::SHA256.hexdigest(File.binread(real_path))
  bundled = KIF::PokedexEntries.parse(File.binread(real_path))
  check.call(bundled.length == 15_005, "native parser reads merged custom dex")
  check.call(bundled.all? { |entry| KIF::PokedexEntries.valid?(entry) }, "all bundled entries contain valid text and author")
  numeric = bundled.find { |entry| entry["author"] == 9000 }
  check.call(numeric && numeric["author"].is_a?(Integer), "numeric author survives native parser")
  scene = PokemonPokedexInfo_Scene.allocate
  texts = scene.getCustomDexEntry("1.100.png")
  check.call(texts && texts.any? { |text| text.include?("spherical appearance") }, "production lookup finds newly imported fusion text")
  texts = scene.getCustomDexEntry("1.38.png")
  check.call(texts && texts.include?("An enormous flower bud sprouts from its tail. The growing bloom inside radiates mystical heat."), "production lookup retains KIF-only text")
  path = File.join(directory, "custom-dex-update.json")
  File.binwrite(path, File.binread(real_path))
  Settings.send(:remove_const, :CUSTOM_DEX_ENTRIES_PATH)
  Settings.const_set(:CUSTOM_DEX_ENTRIES_PATH, path)
  $PokemonSystem.download_sprites = 0
  KIF::Platform.define_singleton_method(:http_get) { |*| {:status => 200, :body => File.binread("Data/dex.json")} }
  before = Digest::SHA256.hexdigest(File.binread(path))
  check.call(updateCustomDexFile == path && Digest::SHA256.hexdigest(File.binread(path)) == before, "stale old upstream data cannot replace merged dex")
  KIF::Platform.define_singleton_method(:http_get) { |*| {:status => 200, :body => "<html>invalid JSON</html>"} }
  check.call(updateCustomDexFile.nil? && Digest::SHA256.hexdigest(File.binread(path)) == before, "native MKXPError is contained and existing data retained")
  fixture = {"sprite" => "1.2a.png", "entry" => "测试 \"quote\" \\ newline\n😀", "author" => "native fixture"}
  KIF::Platform.define_singleton_method(:http_get) { |*| {:status => 200, :body => HTTPLite::JSON.stringify([fixture])} }
  check.call(updateCustomDexFile == path, "native updater appends without external HTTP")
  restored = KIF::PokedexEntries.parse(File.binread(path))
  check.call(restored.length == bundled.length + 1 && restored.last == fixture, "native serializer round-trips Unicode and escaping")
  check.call(restored[0, bundled.length] == bundled, "native rewrite preserves every bundled record")
  check.call(Digest::SHA256.hexdigest(File.binread(real_path)) == original_digest, "repository dex is unchanged by isolated native updater tests")
  check.call(Dir.glob(File.join(directory, ".*.pending")).empty?, "native updates leave no partial files")
  KIFMultiplayerFeatureTest.log("POKEDEX_NATIVE_PASS entries=#{bundled.length} no_external_network=true normal_player_saves=false")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("POKEDEX_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
