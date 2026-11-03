passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  Graphics.resize_screen(Settings::SCREEN_WIDTH, Settings::SCREEN_HEIGHT)
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  check = KIFMultiplayerFeatureTest.method(:check)
  paths = ["Graphics/Pictures/Battle/cursor_command", "Graphics/Pictures/trainer_application_form",
           "Graphics/Pictures/types", "Graphics/Pictures/Pokedex/bg_info", "Graphics/Pictures/map/mapRegion0"]
  originals = {}
  [0, 2, 0].each_with_index do |language, round|
    GameLanguage.load(language)
    paths.each do |path|
      resolved = GameLanguage.bitmap_path(path)
      check.call(resolved.include?("Graphics/Chinese/") == (language == 2), "image language #{round}/#{path}")
      direct = Bitmap.new(path)
      cached = RPG::Cache.load_bitmap_path(path)
      check.call([direct.width, direct.height] == [cached.width, cached.height], "direct/cache dimensions #{round}/#{path}")
      # Font/text differences must survive an English -> Chinese -> English cache cycle.
      signature = []
      (0...direct.height).step(3) do |y|
        (0...direct.width).step(3) do |x|
          c = direct.get_pixel(x,y)
          signature << [c.red, c.green, c.blue, c.alpha]
          cached_color = cached.get_pixel(x,y)
          raise "Stale image cache #{round}/#{path}" unless [cached_color.red,cached_color.green,cached_color.blue,cached_color.alpha] == signature.last
        end
      end
      if round == 0
        originals[path] = signature
      elsif round == 1
        check.call(originals[path] != signature, "Chinese image pixels actually differ #{path}")
      else
        check.call(originals[path] == signature, "English image restored #{path}")
      end
      direct.dispose
      cached.dispose
    end
  end
  GameLanguage.load(2)
  manifest = HTTPLite::JSON.parse(File.binread("Data/localization/zh-CN-images.json"))
  files = manifest["images"].keys
  viewport = Viewport.new(0,0,Graphics.width,Graphics.height)
  files.each_with_index do |path,index|
    source = Bitmap.new(path)
    # Render through the same native Bitmap loader used by game scenes.
    sprite = Sprite.new(viewport)
    sprite.bitmap = source
    sprite.zoom_x = sprite.zoom_y = [1.0, 512.0/source.width, 384.0/source.height].min
    if paths.any? { |candidate| path.downcase.sub(/\.png\z/, "") == candidate.downcase }
      Graphics.update
      Graphics.screenshot(File.join(directory, "image-#{File.basename(path)}"))
    end
    sprite.dispose
    source.dispose
  end
  viewport.dispose
  KIFMultiplayerFeatureTest.log("CHINESE_IMAGES_NATIVE_PASS images=#{files.length} language_rounds=3 direct_and_cache=true normal_player_saves=false")
  passed = true
rescue Exception => error
  $kif_test_log.call("CHINESE_IMAGES_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
