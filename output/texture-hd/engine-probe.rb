# Isolated native image loading/rendering check; no game scripts or player saves.
passed = false
begin
  load "scripts/multiplayer/runtime-preload.rb"
  Graphics.resize_screen(512, 384)
  directory = File.expand_path("output/texture-hd/engine-check")
  Dir.mkdir(directory) unless File.directory?(directory)
  log_path = File.join(directory, "result.txt")
  File.write(log_path, "TEXTURE_ENGINE_BEGIN ruby=#{RUBY_VERSION}\n")
  load "output/texture-hd/engine-assets.rb"
  checks = 0
  TEXTURE_ENGINE_ASSETS.each do |source, width, height|
    bitmap = Bitmap.new(source)
    raise "Wrong dimensions #{source}" unless [bitmap.width, bitmap.height] == [width, height]
    bitmap.dispose
    checks += 1
  end
  TEXTURE_ENGINE_SCENES.each do |theme, background, base_theme|
    %w[before after].each do |version|
      sprites = []
      bitmaps = []
      ["battlebg", "playerbase", "enemybase"].each do |folder|
        source = folder == "battlebg" ? background : "Graphics/Battlebacks/#{folder}/#{theme}.png"
        source = "Graphics/Battlebacks/#{folder}/#{base_theme}.png" unless File.file?(source)
        next unless File.file?(source)
        source = TEXTURE_ENGINE_ORIGINALS.fetch(source, source) if version == "before"
        bitmap = Bitmap.new(source)
        sprite = Sprite.new
        sprite.bitmap = bitmap
        if folder != "battlebg"
          sprite.ox = bitmap.width / 2
          sprite.x = folder == "playerbase" ? 128 : 384
          sprite.y = folder == "playerbase" ? 304 : 176
          sprite.oy = folder == "playerbase" ? bitmap.height : bitmap.height / 2
          sprite.z = 1
        end
        sprites << sprite
        bitmaps << bitmap
      end
      time = theme[/_(eve|night)\z/, 1]
      message = "Graphics/Battlebacks/#{base_theme}_message_#{time}.png"
      message = "Graphics/Battlebacks/#{base_theme}_message.png" unless File.file?(message)
      message = "Graphics/Battlebacks/default_message.png" unless File.file?(message)
      message = TEXTURE_ENGINE_ORIGINALS.fetch(message, message) if version == "before"
      bitmap = Bitmap.new(message)
      sprite = Sprite.new
      sprite.bitmap = bitmap
      sprite.y = 288
      sprite.z = 180
      sprites << sprite
      bitmaps << bitmap
      Graphics.update
      snapshot = Graphics.snap_to_bitmap
      snapshot.to_file(File.join(directory, "#{theme}-#{version}.png"))
      snapshot.dispose
      sprites.each(&:dispose)
      bitmaps.each(&:dispose)
    end
  end
  File.open(log_path, "a") { |file| file.puts("TEXTURE_ENGINE_PASS images=#{checks} renders=#{TEXTURE_ENGINE_SCENES.length * 2}") }
  passed = true
rescue Exception => error
  File.open(log_path, "a") { |file| file.puts("TEXTURE_ENGINE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") } if defined?(log_path) && log_path
ensure
  exit!(passed ? 0 : 1)
end
