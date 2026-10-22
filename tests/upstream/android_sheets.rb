# Runs only through run-android-sheets.py, replacing the diagnostic entry point.
# No game bootstrap or player-save load. Fixtures live in a unique owned folder.
begin
  private_root = File.join(ENV.fetch("KIF_ANDROID_FILES"), "diagnostics", "upstream-sheets")
  load "kif_android_preload.rb"
  require "zlib"
  load File.join(private_root, "000_Platform.rb")
  load File.join(private_root, "png-writer.rb")
  config = HTTPLite::JSON.parse(File.read(File.join(private_root, "config.json")))
  fixture = config.fetch("fixture")
  module Settings; end
  { :NB_POKEMON => 501, :NEWEST_SPRITEPACK_YEAR => 2026, :NEWEST_SPRITEPACK_MONTH => 10,
    :CUSTOM_SPRITES_FILE_PATH => fixture + "/custom.txt", :BASE_SPRITES_FILE_PATH => fixture + "/base.txt",
    :CUSTOM_BASE_SPRITE_FOLDER => fixture + "/individual-base", :CUSTOM_BATTLERS_FOLDER_INDEXED => fixture + "/individual-custom",
    :CUSTOM_BATTLERS_FOLDER => fixture, :BATTLERS_FOLDER => fixture + "/individual-autogen" }.each { |key, value| Settings.const_set(key, value) }
  $PokemonSystem = Struct.new(:sprite_sheet_mode).new(1)
  def downloadAllowed?; true; end
  load File.join(private_root, "SpriteAssets.rb")
  load File.join(private_root, "SpriteSheets.rb")
  KIF::SpriteSheets.test_root = fixture
  checks = []
  check = lambda { |value, name| raise "FAIL #{name}" unless value; checks << name; System.puts("SHEETS_CHECK #{name}") }
  clock = lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  timed = lambda { |&block| start = clock.call; block.call; clock.call - start }
  check.call(KIF::Platform.android? && KIF::SpriteSheets.cache_budget == 24 * 1024 * 1024, "Android native bitmap runtime and 24MiB sheet budget")
  cold = timed.call do
    [[:custom, 500, 501, "a"], [:base, 500, nil, "aa"], [:autogen, 500, 501, ""]].each_with_index do |entry, index|
      path = KIF::SpriteSheets.resolve(*entry, false)
      check.call(path && File.file?(path), "extract type #{entry[0]}")
      bitmap = Bitmap.new(path)
      pixel = bitmap.get_pixel(30, 30)
      expected = [[240, 10, 20], [10, 230, 20], [10, 20, 230]][index]
      check.call([pixel.red, pixel.green, pixel.blue] == expected && bitmap.get_pixel(0, 0).alpha == 0, "exact RGBA #{entry[0]}")
      bitmap.dispose
    end
  end
  check.call(KIF::SpriteSheets.stats[:peak_cache_bytes] <= KIF::SpriteSheets.cache_budget, "peak managed texture bytes stay within budget")
  before = KIF::SpriteSheets.stats[:extractions]
  warm = timed.call { 100.times { KIF::SpriteSheets.resolve(:custom, 500, 501, "a", false) } }
  check.call(before == KIF::SpriteSheets.stats[:extractions], "warm resolution reuses extracted PNG")
  box = timed.call do
    10.times do
      30.times do
        path = KIF::SpriteSheets.resolve(:custom, 500, 501, "a", false)
        bitmap = Bitmap.new(path)
        bitmap.dispose
      end
    end
  end
  candidates = 0
  dex = timed.call do
    100.times { candidates += KIF::SpriteSheets.candidates(:custom, 500, 501).length }
  end
  check.call(candidates == 100 && before == KIF::SpriteSheets.stats[:extractions], "candidate enumeration is lazy and creates no textures")
  token = KIF::SpriteSheets.candidate(:custom, 500, 501, "a")
  check.call(!!KIF::SpriteSheets.resolve_path(token, false), "persisted logical cache token resolves on Android")
  $PokemonSystem.sprite_sheet_mode = 2
  network_start = clock.call
  remote = KIF::SpriteSheets.resolve(:custom, 1, 1)
  network_elapsed = clock.call - network_start
  network = {"available" => KIF::Platform.network_available?, "seconds" => network_elapsed, "downloaded" => !!remote}
  if KIF::Platform.network_available?
    check.call(!!remote && (KIF::SpriteSheets.stats[:downloads] || 0) == 1, "verified HTTPS downloads a real upstream sheet")
  else
    check.call(remote.nil?, "unavailable Android HTTP adapter safely remains offline")
  end
  KIF::SpriteSheets.clear
  check.call(KIF::SpriteSheets.stats[:cache_bytes] == 0, "cache clear releases all owned textures")
  report = {"passed" => true, "ruby" => RUBY_VERSION, "checks" => checks,
    "cold_three_seconds" => cold, "warm_100_seconds" => warm, "box_like_10x30_seconds" => box,
    "enumerate_100_seconds" => dex, "network" => network, "stats" => KIF::SpriteSheets.stats.transform_keys(&:to_s)}
rescue Exception => error
  report = {"passed" => false, "error" => "#{error.class}: #{error.message}", "backtrace" => error.backtrace}
ensure
  File.write(File.join(private_root, "result.json"), HTTPLite::JSON.stringify(report)) if private_root && report
  exit!(report && report["passed"] ? 0 : 1)
end
