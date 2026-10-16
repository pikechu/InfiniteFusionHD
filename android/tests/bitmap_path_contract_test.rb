# Real preload/native-constructor boundary with a recording Bitmap stand-in.
# Does not run RGSS rendering or read player saves.
require "tmpdir"
require "fileutils"

module System
  class << self
    attr_accessor :android_host
    def is_android?; !!@android_host; end
    def data_directory; "desktop/"; end
    def puts(_message); end
  end
end
class Bitmap
  attr_reader :received
  def initialize(*args); @received = args; end
end

root = File.expand_path("../..", __dir__)
preload = File.join(root, "android/ruby/kif_android_preload.rb")
checks = 0
assert = ->(condition, label) { raise label unless condition; checks += 1 }
saved_env = ENV["KIF_SAVE_DIR"]
original_exist = File.method(:exist?)
original_file = File.method(:file?)
begin
  System.android_host = false
  ancestors = Bitmap.ancestors.dup
  load preload
  desktop_name = "Graphics\\titles\\loading_screen"
  assert.call(Bitmap.ancestors == ancestors, "Windows preload installed a Bitmap hook")
  assert.call(Bitmap.new(desktop_name).received[0].equal?(desktop_name), "Windows Bitmap argument changed")

  FileUtils.mkdir_p(File.join(root, "temp"))
  Dir.mktmpdir("kif-bitmap-path-", File.join(root, "temp")) do |temporary|
    ENV["KIF_SAVE_DIR"] = File.join(temporary, "saves")
    System.android_host = true
    load preload # Matches actual startup: hook before 000_Platform defines read_bitmap_path.
    assert.call(Bitmap.new("before-platform").received == ["before-platform"], "early constructor required the later platform helper")
    load File.join(root, "Data/Scripts/000_Platform.rb")
    FileUtils.mkdir_p(File.join(temporary, "Graphics/Titles"))
    actual = File.join(temporary, "Graphics/Titles/Loading_Screen.PNG").tr("\\", "/")
    File.binwrite(actual, "recording-constructor fixture")
    # The host is Windows. Simulate Linux's exact-spelling existence checks
    # while retaining actual File/Dir enumeration and path resolution.
    exact = lambda do |path|
      expanded = File.expand_path(path).tr("\\", "/")
      base = temporary.tr("\\", "/")
      next original_exist.call(path) unless expanded.start_with?(base + "/")
      current = base
      valid = expanded[(base.length + 1)..-1].split("/").all? do |part|
        next false unless File.directory?(current) && Dir.entries(current).include?(part)
        current = File.join(current, part)
        true
      end
      valid && original_exist.call(path)
    end
    File.define_singleton_method(:exist?) { |path| exact.call(path) }
    File.define_singleton_method(:file?) { |path| exact.call(path) && original_file.call(path) }
    request = File.join(temporary, "graphics/titles/loading_screen").tr("/", "\\")
    assert.call(KIF::Platform.read_bitmap_path(request) == actual, "extensionless mixed-case path did not resolve")
    assert.call(Bitmap.new(request).received == [actual], "native Bitmap boundary received the unresolved string")
    assert.call(Bitmap.new(request, true).received == [actual, true], "Bitmap optional argument changed")
    assert.call(Bitmap.new(128, 64).received == [128, 64], "numeric Bitmap dimensions changed")
    wrapper = Class.new(Bitmap) { def initialize(path); super(path); end }
    assert.call(wrapper.new(request).received == [actual], "BitmapWrapper super bypassed the central hook")
    load preload
    assert.call(Bitmap.ancestors.count(KIF::AndroidBitmapPathInitialization) == 1, "repeated preload installed duplicate hooks")
    File.define_singleton_method(:exist?, original_exist)
    File.define_singleton_method(:file?, original_file)
    System.android_host = false
    assert.call(KIF::Platform.read_bitmap_path(desktop_name).equal?(desktop_name), "Windows helper changed the original object")
    assert.call(Bitmap.new(desktop_name).received[0].equal?(desktop_name), "existing hook altered a non-Android argument")
  end
  puts "PASS: #{checks} Bitmap constructor/path assertions (mock native constructor; no rendering claim)"
ensure
  File.define_singleton_method(:exist?, original_exist)
  File.define_singleton_method(:file?, original_file)
  ENV["KIF_SAVE_DIR"] = saved_env
end
