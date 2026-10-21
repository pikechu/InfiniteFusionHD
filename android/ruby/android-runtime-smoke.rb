# Executes only when explicitly selected by the debug launcher intent.
# Uses a separate filename and never reads or replaces player saves.
module Kernel
  def puts(*values)
    values.each { |value| System.puts(value.to_s) }
  end
end
begin
  puts "KIF_SMOKE_BEGIN ruby=#{RUBY_VERSION} platform=#{System.platform} runtime=#{System::VERSION}"
  puts "KIF_SMOKE_CLOCK system_delta=#{System.delta.inspect} graphics_delta=#{Graphics.delta.inspect} marshal=#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION}"
  begin
    require "openssl"
    puts "KIF_SMOKE_OPENSSL #{OpenSSL::OPENSSL_VERSION}"
  rescue LoadError => e
    puts "KIF_SMOKE_OPENSSL_UNAVAILABLE #{e.message}"
  end
  required = { :System => [:data_directory, :delta], :Graphics => [:update, :delta], :Bitmap => [:max_size] }
  required.each do |name, methods|
    object = Object.const_get(name)
    methods.each { |method| raise "Missing #{name}.#{method}" unless object.respond_to?(method) }
  end
  Graphics.resize_screen(512, 384)
  bitmap = Bitmap.new(512, 384)
  bitmap.fill_rect(0, 0, 512, 384, Color.new(25, 38, 55))
  bitmap.font.size = 24
  bitmap.draw_text(0, 60, 512, 48, "KIF Android runtime smoke", 1)
  bitmap.draw_text(0, 110, 512, 48, "Ruby #{RUBY_VERSION} / #{System.platform}", 1)
  sprite = Sprite.new
  sprite.bitmap = bitmap
  require "zlib"
  original = { :version => 1, :name => "KIF Android", :values => [1, 2, 3] }
  path = File.join(ENV.fetch("KIF_SAVE_DIR"), "android-runtime-smoke.dat")
  File.open(path, "wb") { |f| Marshal.dump(original, f) }
  restored = File.open(path, "rb") { |f| Marshal.load(f) }
  raise "Marshal mismatch" unless restored == original
  raise "zlib mismatch" unless Zlib::Inflate.inflate(Zlib::Deflate.deflate("KIF")) == "KIF"
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  120.times { Graphics.update; Input.update }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "KIF_SMOKE_PASS texture=#{Bitmap.max_size} frames=120 elapsed=#{elapsed} save=#{path}"
  loop { Graphics.update; Input.update }
rescue Exception => e
  puts "KIF_SMOKE_FAIL #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
  raise
end
