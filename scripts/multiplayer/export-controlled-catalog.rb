# Offline export from trusted installed game data, never from uploaded saves.
require "json"
require "digest"
require "fileutils"
module GameData
  class Item; end unless const_defined?(:Item)
end
root = File.expand_path("../..", __dir__)
source = File.join(root, "Data/items.dat")
items = Marshal.load(File.binread(source))
catalog = {"version" => 1, "rules" => "controlled-assets-v1", "max_characters" => 3,
           "initial_gold" => 1000, "daily_gold" => 100,
           "source_items_sha256" => Digest::SHA256.file(source).hexdigest,
           "items" => %w[POTION POKEBALL FIRESTONE WATERSTONE THUNDERSTONE LEAFSTONE MOONSTONE SUNSTONE DUSKSTONE DAWNSTONE SHINYSTONE].map do |id|
             item = items.fetch(id.to_sym)
             price = item.instance_variable_get(:@price)
             raise "Invalid trusted item price" unless price.is_a?(Integer) && price > 0
             {"id" => id, "name" => item.instance_variable_get(:@real_name).dup.force_encoding("UTF-8"),
              "buy_price" => price, "sell_price" => price / 2, "max_stack" => 999}
           end}
output = File.join(root, "server/multiplayer/catalog-controlled-v1.json")
File.write(output, JSON.pretty_generate(catalog) + "\n", mode: "w:UTF-8")
puts "CONTROLLED_CATALOG_EXPORTED #{output}"
