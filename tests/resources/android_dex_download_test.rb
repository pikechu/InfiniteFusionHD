require "tmpdir"
require "fileutils"
require "digest/sha2"
root = File.expand_path("../..", __dir__)
module System; def self.is_android?; true; end; end
load File.join(root, "Data/Scripts/000_Platform.rb")
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
Dir.mktmpdir("android-dex-download-", File.join(root, "temp")) do |directory|
  raise "Unsafe fixture directory" unless File.expand_path(directory).start_with?(File.join(root,"temp")+"/")
  Dir.chdir(directory) do
    ENV["KIF_ANDROID_FILES"] = directory
    FileUtils.mkdir_p("Data/pokedex")
    FileUtils.mkdir_p("Graphics/Pictures")
    body = "a" * (9 * 1024 * 1024)
    path = "Data/pokedex/dex_zh.json"
    check.call(KIF::Platform.write_download(path,body), "large Chinese dex writes to app-private storage")
    check.call(Digest::SHA256.hexdigest(File.binread(path)) == Digest::SHA256.hexdigest(body), "large dex writes retain every byte")
    check.call(!KIF::Platform.write_download("Graphics/Pictures/test.png",body), "ordinary images retain8MiB guard")
    check.call(!KIF::Platform.write_download(path,"a" * (32 * 1024 * 1024 + 1)), "oversized dex is rejected")
    check.call(File.size(path) == body.bytesize && Dir.glob("**/*.partial",File::FNM_DOTMATCH).empty?, "rejected write preserves installed dex without partial files")
  end
end
puts "ANDROID_DEX_DOWNLOAD_PASS checks=#{checks} real_network=false player_saves=false"
