# Run with portable Ruby; this does not load the game or any player save.
require "fileutils"
require "tmpdir"

module System
  class << self
    attr_accessor :android_host

    def is_android?
      !!@android_host
    end

    def data_directory
      "desktop-save-directory/"
    end
  end
end

module HTTPLite
  class << self
    attr_reader :calls

    def get(*args)
      (@calls ||= []) << [:get, args]
      { :status => 200, :body => "desktop response", :args => args }
    end

    def post_body(*args)
      (@calls ||= []) << [:post_body, args]
      { :status => 200, :body => "desktop response", :args => args }
    end
  end
end

ROOT = File.expand_path("../..", __dir__)
PRELOAD = File.join(ROOT, "android/ruby/kif_android_preload.rb")
load File.join(ROOT, "Data/Scripts/000_Platform.rb")
load File.join(ROOT, "Data/Scripts/001_Technical/002_RubyUtilities.rb")
load File.join(ROOT, "Data/Scripts/001_Technical/002_Files/001_FileTests.rb")

checks = 0
assert = lambda do |condition, message|
  raise message unless condition
  checks += 1
end

original_save_dir = ENV["KIF_SAVE_DIR"]
begin
  System.android_host = false
  ENV.delete("KIF_SAVE_DIR")
  load PRELOAD
  assert.call(System.data_directory == "desktop-save-directory/", "desktop preload changed save directory")
  assert.call(KIF::Platform.desktop_tools?, "desktop tools were blocked on Windows")
  assert.call(KIF::Platform.network_available?, "desktop network was blocked")
  desktop_path = "Graphics\\titles\\loading_screen.png"
  assert.call(KIF::Platform.read_path(desktop_path).equal?(desktop_path), "desktop read path was changed")
  first_time = KIF::Platform.monotonic_seconds
  assert.call(KIF::Platform.monotonic_seconds >= first_time, "platform timeout clock went backwards")

  headers = { "Authorization" => "test-value" }
  assert.call(KIF::Platform.http_get("https://example.invalid", headers)[:args] == ["https://example.invalid", headers], "desktop GET arguments changed")
  args = ["https://example.invalid", "body", "application/json", headers]
  assert.call(KIF::Platform.http_post_body(*args)[:args] == args, "desktop POST arguments changed")
  assert.call(KIF::Platform.http_post_body(*args.first(3))[:args] == args.first(3), "desktop three-argument POST changed")

  System.android_host = true
  native_calls = HTTPLite.calls.length
  assert.call(!KIF::Platform.network_available?, "Android network must fail closed before secure adapter installation")
  assert.call(!KIF::Platform.desktop_tools?, "Android exposed desktop tools")
  assert.call(KIF::Platform.http_get("https://example.invalid")[:status] == 0, "Android GET did not return a failure response")
  assert.call(KIF::Platform.http_post_body(*args)[:status] == 0, "Android POST did not return a failure response")
  assert.call(HTTPLite.calls.length == native_calls, "Android called unverified native HTTP")
  assert.call(!KIF::Platform.open_android_url("https://example.invalid"), "Android URL opener must report missing capability")

  # Simulate the Ruby 3.2+ removed APIs even if a development Ruby provides them.
  class << File
    remove_method :exists? if singleton_methods(false).include?(:exists?)
  end
  class << Dir
    remove_method :exists? if singleton_methods(false).include?(:exists?)
  end

  rejected_missing_path = false
  begin
    load PRELOAD
  rescue RuntimeError => error
    rejected_missing_path = error.message.include?("KIF_SAVE_DIR")
  end
  assert.call(rejected_missing_path, "Android silently used a desktop save path when KIF_SAVE_DIR was missing")
  assert.call(File.exists?(PRELOAD), "Android File.exists? compatibility alias is missing")
  assert.call(Dir.exists?(File.dirname(PRELOAD)), "Android Dir.exists? compatibility alias is missing")

  ENV["KIF_SAVE_DIR"] = "relative/saves"
  rejected_relative_path = false
  begin
    load PRELOAD
  rescue RuntimeError => error
    rejected_relative_path = error.message.include?("absolute")
  end
  assert.call(rejected_relative_path, "Android accepted a relative save path")

  temporary_root = File.join(ROOT, "temp")
  FileUtils.mkdir_p(temporary_root)
  Dir.mktmpdir("kif-platform-contract-", temporary_root) do |test_root|
    sprite_dir = File.join(test_root, "Graphics", "Titles")
    FileUtils.mkdir_p(sprite_dir)
    sprite_path = File.join(sprite_dir, "Loading.PNG").tr("\\", "/")
    File.binwrite(sprite_path, "sprite")
    assert.call(KIF::Platform.read_path(sprite_path.tr("/", "\\")) == sprite_path, "Android backslashes were not normalized")

    mismatched = File.join(test_root, "graphics", "titles", "loading.png").tr("\\", "/")
    native_exist = File.method(:exist?)
    begin
      # Windows has a case-insensitive filesystem. Simulate Android's missing
      # exact-spelling lookup; the actual directory enumeration remains real.
      File.define_singleton_method(:exist?) { |path| path == mismatched ? false : native_exist.call(path) }
      assert.call(KIF::Platform.read_path(mismatched) == sprite_path, "Android directory casing did not resolve the actual readable path")
      assert.call(safeExists?(mismatched.tr("/", "\\")), "game safeExists? did not use the normalized read path")
      assert.call(pbTryString(mismatched.tr("/", "\\")) == sprite_path, "game pbTryString did not return the actual readable path")
      assert.call(File.safe?(mismatched.tr("/", "\\")), "game File.safe? did not use the normalized read path")
    ensure
      File.define_singleton_method(:exist?, native_exist)
    end
    missing = File.join(test_root, "graphics", "titles", "not-downloaded.png").tr("\\", "/")
    assert.call(KIF::Platform.read_path(missing.tr("/", "\\")) == missing, "missing read path did not preserve normalized spelling")
    download = File.join(sprite_dir, "downloaded.png").tr("\\", "/")
    assert.call(KIF::Platform.read_path(download) == download, "not-yet-downloaded exact path changed")
    File.binwrite(download, "downloaded sprite")
    assert.call(File.file?(KIF::Platform.read_path(download)), "new download stayed hidden behind a stale negative cache")

    requested_path = File.join(test_root, "saves")
    ENV["KIF_SAVE_DIR"] = requested_path
    load PRELOAD
    assert.call(File.directory?(requested_path), "Android preload did not create the save directory")
    expected = requested_path.tr("\\", "/") + "/"
    assert.call(System.data_directory == expected, "Android save directory or trailing separator is wrong")
    load PRELOAD
    assert.call(System.data_directory == expected, "Android preload was not repeatable")
    File.define_singleton_method(:exists?) { |_path| :runtime_file_implementation }
    Dir.define_singleton_method(:exists?) { |_path| :runtime_dir_implementation }
    load PRELOAD
    assert.call(File.exists?(PRELOAD) == :runtime_file_implementation, "preload replaced runtime File.exists? implementation")
    assert.call(Dir.exists?(ROOT) == :runtime_dir_implementation, "preload replaced runtime Dir.exists? implementation")
    class << File
      alias_method :exists?, :exist?
    end
    class << Dir
      alias_method :exists?, :exist?
    end
    File.binwrite(System.data_directory + "File A.rxdata", Marshal.dump({ :slot => "File A", :value => 42 }))
    roundtrip = Marshal.load(File.binread(File.join(requested_path, "File A.rxdata")))
    assert.call(roundtrip[:value] == 42, "independent save path Marshal round trip failed")
  end

  invalid_adapter_rejected = false
  begin
    KIF::Platform.install_http_adapter(Object.new)
  rescue ArgumentError
    invalid_adapter_rejected = true
  end
  assert.call(invalid_adapter_rejected, "invalid secure HTTP adapter was accepted")

  adapter = Object.new
  def adapter.get(*args)
    { :status => 200, :body => "verified adapter", :args => args }
  end
  def adapter.post_body(*args)
    { :status => 201, :body => "verified adapter", :args => args }
  end
  KIF::Platform.install_http_adapter(adapter)
  assert.call(KIF::Platform.network_available?, "installed secure adapter did not enable networking")
  assert.call(KIF::Platform.http_get("https://example.invalid", headers)[:body] == "verified adapter", "Android GET did not use installed adapter")
  assert.call(KIF::Platform.http_post_body(*args)[:status] == 201, "Android POST did not use installed adapter")
  assert.call(HTTPLite.calls.length == native_calls, "Android adapter fell back to unverified native HTTP")

  opened = []
  KIF::Platform.install_url_opener(lambda { |url| opened << url; true })
  assert.call(KIF::Platform.open_android_url("https://example.invalid") && opened == ["https://example.invalid"], "installed Android URL opener was not called")

  puts "PASS: #{checks} platform contract assertions (mocked native host; no game/player saves loaded)"
ensure
  ENV["KIF_SAVE_DIR"] = original_save_dir
end
