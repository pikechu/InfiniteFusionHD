# Real local filesystem/fault-injection tests; no HTTP requests or player saves.
require "tmpdir"
require "fileutils"
module System
  class << self
    attr_accessor :android_host, :messages
    def is_android?; !!@android_host; end
    def puts(message); (@messages ||= []) << message; end
  end
end
class MKXPError < Exception; end
def echoln(*_args); end
def echo(*_args); end
def _INTL(message, *values); message.gsub(/\{(\d+)\}/) { values[$1.to_i - 1].to_s }; end
def pbResolveBitmap(_path); nil; end

root = File.expand_path("../..", __dir__)
System.android_host = true
ENV.delete("KIF_ANDROID_NETWORK")
load File.join(root, "Data/Scripts/000_Platform.rb")
load File.join(root, "Data/Scripts/001_Technical/002_Files/003_HTTP_Utilities.rb")
load File.join(root, "Data/Scripts/052_AddOns/HttpCalls.rb")
original_open = File.method(:open)
original_rename = File.method(:rename)
original_env = ENV["KIF_ANDROID_FILES"]
checks = 0
assert = ->(condition, label) { raise label unless condition; checks += 1 }
png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1cAAAAASUVORK5CYII=".unpack1("m0")

fault_io = Class.new do
  def initialize(io, mode); @io, @mode, @writes = io, mode, 0; end
  def binmode; @io.binmode; end
  def write(value)
    @writes += 1
    if @mode == :write
      raise IOError, "injected interrupted write" if @writes > 1
      return @io.write(value.byteslice(0, 7))
    end
    @io.write(value)
  end
  def flush; @io.flush; end
  def fsync; raise IOError, "injected sync failure" if @mode == :fsync; @io.fsync; end
end
begin
  FileUtils.mkdir_p(File.join(root, "temp"))
  Dir.mktmpdir("kif-download-write-", File.join(root, "temp")) do |temporary|
    private_root = File.join(temporary, "files")
    game = File.join(private_root, "content/game")
    graphics = File.join(game, "Graphics")
    data = File.join(game, "Data")
    FileUtils.mkdir_p([graphics, File.join(data, "Scripts"), File.join(private_root, "saves"), File.join(private_root, "backups")])
    ENV["KIF_ANDROID_FILES"] = private_root
    Dir.chdir(game) do
      image = File.join(graphics, "sprite.png")
      assert.call(KIF::Platform.write_download("Graphics/sprite.png", png), "valid PNG write failed")
      assert.call(File.binread(image) == png, "PNG bytes changed")
      old = File.binread(image)
      assert.call(!KIF::Platform.write_download(image, "<html>200 error page</html>"), "HTML was accepted as PNG")
      assert.call(File.binread(image) == old, "bad image overwrote an existing sprite")
      assert.call(KIF::Platform.write_download("Graphics/animation.gif", "GIF89a".b + "\0" * 20), "GIF signature was rejected")
      assert.call(!KIF::Platform.write_download("Graphics/animation.gif", "<html>error</html>"), "HTML was accepted as GIF")
      unicode = "下载配置\u0000🌟"
      assert.call(KIF::Platform.write_download("Data/config.txt", unicode), "UTF-8 download write failed")
      assert.call(File.binread(File.join(data, "config.txt")).bytes == unicode.bytes, "UTF-8/NUL bytes changed")
      assert.call(!KIF::Platform.write_download("Data/config.txt", "x" * (8 * 1024 * 1024 + 1)), "oversized download was written")
      assert.call(File.binread(File.join(data, "config.txt")).bytes == unicode.bytes, "oversized response overwrote prior file")

      outside = File.join(temporary, "outside.txt")
      File.binwrite(outside, "outside")
      assert.call(!KIF::Platform.write_download(outside, "changed") && File.binread(outside) == "outside", "download escaped app storage")
      assert.call(!KIF::Platform.write_download("Graphics/../Data/config.txt", "changed"), "traversal path was accepted")
      save = File.join(private_root, "saves/File A.rxdata")
      File.binwrite(save, "player save sentinel")
      assert.call(!KIF::Platform.write_download(save, "changed") && File.binread(save) == "player save sentinel", "network download modified a save")
      assert.call(!KIF::Platform.write_download(File.join(private_root, "backups/Backup.rxdata"), "changed"), "network download entered backup storage")
      script = File.join(data, "Scripts/RemoteUrls.rb")
      File.binwrite(script, "packaged configuration")
      assert.call(!KIF::Platform.write_download(script, "remote code") && File.binread(script) == "packaged configuration", "download entered unscreened script loader")
      assert.call(!KIF::Platform.write_download("missing-parent/file.txt", "changed") && !File.exist?("missing-parent"), "download created unapproved directory trees")
      ENV.delete("KIF_ANDROID_FILES")
      assert.call(!KIF::Platform.write_download("Data/config.txt", "changed"), "missing private storage environment did not fail closed")
      ENV["KIF_ANDROID_FILES"] = private_root

      target = File.join(data, "atomic.txt")
      File.binwrite(target, "old cache")
      foreign = File.join(data, ".foreign.partial")
      File.binwrite(foreign, "another operation")
      [:write, :fsync].each do |mode|
        File.define_singleton_method(:open) do |path, *args, &block|
          if path.is_a?(String) && path.include?(".kif-download-") && path.end_with?(".partial") && block
            original_open.call(path, *args) { |file| block.call(fault_io.new(file, mode)) }
          else
            original_open.call(path, *args, &block)
          end
        end
        assert.call(!KIF::Platform.write_download(target, "new bytes" * 200), "interrupted #{mode} reported success")
        assert.call(File.binread(target) == "old cache", "interrupted #{mode} replaced the old file")
        assert.call(Dir.children(data).none? { |name| name.include?(".kif-download-") }, "interrupted #{mode} left its partial file")
        assert.call(File.binread(foreign) == "another operation", "interrupted #{mode} cleaned a foreign partial")
        File.define_singleton_method(:open, original_open)
      end
      File.define_singleton_method(:rename) { |_from, _to| raise IOError, "injected rename failure" }
      assert.call(!KIF::Platform.write_download(target, "new bytes"), "failed rename reported success")
      assert.call(File.binread(target) == "old cache" && Dir.children(data).none? { |name| name.include?(".kif-download-") }, "failed rename changed old data or left staging")
      File.define_singleton_method(:rename, original_rename)
      assert.call(KIF::Platform.write_download(target, "new bytes") && File.binread(target) == "new bytes", "successful atomic replacement failed")

      # Exercise actual game download entry points through the centralized writer.
      fake_http = Object.new
      fake_http.define_singleton_method(:get) { |*_args| { :status => 200, :body => png } }
      fake_http.define_singleton_method(:post_body) { |*_args| { :status => 200, :body => "post bytes" } }
      KIF::Platform.install_http_adapter(fake_http)
      $PokemonSystem = Struct.new(:download_sprites).new(0)
      assert.call(pbDownloadData("https://example.invalid/image", "Graphics/from-utility.png") == "" && File.binread("Graphics/from-utility.png") == png, "pbDownloadData bypassed or broke the writer")
      assert.call(pbPostData("http://example.invalid", {}, "Data/post.txt") == "" && File.binread("Data/post.txt") == "post bytes", "pbPostData file path bypassed the writer")
      assert.call(download_file("https://example.invalid/image", "Graphics/from-addon.png") == "Graphics/from-addon.png", "download_file lost its return contract")
      assert.call(File.binread("Graphics/from-addon.png") == png, "download_file wrote different bytes")
      sprite = download_sprite("https://example.invalid/image", 1, 2, graphics)
      assert.call(sprite == File.join(graphics, "1.2.png") && File.binread(sprite) == png, "download_sprite bypassed the writer")
      fake_http.define_singleton_method(:get) { |*_args| { :status => 200, :body => "<html>poison</html>" } }
      assert.call(download_file("https://example.invalid/error", "Graphics/from-addon.png").nil? && File.binread("Graphics/from-addon.png") == png, "download_file poisoned a cached PNG")
      assert.call(download_sprite("https://example.invalid/error", 1, 2, graphics).nil? && File.binread(sprite) == png, "download_sprite poisoned a cached PNG")
      fake_http.define_singleton_method(:get) { |*_args| { :status => 503, :body => "partial" } }
      assert.call(download_file("https://example.invalid/offline", "Graphics/from-addon.png").nil? && File.binread("Graphics/from-addon.png") == png, "HTTP failure changed a cached file")

      System.android_host = false
      opened = []
      File.define_singleton_method(:open) do |path, *args, &block|
        opened << [path, args.first]
        original_open.call(path, *args, &block)
      end
      windows_target = File.join(temporary, "windows.png")
      assert.call(KIF::Platform.write_download(windows_target, "legacy bytes") && File.binread(windows_target) == "legacy bytes", "Windows behavior gained Android validation")
      assert.call(opened.any? { |path, mode| path == windows_target && mode == "wb" }, "Windows direct File.open wb behavior changed")
      File.define_singleton_method(:open, original_open)
    end
  end
  puts "PASS: #{checks} atomic download/file-entry assertions (real local files; no TLS/rendering claim)"
ensure
  File.define_singleton_method(:open, original_open)
  File.define_singleton_method(:rename, original_rename)
  ENV["KIF_ANDROID_FILES"] = original_env
end
