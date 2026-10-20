# Regression for loading real class reopenings from inside the diagnostic module.
require "tmpdir"
require "fileutils"
module System
  def self.puts(value); STDOUT.write(value.to_s + "\n"); end
end
class FontProbeLoaderBitmap
  def draw_text; :native_font_draw; end
end
root = File.expand_path("../..", __dir__)
source = File.read(File.join(root, "android/ruby/android-font-smoke.rb"))
# Load the diagnostic's definitions without starting its Android-only run method.
eval(source.sub(/\nKIFAndroidFontSmoke\.run\s*\z/, "\n"), TOPLEVEL_BINDING, "android-font-smoke.rb")
Dir.mktmpdir("font-probe-loader-", File.join(root, "temp")) do |work|
  File.write(File.join(work, "001_base.rb"), "class FontProbeLoaderBitmap; alias probe_native_draw draw_text; end\n")
  FileUtils.mkdir_p(File.join(work, "nested"))
  File.write(File.join(work, "nested/002_reopen.rb"), "class FontProbeLoaderBitmap; def probe_result; probe_native_draw; end; end\n")
  KIFAndroidFontSmoke.load_scripts(work)
  raise "Global native class was not reopened" unless FontProbeLoaderBitmap.new.probe_result == :native_font_draw
  raise "Loader created a namespaced shadow class" if KIFAndroidFontSmoke.const_defined?(:FontProbeLoaderBitmap, false)
end
puts "PASS: font diagnostic loads class reopenings in the game's top-level scope (real eval/loader)"
