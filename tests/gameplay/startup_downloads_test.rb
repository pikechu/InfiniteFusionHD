require "fileutils"
require "tmpdir"
Dir.chdir(File.expand_path("../..", __dir__))
class MKXPError < Exception; end
module System
  def self.is_android?; true; end
end
module HTTPLite
  def self.get(*); raise "unverified native HTTP must never run"; end
end
load "Data/Scripts/000_Platform.rb"
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
load "Data/Scripts/054_Multiplayer/020_AndroidNetwork.rb"
load "Data/Scripts/001_Technical/002_Files/003_HTTP_Utilities.rb"
load "Data/Scripts/052_AddOns/HttpCalls.rb"
load "Data/Scripts/RemoteUrls.rb"
def echoln(*); end
def echo(*); end
def _INTL(text, *args); text.gsub(/\{(\d+)\}/) { args[$1.to_i - 1].to_s }; end
def pbResolveBitmap(*); false; end
$PokemonSystem = Struct.new(:download_sprites).new(0)

module KIFAndroidBridge
  class << self
    attr_accessor :failure, :status
    attr_reader :urls
    def http_async_version; 1; end
    def request_start(raw, *)
      (@urls ||= []) << KIFMultiplayer::WireJSON.parse(raw)["url"]
      raise failure if failure
      1
    end
    def request_poll(*)
      body = urls.last.end_with?(".png") ? "\x89PNG\r\n\x1a\n\xff".b : "fixture credits"
      KIFMultiplayer::WireJSON.dump({"status" => status || 200,
        "headers" => {"content-type" => "application/octet-stream"}, "body" => [body].pack("m0")})
    end
    def request_cancel(*); end
  end
end

checks = 0
verify = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
verify.call(Settings::CREDITS_FILE_URL.end_with?("/Sprite%20Credits.csv"), "startup credits URL encodes its space")
endpoint = KIFMultiplayer::SocketHTTP.parse_url(Settings::CREDITS_FILE_URL)
verify.call(endpoint[:path] == "/Sprite%20Credits.csv", "strict URL validation accepts configured credits URL")
FileUtils.mkdir_p("temp/startup-downloads")
Dir.mktmpdir("regression-", "temp/startup-downloads") do |directory|
  ENV["KIF_ANDROID_FILES"] = File.expand_path(directory)
  FileUtils.mkdir_p(File.join(directory, "Data/sprites"))
  FileUtils.mkdir_p(File.join(directory, "Graphics"))
  credits = File.expand_path("Data/sprites/Sprite Credits.csv", directory)
  Settings.const_set(:CREDITS_FILE_PATH, credits)
  File.binwrite(credits, "bundled credits")
  verify.call(updateCreditsFile == credits && File.binread(credits) == "fixture credits",
    "startup credits pass through Android adapter and safe file writer")
  verify.call(KIFAndroidBridge.urls.last == Settings::CREDITS_FILE_URL, "bridge receives the encoded URL unchanged")
  sprite_directory = File.expand_path("Graphics", directory)
  sprite = File.join(sprite_directory, "1.2.png")
  sprite_url = "https://fixture.invalid/{1}.{2}.png"
  download = lambda { download_sprite(sprite_url, 1, 2, sprite_directory) }
  sprite_body = "\x89PNG\r\n\x1a\n\xff".b
  verify.call(download.call == sprite && File.binread(sprite) == sprite_body, "sprite downloads still succeed")
  failures = [KIFMultiplayer::Error.new("invalid endpoint", "invalid_server"),
    KIFMultiplayer::Error.new("deadline exceeded", "network_timeout"),
    KIFMultiplayer::Error.new("old APK", "network_unavailable"),
    Errno::ETIMEDOUT.new, MKXPError.new("native network failure")]
  failures.each do |error|
    KIFAndroidBridge.failure = error
    verify.call(updateCreditsFile.nil? && File.binread(credits) == "fixture credits",
      "startup continues and retains credits after #{error.class}: #{error.message}")
    verify.call(download.call.nil? && File.binread(sprite) == sprite_body,
      "sprite failure retains existing file after #{error.class}: #{error.message}")
  end
  KIFAndroidBridge.failure = nil
  requests = KIFAndroidBridge.urls.length
  verify.call(download_file("https://fixture.invalid/Sprite Credits.csv", credits).nil?, "malformed optional download is skipped")
  verify.call(KIFAndroidBridge.urls.length == requests, "invalid URLs remain blocked before bridge access")
  KIFAndroidBridge.status = 503
  verify.call(updateCreditsFile.nil? && File.binread(credits) == "fixture credits", "HTTP failure retains existing credits")
  KIFAndroidBridge.failure = Interrupt.new("fixture interruption")
  [lambda { updateCreditsFile }, download].each do |action|
    begin
      action.call
      raise "FAIL interruption was swallowed"
    rescue Interrupt
      verify.call(true, "download preserves runtime interruption")
    end
  end
end
puts "STARTUP_DOWNLOADS_TEST_PASS checks=#{checks}; host Android adapter fixture, no external HTTP or player saves"
