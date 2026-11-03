# Explicit live transport check: one small pinned image, no player files.
require "json"
require "fileutils"
require "tmpdir"
root = File.expand_path("../..", __dir__)
module System
  def self.is_android?; false; end
end
%w[000_Platform.rb 054_Multiplayer/001_Client.rb 052_AddOns/SpriteAssets.rb
   052_AddOns/SpriteSheets.rb 053_OfflineResources/001_OfflineResources.rb].each { |name| load File.join(root, "Data/Scripts", name) }
module Graphics
  def self.update; end
end
resources = KIF::OfflineResources
manifest = resources.parse(File.binread(File.join(root, resources::MANIFEST)))
entry = manifest["files"].find { |row| row["path"].end_with?("spritesheets_base/1.png") }
progress = 0
FileUtils.mkdir_p(File.join(root, "temp"))
Dir.mktmpdir("resource-https-", File.join(root, "temp")) do |directory|
  FileUtils.mkdir_p(File.join(directory, "Data"))
  FileUtils.cp(File.join(root, "Data/resource-download.ps1"), File.join(directory, "Data/resource-download.ps1"))
  Dir.chdir(directory) do
    bytes = resources.fetch(entry["url"], entry["size"]) { progress += 1 }
    raise "Downloaded bytes did not pass manifest verification" unless resources.valid_bytes?(entry, bytes)
    raise "No progress callbacks" unless progress > 0
    cdn = resources.fetch('https://infinitefusion.net/customsprites/spritesheets/spritesheets_base/1.png')
    raise "Official CDN range download failed" unless KIF::SpriteSheets.png_header(cdn, :base)
    begin
      resources.fetch(entry["url"], entry["size"]) { raise KIF::OfflineResources::Cancelled }
      raise "Cancellation was ignored"
    rescue KIF::OfflineResources::Cancelled
    end
    begin
      resources.fetch(entry["url"], entry["size"] - 1)
      raise "Oversized response was accepted"
    rescue IOError
    end
    raise "Staging files leaked" unless Dir.glob("Data/offline-resources/*").empty?
    puts "RESOURCE_HTTPS_PASS bytes=#{bytes.bytesize} checksum=#{entry['sha1']} progress_callbacks=#{progress} cancelled=true staging_clean=true"
  end
end
