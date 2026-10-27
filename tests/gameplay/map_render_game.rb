# Real RGSS rendering/performance fixture. It never opens a player's save.
if ENV["KIF_RENDER_BASELINE_DIR"]
  baseline = ENV.fetch("KIF_RENDER_BASELINE_DIR")
  originals = %w[003_Sprite_Character.rb 013_Sprite_Wearable.rb 016_Sprite_Player.rb].to_h do |name|
    ["Data/Scripts/005_Sprites/" + name, File.join(baseline, name)]
  end
  File.singleton_class.prepend(Module.new do
    define_method(:read) do |path, *args|
      super(originals.fetch(path, path), *args)
    end
  end)
end
load "scripts/multiplayer/test-bootstrap.rb"
$GameSpeed = 1
{:@clothes => STARTING_OUTFIT, :@hat => nil, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
 :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each do |key,value|
  $Trainer.instance_variable_set(key, value)
end
$render_generations, $render_owned_bitmaps = [], []
$render_decodes = []
module MapRenderDecodes
  def initialize(*args, &block)
    $render_decodes << args.first if args.first.is_a?(String)
    super
  end
end
Bitmap.prepend(MapRenderDecodes)
module MapRenderTimings
  def generateClothedBitmap
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = super
    $render_owned_bitmaps << value
    value
  ensure
    $render_generations << (Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000
  end
end
Sprite_Player.prepend(MapRenderTimings)

def render_snapshot(name)
  Graphics.update
  image = Graphics.snap_to_bitmap
  image.to_file(File.join($kif_test_directory, name + ".png"))
  yield image if block_given?
ensure
  image&.dispose
end

def render_color(image, x, y)
  color = image.get_pixel(x,y)
  [color.red.round, color.green.round, color.blue.round]
end

begin
  result = {"ruby" => RUBY_VERSION}
  # Test actual native depth ordering: a roof just above the body must cover
  # the whole layered player; removing it must reveal hat above hair/body.
  viewport = Viewport.new(0,0,Graphics.width,Graphics.height)
  viewport.z = 999999
  body = Sprite.new(viewport)
  body.bitmap = Bitmap.new(80,80)
  body.bitmap.fill_rect(0,0,80,80,Color.new(0,0,255))
  body.x, body.y, body.z, body.ox, body.oy = 128,128,159,40,80
  character = Struct.new(:pattern,:direction).new(0,2)
  body.define_singleton_method(:character) { character }
  layers = [Sprite_Hair.new(body,"","walk",viewport), Sprite_Hat.new(body,"","walk",viewport)]
  layers.each_with_index do |layer,index|
    layer.sprite.bitmap = Bitmap.new(80,320)
    layer.sprite.bitmap.fill_rect(0,0,80,320,index == 0 ? Color.new(0,255,0) : Color.new(255,0,0))
    layer.animate("walk")
  end
  roof = Sprite.new(viewport)
  roof.bitmap = Bitmap.new(32,32)
  roof.bitmap.fill_rect(0,0,32,32,Color.new(255,255,0))
  roof.x, roof.y, roof.z = 112,64,160
  render_snapshot("roof-occlusion") { |image| result["covered_pixel"] = render_color(image,128,80) }
  roof.visible = false
  render_snapshot("hat-layering") { |image| result["hat_pixel"] = render_color(image,128,80) }
  roof.bitmap.dispose; roof.dispose
  layers.each { |layer| layer.sprite.bitmap.dispose; layer.dispose }
  body.bitmap.dispose; body.dispose; viewport.dispose

  $scene = Scene_Map.new
  $MapFactory.setup(79)
  $game_player.moveto(20,29)
  $game_player.setDefaultCharName("walk",0)
  $scene.createSpritesets
  player = $scene.spritesetGlobal.playersprite
  $render_generations.clear
  $render_owned_bitmaps.clear
  # Discard the previous action/appearance once, then repeatedly switch real
  # action charsets. Graphics pacing is excluded from the measured update time.
  player.refreshOutfit
  $render_decodes.clear
  samples, identities = [], []
  48.times do |frame|
    Graphics.update
    Input.update
    $game_player.setDefaultCharName(frame.even? ? "run" : "walk",0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    $scene.updateSpritesets
    samples << (Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000
    identities << player.bitmap.object_id
  end
  ordered = samples.sort
  result["action_switch_updates"] = samples.length
  result["compositions"] = $render_generations.length
  result["unique_composites"] = identities.uniq.length
  result["update_ms"] = {"p50" => ordered[ordered.length/2], "p95" => ordered[(ordered.length*0.95).floor], "max" => ordered.last}
  result["composition_ms"] = $render_generations.dup
  result["decoded_assets"] = $render_decodes.tally
  base_owners = (player.instance_variable_get(:@base_bitmaps) || {}).values.map(&:last)
  decodes_before_clear = $render_decodes.length
  RPG::Cache.clear
  4.times do |frame|
    $game_player.setDefaultCharName(frame.even? ? "run" : "walk",0)
    player.update
  end
  result["base_cache_survives_rpg_clear"] = !base_owners.empty? && $render_decodes.length == decodes_before_clear
  # The old grass mask used the unclothed source. Compare a real clothing
  # pixel above the masked feet against the production bush rendering.
  dressed = player.getClothedPlayerSprite
  bare = player.instance_variable_get(:@charbitmap).bitmap
  point = nil
  (20...64).step(4) do |y|
    (16...64).step(4) do |x|
      a, b = dressed.get_pixel(x,y), bare.get_pixel(x,y)
      if a.alpha == 255 && [a.red,a.green,a.blue] != [b.red,b.green,b.blue]
        point = [x,y]
        break
      end
    end
    break if point
  end
  raise "Fixture clothes have no distinct pixel" unless point
  expected = render_color(dressed,*point)
  $game_player.instance_variable_set(:@bush_depth,12)
  player.update
  result["grass_preserves_clothes"] = render_color(player.bitmap,*point) == expected
  $game_player.instance_variable_set(:@bush_depth,0)
  player.update
  render_snapshot("viridian-render")
  before_refresh = $render_owned_bitmaps.dup
  player.refreshOutfit
  $scene.updateSpritesets
  result["base_released_on_refresh"] = base_owners.all?(&:disposed?)
  base_owners = (player.instance_variable_get(:@base_bitmaps) || {}).values.map(&:last)
  result["released_on_refresh"] = before_refresh.all?(&:disposed?)
  $scene.dispose
  result["released_on_dispose"] = $render_owned_bitmaps.all?(&:disposed?)
  result["base_released_on_dispose"] = base_owners.all?(&:disposed?)
  $scene = nil
  File.write(File.join($kif_test_directory,"map-render-result.json"), KIFMultiplayer::WireJSON.dump(result))
  $kif_test_log.call("MAP_RENDER_RESULT " + KIFMultiplayer::WireJSON.dump(result))
  unless ENV["KIF_RENDER_BASELINE_DIR"]
    raise "Roof fails to occlude the whole player" unless result["covered_pixel"] == [255,255,0]
    raise "Hat no longer layers above body/hair" unless result["hat_pixel"] == [255,0,0]
    raise "Walking/running repeatedly recomposes outfits" unless result["compositions"] <= 2 && result["unique_composites"] == 2
    raise "Outfit bitmaps leak after refresh/dispose" unless result["released_on_refresh"] && result["released_on_dispose"]
    raise "Base cache lost ownership after RPG cache clear" unless result["base_cache_survives_rpg_clear"]
    raise "Base actions leak after refresh/dispose" unless result["base_released_on_refresh"] && result["base_released_on_dispose"]
    raise "Grass reverted the player to the unclothed bitmap" unless result["grass_preserves_clothes"]
  end
  $kif_test_log.call("MAP_RENDER_PASS")
rescue Exception => error
  $kif_test_log.call("MAP_RENDER_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  raise
ensure
  $scene.dispose if $scene.is_a?(Scene_Map)
end
exit
