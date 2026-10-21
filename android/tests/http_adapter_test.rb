# Contract tests only: native bridge and mkxp JSON are stand-ins. No TLS/socket I/O.
require "json"
require "tmpdir"
require "fileutils"

class MKXPError < Exception; end

module System
  class << self
    attr_accessor :android_host, :messages
    def is_android?; !!@android_host; end
    def data_directory; "desktop/"; end
    def puts(message); (@messages ||= []) << message; end
  end
end
module HTTPLite
  class << self
    attr_accessor :network_calls
    def get(*args); (@network_calls ||= []) << [:get, args]; { :status => 200, :args => args }; end
    def post_body(*args); (@network_calls ||= []) << [:post_body, args]; { :status => 201, :args => args }; end
  end
  module JSON
    class << self
      attr_accessor :parser_override
      def stringify(value)
        check = lambda do |part|
          if part.is_a?(Hash)
            raise TypeError, "mkxp JSON requires string keys" unless part.keys.all? { |key| key.is_a?(String) }
            part.each_value { |child| check.call(child) }
          elsif part.is_a?(Array)
            part.each { |child| check.call(child) }
          end
        end
        check.call(value)
        ::JSON.generate(value)
      end
      def parse(value)
        return @parser_override.call(value) if @parser_override
        # Pinned mkxp's json2rb checks is_number (including integer) first.
        convert = lambda do |part|
          case part
          when Hash; part.transform_values { |child| convert.call(child) }
          when Array; part.map { |child| convert.call(child) }
          when Numeric; part.to_f
          else part
          end
        end
        convert.call(::JSON.parse(value))
      rescue ::JSON::ParserError
        raise MKXPError, "mocked mkxp JSON parse error"
      end
    end
  end
end
module KIFAndroidBridge
  class << self
    attr_accessor :calls, :responder
    def request(value)
      (@calls ||= []) << ::JSON.parse(value)
      @responder.call(value)
    end
  end
end

root = File.expand_path("../..", __dir__)
adapter_file = File.join(root, "android/ruby/kif_android_http.rb")
platform_file = File.join(root, "Data/Scripts/000_Platform.rb")
preload_file = File.join(root, "android/ruby/kif_android_preload.rb")
saved_environment = %w[KIF_ANDROID_NETWORK KIF_NATIVE_LIB_DIR KIF_SAVE_DIR].to_h { |name| [name, ENV[name]] }
checks = 0
assert = ->(condition, message) { raise message unless condition; checks += 1 }
response = lambda do |body = "ok", status = 200, headers = {}|
  ::JSON.generate({ "status" => status, "headers" => headers, "body" => [body].pack("m0") })
end
failed = lambda do |result, label|
  assert.call(result[:status] == 0 && result[:body] == "" && result[:headers] == {} && result[:error].is_a?(String), label)
end
original_require = Kernel.instance_method(:require)
begin
  ENV.delete("KIF_ANDROID_NETWORK")
  System.android_host = true
  load platform_file
  load adapter_file
  adapter = KIF::AndroidHTTPAdapter.new
  KIFAndroidBridge.calls = []
  KIFAndroidBridge.responder = ->(_json) { response.call }
  failed.call(adapter.get("https://example.invalid"), "default adapter did not fail closed")
  assert.call(KIFAndroidBridge.calls.empty?, "default adapter called native bridge")
  assert.call(!KIF::Platform.network_available?, "default platform enabled network")

  ENV["KIF_ANDROID_NETWORK"] = "1"
  result = adapter.get("https://example.invalid", { "X-Label" => "中文" })
  assert.call(result[:status].is_a?(Integer) && result[:status] == 200, "mkxp Float status was not normalized")
  assert.call(KIFAndroidBridge.calls.last == { "method" => "GET", "url" => "https://example.invalid", "headers" => { "X-Label" => "中文" }, "follow_redirects" => true }, "GET schema changed")
  adapter.get("https://example.invalid", nil, false)
  assert.call(KIFAndroidBridge.calls.last["follow_redirects"] == false, "explicit GET redirect option changed")

  utf8 = "昵称雪色\u0000🌟".encode("UTF-8")
  headers = { "Authorization" => "test-token" }
  saved_headers = headers.dup
  adapter.post_body("https://example.invalid", utf8, "application/json", headers)
  sent = KIFAndroidBridge.calls.last
  assert.call(sent["method"] == "POST" && sent["body"].unpack1("m0").bytes == utf8.bytes && sent["content_type"] == "application/json", "UTF-8/NUL POST body was corrupted")
  assert.call(sent["follow_redirects"] == false, "POST enabled redirect replay")
  assert.call(headers == saved_headers, "adapter mutated caller headers")
  adapter.post_body("https://example.invalid", "body", "application/json")
  assert.call(KIFAndroidBridge.calls.last["headers"] == {} && KIFAndroidBridge.calls.last["follow_redirects"] == false, "three-argument POST changed headers or enabled redirect replay")

  binary = "\x89PNG\r\n\x1a\n".b + (0..255).to_a.pack("C*")
  KIFAndroidBridge.responder = ->(_json) { response.call(binary, 200, { "Content-Type" => "image/png" }) }
  result = adapter.get("https://example.invalid/image.png")
  assert.call(result[:body].bytes == binary.bytes && result[:body].encoding == Encoding::ASCII_8BIT, "binary response was changed or text encoded")
  KIFAndroidBridge.responder = ->(_json) { response.call(utf8, 200, { "content-type" => "application/json; charset=utf-8" }) }
  result = adapter.get("https://example.invalid/config")
  assert.call(result[:body] == utf8 && result[:body].encoding == Encoding::UTF_8, "UTF-8 response was corrupted")
  KIFAndroidBridge.responder = ->(_json) { response.call("not found", 404) }
  assert.call(adapter.get("https://example.invalid")[:status] == 404, "HTTP failure was changed to success/transport failure")

  # Invalid inputs must not cross the native boundary.
  before = KIFAndroidBridge.calls.length
  ["http://example.invalid", "https://user:secret@example.invalid", "https:///missing", "https://example.invalid\r\nx", "https://example.invalid/has space"].each do |url|
    failed.call(adapter.get(url), "invalid URL was accepted")
  end
  failed.call(adapter.get("https://example.invalid", { :symbol => "not supported by mkxp JSON" }), "symbol header key was accepted")
  failed.call(adapter.get("https://example.invalid", { "X" => "bad\nvalue" }), "header injection was accepted")
  failed.call(adapter.get("https://example.invalid", { "X" => "a", "x" => "b" }), "case-duplicate headers were accepted")
  failed.call(adapter.post_body("https://example.invalid", "x" * 65_537, "application/json"), "oversized body crossed bridge")
  failed.call(adapter.post_body("https://example.invalid", "x" * 50_000, "application/json"), "Base64-expanded request JSON crossed limit")
  assert.call(before == KIFAndroidBridge.calls.length, "invalid request called native bridge")

  [{}, [], { "status" => "200", "headers" => {}, "body" => "" }, { "status" => 200.5, "headers" => {}, "body" => "" }, { "status" => 999, "headers" => {}, "body" => "" },
   { "status" => 200, "headers" => [], "body" => "" }, { "status" => 200, "headers" => {}, "body" => "?=" },
   { "status" => 200, "headers" => {}, "body" => "Zh==" }, { "status" => 200, "headers" => {}, "body" => "YQ==\n" },
   { "status" => 200, "headers" => {}, "body" => "", "error" => "unexpected" }].each do |bad|
    KIFAndroidBridge.responder = ->(_json) { ::JSON.generate(bad) }
    failed.call(adapter.get("https://example.invalid"), "bad bridge response was accepted")
  end
  KIFAndroidBridge.responder = ->(_json) { "not JSON" }
  failed.call(adapter.get("https://example.invalid"), "invalid JSON was accepted")
  KIFAndroidBridge.responder = ->(_json) { nil }
  failed.call(adapter.get("https://example.invalid"), "non-string bridge result was accepted")
  KIFAndroidBridge.responder = ->(_json) { " " * (KIF::AndroidHTTPAdapter::MAX_RESPONSE_JSON + 1) }
  failed.call(adapter.get("https://example.invalid"), "oversized JSON was parsed")
  KIFAndroidBridge.responder = ->(_json) { response.call("x" * (KIF::AndroidHTTPAdapter::MAX_RESPONSE_BODY + 1)) }
  failed.call(adapter.get("https://example.invalid"), "decoded response exceeded eight MiB")
  KIFAndroidBridge.responder = ->(_json) { raise IOError, "secret-query-token" }
  result = adapter.get("https://example.invalid")
  failed.call(result, "native bridge exception escaped")
  assert.call(!result[:error].include?("secret-query-token"), "exception message leaked")
  KIFAndroidBridge.responder = ->(_json) { raise MKXPError, "native-json-error" }
  failed.call(adapter.get("https://example.invalid"), "mkxp Exception-based error escaped")
  KIFAndroidBridge.responder = ->(_json) { raise Interrupt, "do not swallow shutdown" }
  interrupted = false
  begin
    adapter.get("https://example.invalid")
  rescue Interrupt
    interrupted = true
  end
  assert.call(interrupted, "adapter swallowed Interrupt")
  KIFAndroidBridge.responder = ->(_json) { ::JSON.generate({ "status" => 0, "headers" => {}, "body" => ["partial"].pack("m0"), "error" => "SocketTimeoutException" }) }
  failed.call(adapter.get("https://example.invalid"), "partial transport failure body was exposed")

  bridge = Object.send(:remove_const, :KIFAndroidBridge)
  failed.call(adapter.get("https://example.invalid"), "missing native bridge did not fail closed")
  Object.const_set(:KIFAndroidBridge, bridge)
  assert.call((HTTPLite.network_calls || []).empty?, "Android fell back to native HTTPLite")

  FileUtils.mkdir_p(File.join(root, "temp"))
  Dir.mktmpdir("kif-http-adapter-", File.join(root, "temp")) do |temporary|
    native = File.join(temporary, "native")
    game = File.join(temporary, "game")
    FileUtils.mkdir_p([native, game])
    ENV["KIF_SAVE_DIR"] = File.join(temporary, "saves")
    ENV["KIF_NATIVE_LIB_DIR"] = native
    library = File.join(native, "libkif_android_bridge.so")
    requested = []
    Kernel.send(:define_method, :require) do |name|
      if name == library
        requested << name
        true
      else
        original_require.bind(self).call(name)
      end
    end
    ENV.delete("KIF_ANDROID_NETWORK")
    load preload_file
    assert.call(requested.empty?, "disabled preload attempted to load native bridge")
    ENV["KIF_ANDROID_NETWORK"] = "1"
    load preload_file
    assert.call(!KIF::Platform.instance_variable_get(:@android_network_bridge_loaded), "missing library marked bridge loaded")
    assert.call(System.messages.any? { |line| line.include?("continuing offline") }, "missing native library was not diagnosed")
    File.binwrite(library, "host-test fixture; never dynamically loaded")
    load preload_file
    assert.call(requested == [library] && KIF::Platform.instance_variable_get(:@android_network_bridge_loaded), "enabled preload did not load pinned native bridge path")
    KIF::Platform.instance_variable_set(:@http_adapter, nil)
    Dir.chdir(game) do
      load platform_file
      assert.call(!KIF::Platform.network_available?, "missing local adapter enabled network")
      FileUtils.cp(adapter_file, File.join(game, "kif_android_http.rb"))
      KIFAndroidBridge.responder = ->(_json) { response.call("Java bridge", 200) }
      load platform_file
      assert.call(KIF::Platform.network_available? && KIF::Platform.http_get("https://example.invalid")[:body] == "Java bridge", "root bootstrap did not install available adapter")
    end
  end
  System.android_host = false
  result = KIF::Platform.http_get("http://desktop.invalid", { "X" => "desktop" })
  assert.call(result[:args] == ["http://desktop.invalid", { "X" => "desktop" }], "Windows network behavior changed")
  puts "PASS: #{checks} HTTP adapter assertions (mock native bridge/JSON; no TLS acceptance claim)"
ensure
  Kernel.send(:define_method, :require, original_require)
  saved_environment.each { |name, value| ENV[name] = value }
  Object.const_set(:KIFAndroidBridge, bridge) if defined?(bridge) && bridge && !defined?(KIFAndroidBridge)
end
