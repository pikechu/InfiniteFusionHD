# Trusted offline game-data export. Network payloads never enter Marshal.load.
require "json"
require "digest"
module Settings; MAXIMUM_LEVEL = 100; end
def _INTL(value, *); value; end
module GameData
  class Species; end
  class Move; end
  class Type; end
  class Trainer; end
  class Encounter; end
  module InstanceMethods; end
  module ClassMethodsSymbols
    def register(hash); self::DATA[hash[:id]] = new(hash); end
  end
end
module RPG; class MapInfo; end; end
root = File.expand_path("../..", __dir__)
read = ->(name) { Marshal.load(File.binread(File.join(root, "Data", name))) }
field = ->(object, name) { object.instance_variable_get("@#{name}") }
supported_codes = %w[000 001 002 003 005 006 007 008 00A 00B 00C 00D 00E 00F 013 06B 06D 0BD 0C0 0D5 0D9 0DC 0DD]
status_moves = %w[GROWL LEER TAILWHIP SANDATTACK SMOKESCREEN STRINGSHOT SCARYFACE GROWTH SWORDSDANCE NASTYPLOT CALMMIND AGILITY DEFENSECURL HARDEN WITHDRAW AMNESIA IRONDEFENSE DOUBLETEAM FOCUSENERGY PROTECT DETECT]
moves = {}
read.call("moves.dat").values.uniq.each do |move|
  id = field.call(move, "id").to_s
  next unless supported_codes.include?(field.call(move, "function_code")) || status_moves.include?(id)
  moves[id] = %w[real_name function_code base_damage type category accuracy total_pp effect_chance priority flags].to_h { |key| [key, field.call(move, key)] }
end
species = {}
read.call("species.dat").values.uniq.each do |entry|
  next unless field.call(entry, "form") == 0
  id = field.call(entry, "id").to_s
  next unless id.match?(/\A[A-Z0-9_]+\z/)
  species[id] = %w[id_number real_name type1 type2 base_stats evs base_exp growth_rate catch_rate egg_groups gender_ratio evolutions].to_h { |key| [key, field.call(entry, key)] }
  species[id]["moves"] = field.call(entry, "moves").select { |_, move| moves.key?(move.to_s) }
  species[id]["tutor_moves"] = field.call(entry, "tutor_moves").select { |move| moves.key?(move.to_s) }
end
types = read.call("types.dat").values.uniq.to_h do |entry|
  [field.call(entry, "id"), %w[weaknesses resistances immunities].to_h { |key| [key, field.call(entry, key)] }]
end
load File.join(root, "Data/Scripts/010_Data/001_Hardcoded data/001_GrowthRate.rb")
growth = GameData::GrowthRate::DATA.to_h { |id, entry| [id, (1..100).map { |level| entry.minimum_exp_for_level(level) }] }
trainers = read.call("trainers.dat").values.uniq
names = ["Mimi", "Brock", "Misty", "Lt. Surge", "Erika", "Koga", "Sabrina", "Blaine", "Giovanni", "Lorelei", "Bruno", "Agatha", "Lance", "Blue"]
stages = names.each_with_index.map do |name, index|
  trainer = trainers.find do |entry|
    id = field.call(entry, "id")
    id[1] == name && id[2] == 0 && (index == 0 || id[0].to_s.start_with?(index <= 8 ? "LEADER_" : index <= 12 ? "ELITEFOUR_" : "CHAMPION"))
  end
  raise "Missing trusted campaign trainer #{name}" unless trainer
  party = field.call(trainer, "pokemon").map { |mon| {"species" => mon.fetch(:species), "level" => mon.fetch(:level)} }
  {"id" => "chapter-#{index}", "name" => name, "trainer_key" => field.call(trainer, "id"), "party" => party,
   "gold" => party.map { |mon| mon["level"] }.max * 50, "level_cap" => [10,15,23,29,36,39,46,52,58,60,62,64,66,100][index]}
end
map_infos = read.call("MapInfos.rxdata")
regions = []
read.call("encounters.dat").values.uniq.each do |entry|
  next unless field.call(entry, "version") == 0
  rows = field.call(entry, "types")[:Land]
  next unless rows && !rows.empty?
  map = field.call(entry, "map")
  regions << {"id" => "map-#{map}", "map_id" => map, "name" => field.call(map_infos.fetch(map), "name"),
              "encounters" => rows.map { |weight, id, low, high| {"weight" => weight, "species" => id, "min_level" => low, "max_level" => high} }}
end
catalog = {"version" => 1, "rules" => "controlled-adventure-v1", "species" => species, "moves" => moves,
           "types" => types, "growth" => growth, "stages" => stages, "regions" => regions,
           "starters" => %w[BULBASAUR CHARMANDER SQUIRTLE], "level_max" => 100,
           "daily_encounter_limit" => 200, "storage_limit" => 180, "training_cost_per_ev" => 20,
           "relearn_cost" => 100, "heal_cost" => 0, "breed_cost" => 500, "hatch_seconds" => 300,
           "fusion_cost" => 500, "evolution_cost" => 200,
           "policy" => {"abilities" => false, "held_items" => false, "weather" => false,
             "unsupported_moves" => "not_available", "campaign" => "server_chapters_from_installed_trainers",
             "legacy_import" => false},
           "source_sha256" => %w[species.dat moves.dat types.dat trainers.dat encounters.dat MapInfos.rxdata].to_h { |name| [name, Digest::SHA256.file(File.join(root,"Data",name)).hexdigest] }}
path = File.join(root, "server/multiplayer/catalog-controlled-adventure-v1.json")
File.write(path, JSON.pretty_generate(catalog) + "\n", mode: "w:UTF-8")
puts "CONTROLLED_ADVENTURE_EXPORTED species=#{species.length} moves=#{moves.length} regions=#{regions.length} stages=#{stages.length}"
