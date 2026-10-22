check = UpstreamTest.method(:check)
entry = GameData::TrainerModern.allocate
entry.define_singleton_method(:isGymBattle) { false }
entry.define_singleton_method(:replace_species_to_randomized_regular) { |*| :RANDOMIZED }
entry.define_singleton_method(:replace_species_to_randomized_gym) { |*| :GYM_RANDOMIZED }
$game_switches[SWITCH_DONT_RANDOMIZE] = true
$game_switches[SWITCH_FIRST_RIVAL_BATTLE] = false
check.call(entry.replace_species_to_randomized(:PIKACHU, :fixture, 0) == :PIKACHU, "modern protected trainer retains species")
$game_switches[SWITCH_DONT_RANDOMIZE] = false
check.call(entry.replace_species_to_randomized(:PIKACHU, :fixture, 0) == :RANDOMIZED, "ordinary randomizer remains enabled")
$game_switches[SWITCH_FIRST_RIVAL_BATTLE] = true
check.call(entry.replace_species_to_randomized(:PIKACHU, :fixture, 0) == :PIKACHU, "first rival exception retained")
$game_switches[SWITCH_FIRST_RIVAL_BATTLE] = false
$game_switches[SWITCH_RANDOMIZE_GYMS_SEPARATELY] = true
entry.define_singleton_method(:isGymBattle) { true }
check.call(entry.replace_species_to_randomized(:PIKACHU, :fixture, 0) == :GYM_RANDOMIZED, "separate gym randomizer retained")
$game_switches[SWITCH_DONT_RANDOMIZE] = true
check.call(entry.replace_species_to_randomized(:PIKACHU, :fixture, 0) == :PIKACHU, "protection also precedes gym randomizer")
$game_switches[SWITCH_RANDOM_TRAINERS] = true
records = []
GameData::TrainerModern.each { |record| records << record if record.pokemon.any? }
placeholders = [Settings::RIVAL_STARTER_PLACEHOLDER_SPECIES, Settings::VAR_1_PLACEHOLDER_SPECIES, Settings::VAR_2_PLACEHOLDER_SPECIES]
record = records.find { |candidate| candidate.pokemon.none? { |pokemon| placeholders.include?(pokemon[:species]) } }
check.call(!!record, "compiled modern trainer fixture exists")
trainer = record.to_trainer
check.call(trainer.party.map(&:species) == record.pokemon.map { |pokemon| GameData::Species.get(pokemon[:species]).species }, "real modern trainer construction honors protection without a shuffled table")
