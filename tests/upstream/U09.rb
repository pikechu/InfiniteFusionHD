check = UpstreamTest.method(:check)
KIFMultiplayerFeatureTest.log("U09_READY initialized_game=true")
folder = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "sheets")
KIF::SpriteImport.mkdir(folder)
credits_file = File.join(folder, "credits.csv")
File.write(credits_file, "500.501a,alpha\n500.501a,beta\n")
check.call(KIF::SpriteCredits.lookup("500.501a", credits_file).strip == "alpha", "credits cache preserves first artist attribution")
check.call(KIF::SpriteCredits.lookup("missing", credits_file).nil?, "credits cache also remembers missing artists")
File.write(credits_file, "500.501a,updated author\n")
check.call(KIF::SpriteCredits.lookup("500.501a", credits_file).strip == "updated author", "credits update invalidates cached attribution")
300.times { |index| KIF::SpriteCredits.lookup(index.to_s, credits_file) }
check.call(KIF::SpriteCredits.instance_variable_get(:@cache).length <= 256, "credits query cache stays bounded")
KIF::SpriteSheets.test_root = folder
$PokemonSystem.sprite_sheet_mode = 1
write_sheet = lambda do |type, head, alt, columns, index, color|
  path = KIF::SpriteSheets.bundled(type, head, alt)
  KIF::SpriteImport.mkdir(File.dirname(path))
  # Generate fixtures without millions of slow GPU readbacks under emulation;
  # decoding/cropping/validation still use the real native Bitmap implementation.
  width, height = columns * 96, (index / columns + 1) * 96
  blank = "\0".b * (width * 4)
  colored = blank.dup
  offset = index % columns * 96 * 4
  colored[offset, 96 * 4] = [color.red, color.green, color.blue, color.alpha].map(&:to_i).pack("C4") * 96
  raw = (0...height).map do |row|
    pixels = row >= index / columns * 96 ? colored.dup : blank
    pixels[offset, 4] = "\0".b * 4 if row == index / columns * 96
    "\0".b + pixels
  end.join
  chunk = lambda { |kind, data| [data.bytesize].pack("N") + kind + data + [Zlib.crc32(kind + data)].pack("N") }
  File.binwrite(path, KIF::SpriteImport::PNG + chunk.call("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNCCCCC")) + chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", ""))
  path
end
red, green, blue = Color.new(240, 10, 20, 255), Color.new(10, 230, 20, 255), Color.new(10, 20, 230, 255)
custom = write_sheet.call(:custom, 500, "a", 20, 501, red)
base = write_sheet.call(:base, 500, "", 10, 27, green)
autogen = write_sheet.call(:autogen, 500, "", 10, 501, blue)
%w[off local online].each_with_index { |_, index| $PokemonSystem.sprite_sheet_mode = index; check.call($PokemonSystem.sprite_sheet_mode == index, "sheet mode #{index} configurable") }
$PokemonSystem.sprite_sheet_mode = 1
fixtures = [[:custom, 500, 501, "a", red], [:base, 500, nil, "aa", green], [:autogen, 500, 501, "", blue]]
cold_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
paths = fixtures.map do |type, head, body, alt, color|
  path = KIF::SpriteSheets.resolve(type, head, body, alt, false)
  check.call(path && File.file?(path), "#{type} sheet materializes PNG")
  image = Bitmap.new(path)
  pixel = image.get_pixel(30, 30)
  check.call(image.width == 96 && image.height == 96 && [pixel.red, pixel.green, pixel.blue] == [color.red, color.green, color.blue], "#{type} exact row column and alt indexing")
  check.call(image.get_pixel(0, 0).alpha == 0, "#{type} transparency retained")
  image.dispose
  path
end
cold_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - cold_start
check.call(KIF::SpriteSheets.stats[:cache_bytes] > 0 && KIF::SpriteSheets.stats[:sheets] <= 2, "native sheet LRU retains at most two decoded textures")
token = KIF::SpriteSheets.candidate(:custom, 500, 501, "a")
check.call(pbResolveBitmap(token) == paths[0], "bitmap resolver lazily resolves managed cache tokens")
animated = AnimatedBitmap.new(token).recognizeDims()
check.call(animated.bitmap.width == 288, "KIF size normalization consumes extracted 96px sprites")
animated.dispose
check.call(KIF::SpriteSheets.resolve(:custom, 500, 1, "a", false).nil?, "transparent cells fall back instead of producing blank Pokemon")
check.call(KIF::SpriteSheets.resolve(:base, 500, nil, "../../", false).nil?, "invalid alternatives cannot traverse paths")
key = KIFMultiplayer::TradeCodec.asset_key(token)
check.call(key == "fusion:500.501a", "trade serializes stable logical asset ID rather than cache directory")
path = KIFMultiplayer::TradeCodec.asset_path(key, "B501H500")
check.call(path == paths[0], "trade reconstructs same asset from installed sheet without HTTP")
write_sheet.call(:custom, 500, "a", 20, 501, green)
changed = KIF::SpriteSheets.resolve_path(paths[0], false)
changed_bitmap = Bitmap.new(changed)
check.call(changed != paths[0] && changed_bitmap.get_pixel(30, 30).green == 230, "changed sheet invalidates extracted paths without overwriting saved user art")
check.call(getPathForShinyCache(File.dirname(changed) + "/") != getPathForShinyCache(File.dirname(paths[0]) + "/"), "shiny disk cache includes sheet version and source fingerprint")
changed_bitmap.dispose
override = File.join(folder, "local-override.png")
override_bitmap = Bitmap.new(96, 96)
override_bitmap.fill_rect(0, 0, 96, 96, blue)
override_bitmap.save_to_png(override)
override_bitmap.dispose
UpstreamTest.override(KIF::SpriteSheets.singleton_class, :local_png, proc { |*| override }) do
  check.call(KIF::SpriteSheets.resolve(:custom, 500, 501, "a") == override, "local individual PNG takes priority over a sheet")
end
write_sheet.call(:custom, 500, "b", 20, 501, blue)
first = Pokemon.new(getFusedPokemonIdFromSymbols(501, 500), 50, $Trainer)
first.kuraycustomfile = token
second = first.clone
second.kuraycustomfile = KIF::SpriteSheets.candidate(:custom, 500, 501, "b")
$PokemonSystem.kurayindividcustomsprite = 0
first.shiny = false
second.shiny = false
normal = GameData::Species.sprite_bitmap_from_pokemon(first)
other = GameData::Species.sprite_bitmap_from_pokemon(second)
check.call(normal.bitmap.get_pixel(90, 90).green == 230 && other.bitmap.get_pixel(90, 90).blue == 230, "same species retains independent per-Pokemon sprite variants")
first.shiny = true
first.shinyValue = 120
first.shinyR, first.shinyG, first.shinyB = 1, 0, 2
$PokemonSystem.pifimprovedshinies = 3
$PokemonSystem.shinyadvanced = 1
shiny = GameData::Species.sprite_bitmap_from_pokemon(first)
check.call(shiny.bitmap.get_pixel(90, 90) != normal.bitmap.get_pixel(90, 90), "KIF shiny transformation is applied after sheet extraction")
check.call(other.bitmap.get_pixel(90, 90).blue == 230, "one Pokemon shiny does not mutate another sprite")
[normal, other, shiny].each(&:dispose)
snapshot = KIFMultiplayer::TradeCodec.export(first)
received = KIFMultiplayer::TradeCodec.import(snapshot)
check.call(received.kuraycustomfile? == changed && received.shinyR? == 1 && received.shinyValue? == 120, "real trade codec preserves logical sprite and individual shiny parameters")
exported = File.join(folder, "exported-shiny.png")
shinyPNGMake(first, exported)
check.call(KIF::SpriteImport.valid_png?(exported), "existing shiny PNG export accepts managed sheet paths")
write_sheet.call(:custom, 501, "a", 20, 500, red)
$PokemonGlobal.alt_sprite_substitutions ||= {}
$PokemonGlobal.alt_sprite_substitutions[first.species_data.id_number.to_s] = token
reverse_id = getFusedPokemonIdFromSymbols(500, 501)
$PokemonGlobal.alt_sprite_substitutions[GameData::Species.get(reverse_id).id_number.to_s] = KIF::SpriteSheets.candidate(:custom, 501, 500, "a")
preview = DoublePreviewScreen.allocate
forward = preview.getPicturePath(500, 501)
reverse = preview.getPicturePath(501, 500)
f_bitmap = AnimatedBitmap.new(forward).recognizeDims()
r_bitmap = AnimatedBitmap.new(reverse).recognizeDims()
check.call(f_bitmap.bitmap.get_pixel(90, 90).green == 230 && r_bitmap.bitmap.get_pixel(90, 90).red == 240, "fusion and reverse-fusion preview use their own sheet cells")
[f_bitmap, r_bitmap].each(&:dispose)
requests = 0
response_body = File.binread(custom)
$PokemonSystem.sprite_sheet_mode = 2
$PokemonSystem.download_sprites = 0
UpstreamTest.override(KIF::Platform.singleton_class, :network_available?, proc { false }) do
  check.call(KIF::SpriteSheets.resolve(:custom, 396, 501).nil?, "missing network capability stays offline even in Online mode")
end
UpstreamTest.override(KIF::Platform.singleton_class, :network_available?, proc { true }) do
UpstreamTest.override(Object, :download_all_alt_sprites, proc { |*| raise "eager PNG download" }) do
  UpstreamTest.override(KIF::SpriteIndex.singleton_class, :fusion_alts, proc { |*| ["a", "b"] }) do
    lazy_scene = PokemonPokedexInfo_Scene.new
    lazy_scene.instance_variable_set(:@species, first.species)
    check.call(lazy_scene.pbGetAvailableForms.include?(token), "online dex enumerates candidates without eager PNG downloads")
    lazy_scene.disposeAvailableBitmaps
  end
end
UpstreamTest.override(KIF::Platform.singleton_class, :http_get, proc { |*| requests += 1; {:status => 200, :body => response_body} }) do
  downloaded = KIF::SpriteSheets.resolve(:custom, 399, 501)
  check.call(downloaded && requests == 1, "valid downloaded sheet is staged verified and extracted")
  check.call(KIF::SpriteSheets.resolve(:custom, 399, 501) == downloaded && requests == 1, "downloaded pack cache avoids repeated requests")
end
UpstreamTest.override(KIF::Platform.singleton_class, :http_get, proc { |*| requests += 1; {:status => 200, :body => "<html>bad sheet</html>"} }) do
  check.call(KIF::SpriteSheets.resolve(:custom, 398, 501).nil?, "invalid remote image is never installed")
  before = requests
  KIF::SpriteSheets.resolve(:custom, 398, 501)
  check.call(requests == before, "failed sheet is requested at most once per session")
end
write_sheet.call(:custom, 397, "", 20, 501, green)
UpstreamTest.override(KIF::Platform.singleton_class, :http_get, proc { |*| raise MKXPError, "offline fixture" }) do
  check.call(!!KIF::SpriteSheets.resolve(:custom, 397, 501), "network failure falls back to an installed sheet")
  KIF::SpriteSheets.preload_party(Struct.new(:party).new([first] * 6 + [Object.new]))
  check.call(true, "party prewarm is local only and bounded to six Pokemon")
end
end
$PokemonSystem.download_sprites = 1
$PokemonSystem.sprite_sheet_mode = 1
old_pack = KIF::SpriteSheets.pack
old_month = Settings::NEWEST_SPRITEPACK_MONTH
Settings.send(:remove_const, :NEWEST_SPRITEPACK_MONTH)
Settings.const_set(:NEWEST_SPRITEPACK_MONTH, old_month + 1)
new_path = KIF::SpriteSheets.resolve_path(token, false)
check.call(KIF::SpriteSheets.pack != old_pack && new_path && new_path != paths[0], "pack update isolates cache and migrates persisted tokens")
Settings.send(:remove_const, :NEWEST_SPRITEPACK_MONTH)
Settings.const_set(:NEWEST_SPRITEPACK_MONTH, old_month)
$PokemonSystem.sprite_sheet_mode = 0
check.call(KIF::SpriteSheets.resolve(:custom, 500, 501, "a", false).nil?, "legacy PNG-only mode bypasses sheets")
$PokemonSystem.sprite_sheet_mode = 1
candidate = KIF::SpriteSheets.candidate(:base, 500, nil, "aa")
pc = PokemonPokedexInfo_Scene.new
pc.setAvailableBitmaps(Array.new(20, candidate))
check.call(pc.instance_variable_get(:@available_bitmaps).empty?, "dex does not eagerly decode every alternative")
12.times { |index| pc.getAvailableBitmap(index) }
check.call(pc.instance_variable_get(:@available_bitmaps).length <= 8, "dex bitmap cache is bounded")
pc.disposeAvailableBitmaps
check.call(pc.instance_variable_get(:@available_bitmaps).nil?, "dex owns and disposes alternative bitmaps")
check.call(KIF::SpriteSheets.stats[:cache_bytes] <= KIF::SpriteSheets.cache_budget, "sheet LRU respects platform memory budget")
before = KIF::SpriteSheets.stats[:extractions] || 0
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { KIF::SpriteSheets.resolve(:custom, 500, 501, "a", false) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
check.call((KIF::SpriteSheets.stats[:extractions] || 0) == before, "warm lookups reuse extracted PNGs")
KIFMultiplayerFeatureTest.log("SHEET_BENCHMARK cold_three_seconds=#{cold_elapsed} warm_100_seconds=#{elapsed} stats=#{KIF::SpriteSheets.stats.inspect}")
KIF::SpriteSheets.clear
check.call(KIF::SpriteSheets.stats[:cache_bytes] == 0, "explicit cache lifecycle releases native bitmaps")

# Real native UI paths, using only the freshly-created test trainer/storage.
first.shiny = false
$Trainer.party = [second]
$PokemonSystem.kuraybigicons = 2
$PokemonSystem.shiny_icons_kuray = 0
2.times { |box| 30.times { |slot| $PokemonStorage[box, slot] = (slot.even? ? first : second).clone } }
storage_scene = PokemonStorageScene.new
storage_screen = PokemonStorageScreen.new(storage_scene, $PokemonStorage)
ui_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
storage_scene.pbStartBox(storage_screen, 0)
storage_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ui_start
ui_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
4.times { |index| storage_scene.pbJumpToBox(index.even? ? 1 : 0) }
storage_switch = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ui_start
Graphics.update
Graphics.screenshot(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "sheets-storage.png"))
check.call($PokemonStorage.currentBox == 0, "native big-icon storage switches between full boxes using individual sheet variants")
storage_scene.pbCloseBox
info = PokemonPokedexInfo_Scene.new
info.setAvailableBitmaps([token, second.kuraycustomfile?])
ui_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
info.pbStartSpritesSelectSceneBrief(first.species, [token, second.kuraycustomfile?])
dex_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ui_start
ui_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
20.times do |index|
  info.instance_variable_set(:@selected_index, index % 2)
  info.update_displayed
  Graphics.update
end
dex_turn = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ui_start
Graphics.screenshot(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "sheets-dex.png"))
check.call(info.instance_variable_get(:@available_bitmaps).length == 2, "native dex page renders and flips sheet alternatives lazily")
info.pbEndScene
check.call(info.instance_variable_get(:@available_bitmaps).nil?, "native dex close disposes lazy bitmap ownership")
KIFMultiplayerFeatureTest.log("SHEET_UI_BENCHMARK storage_start_seconds=#{storage_start} four_switches_seconds=#{storage_switch} dex_start_seconds=#{dex_start} twenty_flips_seconds=#{dex_turn}")
load File.join(ENV.fetch("KIF_TEST_SOURCE_ROOT", "."), "tests/multiplayer/trade_game_test.rb")
KIFMultiplayerTradeGameTest.run(KIFMultiplayerFeatureTest.method(:log))
check.call(true, "existing full native trade snapshot regression passes")
