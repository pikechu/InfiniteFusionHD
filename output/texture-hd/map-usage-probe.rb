# Read only production map/tileset metadata; no player saves or game scripts.
passed = false
begin
  tilesets = load_data("Data/Tilesets.rxdata")
  usage = Hash.new { |hash, key| hash[key] = [] }
  tile_ids = Hash.new { |hash, key| hash[key] = {} }
  Dir["Data/Map[0-9]*.rxdata"].sort.each do |path|
    map = load_data(path)
    raw = map.data.send(:_dump, 0)
    header = raw.byteslice(0,20).unpack("V5")
    raise "Unexpected Table layout: #{path}" unless header[1] == map.width && header[2] == map.height && raw.bytesize == 20 + header[4]*2
    used = raw.byteslice(20,raw.bytesize-20).unpack("v*").uniq.sort
    used.each { |id| tile_ids[map.tileset_id][id] = true }
    usage[map.tileset_id] << {"path" => path, "width" => map.width, "height" => map.height, "used_tile_ids" => used}
  end
  rows = []
  tilesets.each_with_index do |tileset, index|
    next unless tileset
    rows << {"id" => index, "name" => tileset.name, "tileset_name" => tileset.tileset_name,
             "autotile_names" => tileset.autotile_names, "maps" => usage[index], "used_tile_ids" => tile_ids[index].keys.sort}
  end
  File.write("output/texture-hd/p1-evidence/map-usage.json", HTTPLite::JSON.stringify(rows))
  File.write("output/texture-hd/p1-evidence/map-usage-result.txt", "MAP_USAGE_PASS tilesets=#{rows.length} maps=#{usage.values.map(&:length).inject(0,:+)}\n")
  passed = true
rescue Exception => error
  File.write("output/texture-hd/p1-evidence/map-usage-result.txt", "MAP_USAGE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}\n")
ensure
  exit!(passed ? 0 : 1)
end
