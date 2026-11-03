# Explicit native-runtime diagnostic. Uses a new isolated profile, never a player's save.
load "scripts/multiplayer/test-bootstrap.rb"
$GameSpeed = 1
$PokemonSystem.sevolume = 100
$PokemonSystem.bgmvolume = 100
# This synthetic fixture skips the opening's character creation/outfit grants.
{:@clothes => STARTING_OUTFIT, :@hat => nil, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
 :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each do |key, value|
  $Trainer.instance_variable_set(key, value)
end
$local_map_audio = []
module LocalMapAudioProbe
  def se_play(*arguments)
    $local_map_audio << arguments
    super
  end
end
Audio.singleton_class.prepend(LocalMapAudioProbe)
# Keep this fixture about presentation: it intentionally skips the opening's
# story flags. Door autoruns still execute unchanged on arrival and departure.
module LocalMapStoryFixture
  def check_event_trigger_auto
    return if [3,4].include?(trigger) && name != "Home door"
    super
  end
  def update
    return if [3,4].include?(trigger) && name != "Home door"
    super
  end
end
Game_Event.prepend(LocalMapStoryFixture)
module LocalMapHeldInput
  def dir4; $local_map_direction.nil? ? super : $local_map_direction; end
  def press?(code)
    return $local_map_run if !$local_map_run.nil? && code == Input::ACTION
    super
  end
end
Input.singleton_class.prepend(LocalMapHeldInput)

def local_map_frame
  Graphics.update
  Input.update
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  $scene.update
  $local_map_update_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000
end

def local_map_motion(map)
  local_map_setup(map,20,29)
  corridor = nil
  (8...$game_map.height-8).each do |y|
    (8...$game_map.width-14).each do |x|
      points = (0..6).map { |dx| [x+dx,y] }
      next if points.any? { |point| $game_map.events.values.any? { |event| event.at_coordinate?(*point) } }
      next unless points[0...-1].all? { |point| $game_player.can_move_from_coordinate?(*point,6) }
      next unless points[1..-1].all? { |point| $game_player.can_move_from_coordinate?(*point,4) }
      corridor = [x,y]
      break
    end
    break if corridor
  end
  raise "No safe scrolling corridor on #{map}" unless corridor
  $game_player.moveto(*corridor)
  $Trainer.has_running_shoes = true
  $PokemonSystem.runstyle = 0
  positions, cameras, updates = [], [], []
  [[6,false,corridor[0]+6],[4,true,corridor[0]]].each do |direction,running,target|
    $local_map_direction, $local_map_run = direction,running
    reached = false
    180.times do
      local_map_frame
      raise "Motion fixture entered another map" unless $game_map.map_id == map
      player = $scene.spritesetGlobal.playersprite
      offset = player.instance_variable_get(:@character_name) == "run" ? [direction == 6 ? 2 : -2,-2] : [0,0]
      expected = [player.x-player.ox+offset[0],player.y-player.oy+offset[1]-($game_player.pattern.odd? ? 2 : 0)]
      %w[@hair @hat].each do |name|
        layer = player.instance_variable_get(name).sprite
        raise "Motion layer alignment/depth differs" unless [layer.x,layer.y] == expected && layer.z == player.z
      end
      positions << $game_player.real_x.to_f / Game_Map::X_SUBPIXELS
      cameras << $game_map.display_x
      updates << $local_map_update_ms
      if $game_player.x == target && !$game_player.moving?
        reached = true
        break
      end
    end
    raise "Held input failed to reach target on #{map}" unless reached
  end
  raise "Movement skipped intermediate pixels" unless positions.each_cons(2).all? { |a,b| (a-b).abs <= 6.5 }
  raise "Camera did not scroll" unless cameras.uniq.length > 6
  local_map_capture("motion-#{map}")
  ordered = updates.sort
  {"map" => map,"frames" => positions.length,"camera_positions" => cameras.uniq.length,
   "update_ms" => {"p50" => ordered[ordered.length/2],"p95" => ordered[(ordered.length*0.95).floor],"max" => ordered.last}}
ensure
  $local_map_direction = $local_map_run = nil
end

def local_map_setup(map, x, y)
  $kif_test_log.call("LOCAL_MAP_SETUP #{map}")
  $scene.dispose if $scene.is_a?(Scene_Map)
  $scene = Scene_Map.new
  $MapFactory.setup(map)
  $game_player.moveto(x, y)
  $game_player.turn_up
  # This fixture skips the story setup; run doors, not unrelated story autoruns.
  $MapFactory.maps.each do |loaded_map|
    loaded_map.events.each_value do |event|
      event.erase if [3,4].include?(event.trigger) && event.name != "Home door"
    end
  end
  $scene.createSpritesets
  $game_map.autoplay
  2.times { local_map_frame }
  $kif_test_log.call("LOCAL_MAP_READY #{map}")
end

def local_map_capture(name)
  image = Graphics.snap_to_bitmap
  image.to_file(File.join($kif_test_directory, name + ".png"))
ensure
  image&.dispose
end

begin
  result = {"runtime" => RUBY_VERSION, "alignment_errors" => [], "hidden_layer_errors" => []}
  local_map_setup(42, 12, 11)
  $game_player.move_generic(6)
  12.times do |frame|
    local_map_frame
    player = $scene.spritesetGlobal.playersprite
    %w[@hair @hat].each do |name|
      layer = player.instance_variable_get(name).sprite
      expected = [player.x - player.ox, player.y - player.oy - ($game_player.pattern.odd? ? 2 : 0)]
      actual = [layer.x, layer.y]
      result["alignment_errors"] << {"frame" => frame, "layer" => name, "expected" => expected, "actual" => actual} if actual != expected
    end
  end
  local_map_capture("walking")
  result["held_walk_run_and_scrolling"] = [42,79].map { |map| local_map_motion(map) }

  local_map_setup(42, 12, 10)
  $local_map_audio.clear
  $game_player.move_generic(8)
  160.times do
    local_map_frame
    break if $game_map.map_id == 43
  end
  raise "Pallet home entry failed" unless $game_map.map_id == 43
  result["pallet_entry_sounds"] = $local_map_audio.dup
  local_map_capture("pallet-home")

  local_map_setup(79, 25, 29)
  $local_map_audio.clear
  $game_player.move_generic(8)
  hidden_frames = 0
  240.times do |frame|
    local_map_frame
    player = $scene.spritesetGlobal.playersprite
    unless player.visible
      hidden_frames += 1
      %w[@hair @hat].each do |name|
        layer = player.instance_variable_get(name).sprite
        result["hidden_layer_errors"] << {"frame" => frame, "layer" => name} if layer.bitmap && layer.visible
      end
      local_map_capture("hidden-player") if hidden_frames == 2
    end
    break if $game_map.map_id == 81
  end
  raise "Viridian shop entry failed" unless $game_map.map_id == 81
  result["animated_door_hidden_frames"] = hidden_frames
  result["viridian_entry_sounds"] = $local_map_audio.dup
  local_map_capture("viridian-shop")
  File.write(File.join($kif_test_directory, "local-map-result.json"), KIFMultiplayer::WireJSON.dump(result))
  $kif_test_log.call("LOCAL_MAP_OBSERVATION " + KIFMultiplayer::WireJSON.dump(result))
  if ENV["KIF_LOCAL_MAP_ASSERT"] == "1"
    raise "Wearable movement lags behind the body" unless result["alignment_errors"].empty?
    raise "Hidden player still renders wearable layers" unless result["hidden_layer_errors"].empty?
    raise "Pallet entry has no door sound" unless result["pallet_entry_sounds"].any? { |args| args.first.include?("Entering Door") }
    raise "Door animation was not exercised" unless hidden_frames > 0
  end
  $kif_test_log.call("LOCAL_MAP_PASS")
rescue Exception => error
  $kif_test_log.call("LOCAL_MAP_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  raise
ensure
  $scene.dispose if $scene.is_a?(Scene_Map)
end
exit
