# Isolated production-map rendering; candidate textures are routed in memory only.
phase = TEXTURE_MAP_PHASE
directory = File.expand_path("output/texture-hd/p1-evidence/native-maps")
Dir.mkdir(directory) unless File.directory?(directory)
logfile = File.join(directory, "#{phase}-result.txt")
passed = false
begin
  $texture_preview_paths = HTTPLite::JSON.parse(File.binread("output/texture-hd/p1-evidence/native-map-paths.json"))[phase]
  module TextureMapPreviewBitmap
    def initialize(*args)
      if args[0].is_a?(String)
        key = File.expand_path(args[0]).tr("\\", "/").downcase.sub(/\.(png|jpg|jpeg)\z/, "")
        args[0] = $texture_preview_paths.fetch(key, args[0])
      end
      super(*args)
    end
  end
  Bitmap.prepend(TextureMapPreviewBitmap)
  load "scripts/multiplayer/test-bootstrap.rb"
  input_hashes = $texture_preview_paths.transform_values { |path| Digest::SHA256.hexdigest(File.binread(path)) }
  File.write(File.join(directory,"#{phase}-inputs.json"), HTTPLite::JSON.stringify(input_hashes))
  Graphics.resize_screen(512,384)
  $GameSpeed = 1
  srand(12345)
  {:@clothes => STARTING_OUTFIT, :@hat => nil, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
   :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each { |key,value| $Trainer.instance_variable_set(key,value) }
  cases = KIFMultiplayer::WireJSON.parse(File.binread("output/texture-hd/p1-evidence/native-map-cases.json"))
  cases = cases.select { |entry| entry["source"] == TEXTURE_MAP_FILTER } if defined?(TEXTURE_MAP_FILTER)
  File.write(logfile,"NATIVE_MAP_BEGIN phase=#{phase} cases=#{cases.length}\n")
  cases.each do |entry|
    $scene.dispose if $scene.is_a?(Scene_Map)
    $scene = Scene_Map.new
    $MapFactory.setup(entry["map_id"])
    $game_player.moveto(entry["width"]/2,entry["height"]/2)
    $game_player.setDefaultCharName("walk",0)
    $MapFactory.maps.each { |map| map.events.each_value { |event| event.erase if [3,4].include?(event.trigger) } }
    $scene.createSpritesets
    5.times { Graphics.update; Input.update; $scene.update }
    renderer = $scene.map_renderer
    active_tiles = renderer.instance_variable_get(:@tiles).flatten.select { |tile| tile.bitmap && tile.visible }
    File.open(logfile,"a") do |file|
      file.puts("DEBUG map=#{entry['map_id']} tileset=#{$game_map.tileset_name.inspect} active=#{active_tiles.length} tone=#{renderer.tone.inspect} offset=#{$game_map.display_x},#{$game_map.display_y}")
      renderer.tilesets.bitmaps.each { |name,bitmap| file.puts("TEXTURE #{name} #{bitmap.width}x#{bitmap.height} pixel=#{bitmap.get_pixel(0,0).inspect}") }
      active_tiles.first(3).each { |tile| file.puts("TILE x=#{tile.x} y=#{tile.y} z=#{tile.z} src=#{tile.src_rect.inspect} opacity=#{tile.opacity}") }
    end
    image = Graphics.snap_to_bitmap
    raise "Wrong native frame size" unless image.width == 512 && image.height == 384
    colored = 0
    (0...384).step(16) do |y|
      (0...512).step(16) do |x|
        color = image.get_pixel(x,y)
        colored += 1 if color.red + color.green + color.blue > 30
      end
    end
    raise "Map tiles did not render: #{entry['map_id']}" if colored < 30
    image.to_file(File.join(directory,"map-#{entry['map_id']}-#{phase}.png"))
    image.dispose
    File.open(logfile,"a") { |file| file.puts("MAP_RENDERED #{entry['map_id']} #{entry['source']}") }
  end
  $scene.dispose
  $scene = nil
  File.open(logfile,"a") { |file| file.puts("NATIVE_MAP_PASS phase=#{phase} maps=#{cases.length}") }
  passed = true
rescue Exception => error
  File.open(logfile,"a") { |file| file.puts("NATIVE_MAP_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
ensure
  exit!(passed ? 0 : 1)
end
