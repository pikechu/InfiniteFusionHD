# Native image decoding and battle sprites, with test saves and no external HTTP.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  module UpstreamTest
    class << self
      attr_accessor :checks
      def check(value, name)
        KIFMultiplayerFeatureTest.check(value, name)
        self.checks = (checks || 0) + 1
      end
      def override(target, name, callable)
        original = target.instance_method(name)
        target.send(:define_method, name, callable)
        yield
      ensure
        target.send(:define_method, name, original) if original
      end
    end
  end
  check = UpstreamTest.method(:check)
  log = KIFMultiplayerFeatureTest.method(:log)
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  KIF::SpriteSheets.test_root = File.join(directory, "battle-sheets")
  $PokemonSystem.download_sprites = 0
  requests = []
  KIF::Platform.define_singleton_method(:http_get) { |url, *| requests << url; { :status => 404 } }
  KIF::OfflineResources.define_singleton_method(:fetch) { |url, *| requests << url; raise IOError, "offline fixture" }
  # This installed game lacks 41n.png, although the credits list it as main art.
  Object.send(:define_method, :get_random_alt_letter_for_unfused) { |*| "n" }
  times = []
  viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
  opponent = PokemonBattlerSprite.new(viewport, 1, 1, [])
  player = PokemonBattlerSprite.new(viewport, 1, 0, [])
  10.times do
    $PokemonGlobal.alt_sprite_substitutions = {}
    pokemon = Pokemon.new(:ZUBAT, 8, $Trainer)
    pokemon.kuraycustomfile = "none"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    opponent.setPokemonBitmap(pokemon)
    player.setPokemonBitmap(pokemon, true)
    times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    check.call(opponent.bitmap && opponent.bitmap.width > 32 && player.bitmap && player.bitmap.width > 32,
      "Zubat front and back decode through actual battle sprites")
  end
  check.call(requests.empty?, "missing random Zubat art never starts HTTPS when local main is installed")
  check.call(get_unfused_sprite_path(41) != Settings::DEFAULT_SPRITE_PATH, "Zubat resolves to installed art rather than the question mark")
  generated = Dir["Graphics/Battlers/*/*.*.png"].find { |path| KIF::SpriteIndex.parse_name(File.basename(path)) }
  entry = KIF::SpriteIndex.parse_name(File.basename(generated))
  pokemon = Pokemon.new(getSpeciesIdForFusion(entry[:head], entry[:body]), 8, $Trainer)
  pokemon.kuraycustomfile = "none"
  opponent.setPokemonBitmap(pokemon)
  check.call(opponent.bitmap.width > 32 && requests.empty?, "real installed fusion art renders without a custom download")
  $PokemonGlobal.alt_sprite_substitutions.clear
  $PokemonGlobal.autogen_sprites_cache = {}
  $PokemonSystem.sprite_sheet_mode = 0
  check.call(get_fusion_sprite_path(entry[:head], entry[:body], 0, 0) == generated && requests.empty?,
    "default fusion form zero resolves real installed art with sheets disabled")
  log.call("BATTLE_SPRITE_TIMING #{times.inspect} max_seconds=#{times.max} requests=#{requests.length}")
  opponent.dispose
  player.dispose
  viewport.dispose
  # Reuse the existing real PNG crop, transparency, shiny, cache and UI regressions.
  load "tests/upstream/U09.rb"
  log.call("BATTLE_SPRITES_NATIVE_PASS checks=#{UpstreamTest.checks} no_player_saves=true")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("BATTLE_SPRITES_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  [opponent, player, viewport].each { |object| object.dispose if object && !object.disposed? }
  KIF::SpriteSheets.clear if defined?(KIF::SpriteSheets)
  exit!(passed ? 0 : 1)
end
