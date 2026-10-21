require "json"
require "digest/sha2"
require "ostruct"
ROOT = File.expand_path("../..", __dir__) unless defined?(ROOT)
load File.join(ROOT, "Data/Scripts/054_Multiplayer/001_Client.rb")
load File.join(ROOT, "Data/Scripts/054_Multiplayer/007_Rental.rb")
catalog = JSON.parse(File.read(File.join(ROOT, "server/multiplayer/catalog-rental-v1.json")))
catalog_pokemon = catalog["pokemon"] || catalog["candidates"].map { |entry| entry["snapshot"] }

# Registry doubles verify the complete wire schema. Actual existence/import and
# battle move construction are separately verified by rental_catalog_game.rb.
NB_POKEMON = 500 unless defined?(NB_POKEMON)
module GameData; end
registry_values = {
  :Species => [], :Move => catalog_pokemon.flat_map { |pokemon| pokemon["moves"].map { |move| move["id"] } },
  :Ability => catalog_pokemon.flat_map { |pokemon| [pokemon["ability"], pokemon["ability2"]] }.compact,
  :Item => catalog_pokemon.map { |pokemon| pokemon["item"] }.compact,
  :Nature => catalog_pokemon.flat_map { |pokemon| [pokemon["nature"], pokemon["nature_for_stats"]] }.compact,
  :Type => catalog_pokemon.map { |pokemon| pokemon["hidden_power_type"] }.compact
}
registry_values.each do |name, values|
  klass = Class.new
  klass.const_set(:DATA, values.uniq.each_with_object({}) { |value, result| result[value.to_sym] = true })
  klass.define_singleton_method(:exists?) { |value| self::DATA.key?(value.to_s.to_sym) }
  GameData.const_set(name, klass)
end
module KIFMultiplayer
  def self.battle_digest(value); Digest::SHA256.hexdigest(WireJSON.dump(value)); end
  def self.display_text(value); value.to_s.gsub("\\", "＼").gsub("<", "＜").gsub(">", "＞"); end
end
$rental_checks = 0
def rental_assert(condition, message)
  raise message unless condition
  $rental_checks += 1
end
def rental_reject(message)
  begin
    yield
  rescue KIFMultiplayer::Error
    $rental_checks += 1
    return
  end
  raise message
end
class RentalClientFixture
  attr_accessor :responses
  attr_reader :calls
  def initialize; @responses, @calls = [], []; end
  def player_id; "host_id"; end
  def request(*args)
    @calls << args
    response = @responses.shift
    raise response if response.is_a?(Exception)
    response
  end
end
def rental_copy(value); Marshal.load(Marshal.dump(value)); end
pool = catalog_pokemon.each_with_index.map { |snapshot, slot| {"slot" => slot, "snapshot" => snapshot} }
draft = {"id" => "draft_test_0001", "status" => "picking", "pool" => pool,
  "order" => %w[host_id guest_id guest_id host_id host_id guest_id],
  "picks" => {"host_id" => [], "guest_id" => []}, "next_owner_id" => "host_id", "remaining" => (0...12).to_a,
  "deadline" => Time.now.to_f + 30, "reconnect_remaining" => {"host_id" => 60, "guest_id" => 60}, "disconnected" => []}
room = {"code" => "RENTAL1", "mode" => "rental_singles", "host_id" => "host_id", "status" => "drafting", "members" => [{"id" => "host_id"}, {"id" => "guest_id"}], "draft" => draft}
client = RentalClientFixture.new
session = KIFMultiplayer::RentalSession.new(client, room)
rental_assert(session.own_turn? && session.summary.include?("A → B → B"), "ABBAAB ownership missing")
rental_assert(session.candidate_text(0).include?("FLAMETHROWER") && session.candidate_text(0).include?("LEFTOVERS"), "Candidate full moves/item hidden")
rental_assert(session.candidate(11)["snapshot"]["species"].start_with?("B"), "Native fusion catalogue missing")
changed = rental_copy(room)
changed["draft"]["picks"]["host_id"] = [0]
changed["draft"]["remaining"].delete(0)
changed["draft"]["next_owner_id"] = "guest_id"
client.responses = [{"room" => changed}]
session.pick(0)
rental_assert(!session.own_turn? && client.calls.last[2] == {"draft_id" => draft["id"], "pick_index" => 0, "slot" => 0}, "Pick omitted draft/phase identity or selected twice")
rental_reject("Player selected outside their turn") { session.pick(1) }
bad = rental_copy(changed)
bad["draft"]["pool"][0]["snapshot"]["moves"][0]["pp"] = 1
rental_reject("Pool changed within same draft") { session.adopt(bad) }
bad = rental_copy(changed)
bad["draft"]["picks"]["guest_id"] = [0]
rental_reject("Candidate assigned to both players") { session.adopt(bad) }
bad = rental_copy(changed)
bad["draft"]["order"] = %w[host_id guest_id host_id guest_id host_id guest_id]
rental_reject("Invalid selection order accepted") { session.adopt(bad) }
bad = rental_copy(changed)
bad["draft"]["remaining"] << 0
rental_reject("Picked candidate still available") { session.adopt(bad) }
bad = rental_copy(changed)
bad["draft"]["pool"][3] = 5
rental_reject("Malformed pool entry caused unsafe access") { session.adopt(bad) }
complete = rental_copy(room)
complete["draft"].merge!("status" => "complete", "picks" => {"host_id" => [0, 3, 4], "guest_id" => [1, 2, 5]}, "remaining" => (6...12).to_a, "next_owner_id" => nil)
session.adopt(complete)
rental_assert(!session.own_turn?, "Completed draft allowed another pick")
next_cup = rental_copy(room)
next_cup["draft"]["id"] = "draft_test_0002"
next_cup["draft"]["pool"][0]["snapshot"]["moves"][0]["pp"] = 2
session.adopt(next_cup)
rental_assert(session.own_turn? && session.draft["id"] != complete["draft"]["id"], "New cup reused completed draft or was blocked by old pool digest")
bad = rental_copy(room)
bad["draft"]["picks"]["guest_id"] = [0]
bad["draft"]["remaining"].delete(0)
bad["draft"]["next_owner_id"] = "guest_id"
rental_reject("ABBAAB history assigned first pick to wrong owner") { session.adopt(bad) }
client2 = RentalClientFixture.new
session2 = KIFMultiplayer::RentalSession.new(client2, room)
client2.responses = [KIFMultiplayer::UncertainRequest.new("lost commit response"), {"room" => changed}]
rental_reject("Lost response not surfaced") { session2.pick(0) }
rental_assert(client2.calls.map { |call| call[0] } == ["POST", "GET"] && !session2.own_turn?, "Timeout assumed failure before querying draft state")
puts "PASS: #{$rental_checks} rental state checks; catalogue native import proof is separate"
