# Explicit diagnostic only. Loads real final Bitmap wrappers, never player saves.
module Kernel
  def puts(*values)
    values.each { |value| System.puts(value.to_s) }
  end
end

module KIFAndroidFontSmoke
  def self.load_scripts(path)
    names = Dir.entries(path).reject { |name| name == "." || name == ".." }.sort
    files, folders = names.partition { |name| !File.directory?(File.join(path, name)) }
    files.each do |name|
      file = File.join(path, name)
      eval(File.read(file), TOPLEVEL_BINDING, file)
    end
    folders.each do |name|
      next if path == "Data/Scripts" && name == "999_Main"
      load_scripts(File.join(path, name))
    end
  end

  def self.coverage(bitmap)
    count, rows = 0, []
    bitmap.height.times do |y|
      occupied = false
      bitmap.width.times do |x|
        next if bitmap.get_pixel(x, y).alpha == 0
        count += 1
        occupied = true
      end
      rows << y if occupied
    end
    { "pixels" => count, "firstRow" => rows.first, "lastRow" => rows.last,
      "inkHeight" => rows.length }
  end

  def self.run
    load "kif_android_preload.rb"
    load_scripts("Data/Scripts")
    config = HTTPLite::JSON.parse(File.read("mkxp.json"))
    mode = config.fetch("fontHeightReporting").to_i
    puts "KIF_FONT_BEGIN mode=#{mode} ruby=#{RUBY_VERSION} final_draw=#{Bitmap.instance_method(:draw_text).source_location.inspect}"
    fonts = [["Power Green", 29], ["Power Green Small", 25],
      ["Power Green Narrow", 29], ["Power Red and Green", 26],
      ["Power Red and Blue", 24], ["Power Red and Blue Intl", 24],
      ["Power Clear", 29], ["Power Clear Bold", 29]]
    screen = Bitmap.new(512, 640)
    screen.fill_rect(0, 0, 512, 640, Color.new(32, 40, 56))
    results = []
    fonts.each_with_index do |(name, size), index|
      reference, actual = Bitmap.new(240, 64), Bitmap.new(240, 64)
      [reference, actual].each do |bitmap|
        bitmap.font.name = name
        bitmap.font.size = size
        bitmap.font.color = Color.new(248, 248, 248)
        bitmap.font.shadow = false if bitmap.font.respond_to?(:shadow=)
        bitmap.font.outline = false if bitmap.font.respond_to?(:outline=)
      end
      text = "Agjpqy\u00e9"
      reference.mkxp_draw_text(0, 0, 240, 64, text)
      actual.draw_text(0, 0, 240, 32, text)
      expected, observed = coverage(reference), coverage(actual)
      result = { "font" => name, "exists" => Font.exist?(name), "size" => size,
        "reportedHeight" => actual.text_size(text).height,
        "reference" => expected, "actual" => observed,
        "complete" => expected["pixels"] > 0 && expected["pixels"] == observed["pixels"] }
      results << result
      puts "KIF_FONT_SAMPLE #{HTTPLite::JSON.stringify(result)}"
      # Two columns: unclipped native reference / game's final draw_text path.
      screen.blt(8, index * 80, reference, Rect.new(0, 0, 240, 64))
      screen.blt(264, index * 80 + 16, actual, Rect.new(0, 0, 240, 64))
      reference.dispose
      actual.dispose
    end
    output = File.join(ENV.fetch("KIF_ANDROID_FILES"), "font-probe-mode-#{mode}")
    File.binwrite(output + ".json", HTTPLite::JSON.stringify({ "mode" => mode, "fonts" => results }))
    screen.to_file(output + ".png")
    sprite = Sprite.new
    sprite.bitmap = screen
    sprite.zoom_x = sprite.zoom_y = 0.6
    sprite.x = 102
    puts "KIF_FONT_#{results.all? { |r| r["complete"] } ? "PASS" : "CLIPPED"} mode=#{mode} complete=#{results.count { |r| r["complete"] }}/#{results.length}"
    loop { Graphics.update; Input.update }
  rescue Exception => error
    puts "KIF_FONT_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}"
    raise
  end
end
KIFAndroidFontSmoke.run
