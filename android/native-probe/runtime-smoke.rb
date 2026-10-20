# Deliberately independent of the game and its script loader.
module NativeProbeSmoke
  def self.run
    raise "Graphics.update missing" unless Graphics.respond_to?(:update)
    raise "Bitmap.max_size missing" unless Bitmap.respond_to?(:max_size)
    raise "System.delta missing" unless System.respond_to?(:delta)
    Graphics.resize_screen(512, 384)
    Graphics.frame_rate = 40
    raise "Bundled Power Green font unavailable" unless Font.exist?("Power Green")
    bitmap = Bitmap.new(512, 384)
    bitmap.fill_rect(0, 0, 512, 384, Color.new(25, 38, 55))
    text = Bitmap.new(512, 80)
    text.font.name = "Power Green"
    text.font.size = 28
    text.draw_text(0, 0, 512, 64, "Native Ruby Probe / Agjpqy 0123", 1)
    ink = 0
    text.height.times { |y| text.width.times { |x| ink += 1 if text.get_pixel(x, y).alpha > 0 } }
    raise "Font produced no pixels" if ink.zero?
    bitmap.blt(0, 60, text, Rect.new(0, 0, 512, 80))
    text.dispose
    bitmap.font.name = "Power Green"
    bitmap.font.size = 24
    bitmap.draw_text(0, 140, 512, 48, "Ruby #{RUBY_VERSION} / 120 frames", 1)
    sprite = Sprite.new
    sprite.bitmap = bitmap
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    120.times { Graphics.update; Input.update }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    { "frames" => 120, "elapsedSeconds" => elapsed, "fontInkPixels" => ink,
      "maximumTexture" => Bitmap.max_size, "sprite" => sprite, "bitmap" => bitmap }
  end
end
