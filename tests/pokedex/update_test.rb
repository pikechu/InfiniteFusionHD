# Isolated updater regression tests. Native JSON/game loading has a separate probe.
require "json"
require "fileutils"
require "tmpdir"
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
class MKXPError < Exception; end
module System
  def self.is_android?; false; end
end
module HTTPLite
  class << self
    attr_accessor :response, :failure, :requests
    def get(url, *)
      self.requests ||= []
      requests << url
      raise failure if failure
      response
    end
  end
  module JSON
    def self.native_numbers(value)
      case value
      when Hash then value.transform_values { |item| native_numbers(item) }
      when Array then value.map { |item| native_numbers(item) }
      when Integer then value.to_f
      else value
      end
    end
    def self.parse(text)
      native_numbers(::JSON.parse(text))
    rescue ::JSON::ParserError
      raise MKXPError, "native JSON failure"
    end
    def self.stringify(value); ::JSON.generate(value); end
  end
end
load "Data/Scripts/000_Platform.rb"
load "Data/Scripts/001_Technical/002_Files/003_HTTP_Utilities.rb"
load "Data/Scripts/052_AddOns/HttpCalls.rb"
load "Data/Scripts/052_AddOns/PokedexEntries.rb"
load "Data/Scripts/RemoteUrls.rb"
def echoln(*); end
$PokemonSystem = Struct.new(:download_sprites).new(0)
checks = 0
verify = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
record = lambda { |text, author = "KIF author"| {"sprite" => "1.2a.png", "entry" => text, "author" => author} }
local = [record.call("KIF-only text"), record.call("Shared text")]
new_text = record.call("中文 \"quote\" \\ newline\n😀", "IF author")
incoming = [local[1], new_text, new_text.dup, record.call("New interpretation", "Other author"),
            record.call("Numeric author", 9000), record.call(222), {"sprite" => "2.3.png"}, "invalid"]
result = KIF::PokedexEntries.merge(local, incoming)
verify.call(result[:entries][0, local.length] == local, "preserves local records and ordering")
verify.call(local.length == 2 && incoming.length == 8, "does not change input collections")
verify.call(result[:added] == 3 && result[:skipped] == 3, "skips malformed records and duplicate incoming text")
verify.call(result[:entries].include?(new_text) && result[:entries].include?(incoming[3]), "keeps distinct text and authors for the same sprite")
verify.call(KIF::PokedexEntries.merge(result[:entries], incoming)[:added] == 0, "repeating updates is idempotent")
verify.call(KIF::PokedexEntries.merge([local[0], local[0]], [])[:entries].length == 2, "does not deduplicate existing local records")
verify.call(Settings::CUSTOM_DEX_FILE_URL.end_with?("/main/Data/pokedex/dex.json"), "uses current upstream custom dex path")
FileUtils.mkdir_p("temp/pokedex")
Dir.mktmpdir("update-", "temp/pokedex") do |directory|
  path = File.expand_path("dex.json", directory)
  Settings.const_set(:CUSTOM_DEX_ENTRIES_PATH, path)
  File.binwrite(path, ::JSON.pretty_generate(local))
  HTTPLite.response = {:status => 200, :body => ::JSON.generate(incoming)}
  verify.call(updateCustomDexFile == path, "production updater succeeds")
  saved = ::JSON.parse(File.binread(path))
  verify.call(saved == result[:entries], "writes Unicode, escaping and all preserved records correctly")
  verify.call(saved.find { |item| item["entry"] == "Numeric author" }["author"].is_a?(Integer), "normalizes native numeric author without losing its value")
  verify.call(HTTPLite.requests.last == Settings::CUSTOM_DEX_FILE_URL, "requests configured current upstream URL")
  before = File.binread(path)
  HTTPLite.response = {:status => 200, :body => ::JSON.generate([local[1]])}
  verify.call(updateCustomDexFile == path && File.binread(path) == before, "stale subset cannot downgrade local data")
  HTTPLite.response = {:status => 200, :body => "[]"}
  verify.call(updateCustomDexFile == path && File.binread(path) == before, "empty response cannot erase data")
  ["<html>error</html>", "{}", "null", "\xff".b, " " * (KIF::PokedexEntries::MAX_BYTES + 1)].each do |body|
    HTTPLite.response = {:status => 200, :body => body}
    verify.call(updateCustomDexFile.nil? && File.binread(path) == before, "invalid response preserves original file")
  end
  HTTPLite.response = {:status => 503, :body => ::JSON.generate(incoming)}
  verify.call(updateCustomDexFile.nil? && File.binread(path) == before, "failed HTTP status preserves file")
  HTTPLite.failure = MKXPError.new("network failure")
  verify.call(updateCustomDexFile.nil? && File.binread(path) == before, "native network failure does not stop startup")
  HTTPLite.failure = nil
  request_count = HTTPLite.requests.length
  $PokemonSystem.download_sprites = 1
  verify.call(updateCustomDexFile.nil? && HTTPLite.requests.length == request_count, "disabled downloads make no request")
  $PokemonSystem.download_sprites = 0
  HTTPLite.response = {:status => 200, :body => ::JSON.generate(local + [record.call("New after failure")])}
  File.binwrite(path, "corrupt local JSON")
  verify.call(updateCustomDexFile.nil? && File.binread(path) == "corrupt local JSON", "invalid local file is retained for recovery")
  File.binwrite(path, before)
  rename = File.method(:rename)
  begin
    File.define_singleton_method(:rename) { |*| raise Errno::EACCES, "simulated replacement failure" }
    verify.call(updateCustomDexFile.nil? && File.binread(path) == before, "replacement failure leaves original intact")
    verify.call(Dir.glob(File.join(directory, ".*.pending")).empty?, "failed update cleans its staging file")
  ensure
    File.define_singleton_method(:rename, rename)
  end
  verify.call(updateCustomDexFile == path, "update can recover after a failed replacement")
  verify.call(::JSON.parse(File.binread(path)).length == local.length + 1 + result[:added], "recovered update retains earlier imported entries")
  System.define_singleton_method(:is_android?) { true }
  adapter = Object.new
  def adapter.get(*); HTTPLite.response; end
  def adapter.post_body(*); raise "unexpected POST"; end
  KIF::Platform.install_http_adapter(adapter)
  before = File.binread(path)
  verify.call(updateCustomDexFile == path && File.binread(path) == before, "Android adapter and path handling retain existing entries")
  System.define_singleton_method(:is_android?) { false }
end
puts "POKEDEX_UPDATE_TEST_PASS checks=#{checks}; native game is a separate probe"
