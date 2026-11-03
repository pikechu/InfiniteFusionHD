# Native loading benchmark with isolated saves; no story progression is saved.
load "scripts/multiplayer/test-bootstrap.rb"
$GameSpeed = 1
GameLanguage.load(2)
{:@clothes => STARTING_OUTFIT, :@hat => nil, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
 :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each do |key, value|
  $Trainer.instance_variable_set(key, value)
end
module MapTransferStoryFixture
  def check_event_trigger_auto; end
  def update
    return if [3, 4].include?(trigger)
    super
  end
end
Game_Event.prepend(MapTransferStoryFixture)

$transfer_metrics = nil
def measure_transfer_methods(klass, *names)
  probe = Module.new
  names.each do |name|
    probe.define_method(name) do |*args, &block|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        super(*args, &block)
      ensure
        if $transfer_metrics
          key = "#{klass}##{name}"
          if klass == Sprite_Character && name == :initialize && args[1].respond_to?(:name)
            key += ":#{args[1].name}"
          end
          entry = ($transfer_metrics[key] ||= [0, 0.0])
          entry[0] += 1
          entry[1] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        end
      end
    end
  end
  klass.prepend(probe)
end
measure_transfer_methods(Scene_Map, :autofade, :disposeSpritesets, :createSpritesets)
measure_transfer_methods(Game_Map, :setup)
measure_transfer_methods(Game_Event, :initialize)
measure_transfer_methods(Sprite_Character, :initialize)
measure_transfer_methods(TilemapRenderer::TilesetBitmaps, :add)
measure_transfer_methods(TilemapRenderer::AutotileBitmaps, :add)
measure_transfer_methods(Object, :pbResolveBitmap, :load_data)
measure_transfer_methods(Sprite_Character, :checkModifySpriteGraphics)

passed = false
begin
  $scene = Scene_Map.new
  $MapFactory.setup(42)
  $game_player.moveto(12, 10)
  $scene.createSpritesets
  results = []
  3.times do |round|
    [[43, 3, 6], [42, 12, 10], [81, 3, 6], [79, 25, 29]].each do |map, x, y|
      $game_temp.player_new_map_id = map
      $game_temp.player_new_x = x
      $game_temp.player_new_y = y
      $game_temp.player_new_direction = 2
      $game_temp.transition_processing = false
      $transfer_metrics = {}
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      black_started = black_ended = nil
      pbFadeOutIn do
        black_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        $scene.transfer_player
        black_ended = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      fade_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      elapsed = (black_ended - black_started) * 1000
      raise "Wrong destination" unless $game_map.map_id == map && $game_player.x == x && $game_player.y == y
      result = {"round" => round, "map" => map, "ms" => elapsed, "fully_black_hold_ms" => elapsed, "fade_roundtrip_ms" => fade_ms, "rss_kib" => File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/,1].to_i, "stages" => $transfer_metrics}
      result["textures"] = [$scene.map_renderer.tilesets, $scene.map_renderer.autotiles].map do |bank|
        bank.bitmaps.map { |name, bitmap| [name, bitmap.width, bitmap.height, bank.instance_variable_get(:@load_counts)[name]] }
      end
      results << result
      $transfer_metrics = nil
      Graphics.update
      Graphics.screenshot(File.join($kif_test_directory, "map-#{map}.png")) if round == 2
      $kif_test_log.call("TRANSFER " + KIFMultiplayer::WireJSON.dump(result))
    end
  end
  # Compare the optimized event tiles against the original unwrapped pixels.
  source = pbGetTileset("Indoor")
  boundary = $scene.map_renderer.tilesets["Indoor"].height / 32 * 8 + 384
  [[8116, 1, 1, 0], [8116, 1, 1, 120], [boundary, 2, 2, 0],
   [boundary + 7, 2, 2, 0], [384, 1, 2, 0]].each do |id, width, height, hue|
    actual = RPG::Cache.tileEx("Indoor", id, hue, width, height) { raise "Event tile reloaded the whole atlas" }
    expected = Bitmap.new(width * 32, height * 32)
    expected.blt(0, 0, source, Rect.new((id - 384) % 8 * 32, ((id - 384) / 8 - height + 1) * 32, width * 32, height * 32))
    expected.hue_change(hue) if hue != 0
    expected.height.times do |y|
      expected.width.times do |x|
        a, b = actual.get_pixel(x, y), expected.get_pixel(x, y)
        raise "Event tile pixel differs: #{id} at #{x},#{y}" unless [a.red,a.green,a.blue,a.alpha] == [b.red,b.green,b.blue,b.alpha]
      end
    end
    actual.dispose
    expected.dispose
  end
  source.dispose
  $kif_test_log.call("EVENT_TILE_PIXELS_PASS cases=5")
  File.write(File.join($kif_test_directory, "map-transfer-result.json"), KIFMultiplayer::WireJSON.dump(results))
  $kif_test_log.call("MAP_TRANSFER_PASS")
  passed = true
rescue Exception => error
  $kif_test_log.call("MAP_TRANSFER_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
ensure
  $scene.dispose if $scene.is_a?(Scene_Map)
  exit!(passed ? 0 : 1)
end
