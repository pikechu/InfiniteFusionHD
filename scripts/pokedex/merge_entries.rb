# Offline maintenance command; the game uses the same merger with native JSON.
# ruby --disable-gems scripts/pokedex/merge_entries.rb upstream.json [local.json]
require "json"
module HTTPLite
  module JSON
    def self.parse(text); ::JSON.parse(text); end
    def self.stringify(value); ::JSON.pretty_generate(value, :indent => "    ") + "\n"; end
  end
end
load File.expand_path("../../Data/Scripts/052_AddOns/PokedexEntries.rb", __dir__)
incoming_path = ARGV[0] or abort "Usage: merge_entries.rb upstream.json [local.json]"
destination = ARGV[1] || File.expand_path("../../Data/pokedex/dex.json", __dir__)
existing = File.file?(destination) ? KIF::PokedexEntries.parse(File.binread(destination)) : []
incoming = KIF::PokedexEntries.parse(File.binread(incoming_path))
result = KIF::PokedexEntries.merge(existing, incoming)
KIF::PokedexEntries.write(destination, result[:entries]) if result[:added] > 0
puts ::JSON.generate({ :existing => existing.length, :incoming => incoming.length,
  :added => result[:added], :skipped => result[:skipped], :total => result[:entries].length })
