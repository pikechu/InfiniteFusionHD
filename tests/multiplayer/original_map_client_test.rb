require_relative "../../server/multiplayer/native/world"
load File.join(KIFNative::ROOT, "Data/Scripts/054_Multiplayer/027_OriginalWorld.rb")
source = load_data("Data/Map069.rxdata")
tilesets = load_data("Data/Tilesets.rxdata")
base = source.data[0,0,0]
entry = {"id" => 69, "width" => source.width, "height" => source.height, "layers" => 3,
  "tileset" => source.tileset_id, "origin" => [0,0], "full" => false, "tiles" => [[0, base + 1]]}
projection = KIFMultiplayer::OriginalMapProjection.new(entry, tilesets)
raise "Server tile changes were not displayed" unless projection.data[0,0,0] == base + 1
projection.apply(entry.merge("tiles" => []))
raise "Reverted tiles did not return to the original map" unless projection.data[0,0,0] == base
raise "Rendering changed the installed map" unless load_data("Data/Map069.rxdata").data[0,0,0] == base
second = KIFMultiplayer::OriginalMapProjection.new(entry.merge("origin" => [4,-3]), tilesets)
second.instance_variable_set(:@map_id, 70)
factory = KIFMultiplayer::OriginalMapFactoryProjection.new([projection, second])
raise "Connected map projection offsets differ" unless factory.getRelativePos(69, 1, 2, 70, 3, 4) == [6,-1]
puts "ORIGINAL_MAP_CLIENT_DIFF_REVERT_AND_LOCAL_RESOURCE_ISOLATION_PASS"
