# Run only through the isolated Game.exe custom-script launcher. Exports
# trusted local game objects as a reviewed JSON catalogue, never a save file.
passed = false
begin
  load "scripts/multiplayer/runtime-preload.rb"
  require "digest/sha2"
  log_path = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "rental-catalog.log")
  log = proc { |value| File.open(log_path, "a") { |file| file.puts(value); file.flush } }
  loader = lambda do |path|
    entries = Dir.entries(path).reject { |entry| entry == "." || entry == ".." }
    files, folders = entries.partition { |entry| !File.directory?(File.join(path, entry)) }
    files.sort.each { |entry| load File.join(path, entry) }
    folders.sort.each do |entry|
      next if path == "Data/Scripts" && entry == "999_Main"
      loader.call(File.join(path, entry))
    end
  end
  loader.call("Data/Scripts")
  $POKEMONDATA_QUEUEING = []
  MessageTypes.loadMessageFile("Data/messages.dat")
  PluginManager.runPlugins
  Dir["Mods/*.rb"].sort.each { |file| load File.expand_path(file) }
  Game.initialize
  SaveData.initialize_bootup_values
  SaveData.load_new_game_values
  $scene = Object.new
  $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
  $game_player.moveto($data_system.start_x, $data_system.start_y)
  $PokemonSystem.download_sprites = 1
  fixtures = [
    [:CHARIZARD, :BLASTOISE, :BLAZE, :LEFTOVERS, [:FLAMETHROWER, :SURF, :AIRSLASH, :PROTECT], :MODEST],
    [:VENUSAUR, :VILEPLUME, :OVERGROW, :BLACKSLUDGE, [:GIGADRAIN, :SLUDGEBOMB, :LEECHSEED, :PROTECT], :CALM],
    [:PIKACHU, :JOLTEON, :VOLTABSORB, :MAGNET, [:THUNDERBOLT, :VOLTSWITCH, :THUNDERWAVE, :PROTECT], :TIMID],
    [:ALAKAZAM, :ESPEON, :SYNCHRONIZE, :LEFTOVERS, [:PSYCHIC, :SHADOWBALL, :CALMMIND, :RECOVER], :TIMID],
    [:MACHAMP, :HERACROSS, :GUTS, :SITRUSBERRY, [:CLOSECOMBAT, :ROCKSLIDE, :BULKUP, :PROTECT], :ADAMANT],
    [:GOLEM, :ONIX, :STURDY, :LEFTOVERS, [:EARTHQUAKE, :ROCKSLIDE, :STEALTHROCK, :PROTECT], :IMPISH],
    [:GENGAR, :UMBREON, :INNERFOCUS, :LEFTOVERS, [:SHADOWBALL, :DARKPULSE, :TOXIC, :PROTECT], :MODEST],
    [:GYARADOS, :KINGDRA, :INTIMIDATE, :LUMBERRY, [:WATERFALL, :DRAGONPULSE, :DRAGONDANCE, :PROTECT], :ADAMANT],
    [:LAPRAS, :ARTICUNO, :PRESSURE, :LEFTOVERS, [:ICEBEAM, :SURF, :ROOST, :TOXIC], :MODEST],
    [:SNORLAX, :BLISSEY, :THICKFAT, :CHESTOBERRY, [:BODYSLAM, :CRUNCH, :REST, :SLEEPTALK], :CAREFUL],
    [:SCIZOR, :SKARMORY, :TECHNICIAN, :METALCOAT, [:BULLETPUNCH, :IRONHEAD, :SWORDSDANCE, :ROOST], :ADAMANT],
    [:DRAGONITE, :FLYGON, :INNERFOCUS, :LIFEORB, [:DRAGONCLAW, :EARTHQUAKE, :FIREPUNCH, :ROOST], :JOLLY]
  ]
  output = nil
  KIFMultiplayer::BattleIsolation.with do
    candidates = fixtures.each_with_index.map do |fixture, index|
      body, head, ability, item, moves, nature = fixture
      species = getFusedPokemonIdFromSymbols(body, head)
      pokemon = Pokemon.new(species, 50, nil, false, false)
      pokemon.name = "Rental #{index + 1}"
      pokemon.personalID = 2026101600 + index
      pokemon.nature = nature
      pokemon.ability = ability
      pokemon.ability_index = 0
      pokemon.instance_variable_set(:@ability2, nil)
      pokemon.instance_variable_set(:@ability2_index, nil)
      pokemon.item = item
      pokemon.shiny = false
      pokemon.moves = moves.map { |move| Pokemon::Move.new(move) }
      KIFMultiplayer::Snapshot::STATS.each do |stat|
        pokemon.iv[stat.to_sym] = 31
        pokemon.ev[stat.to_sym] = 0
        pokemon.ivMaxed[stat.to_sym] = false
      end
      physical = [:ADAMANT, :JOLLY, :IMPISH, :CAREFUL].include?(nature)
      pokemon.ev[physical ? :ATTACK : :SPECIAL_ATTACK] = 252
      pokemon.ev[:SPEED] = 252
      pokemon.ev[:HP] = 4
      pokemon.calc_stats
      pokemon.heal
      snapshot = KIFMultiplayer::Snapshot.export(pokemon)
      imported = KIFMultiplayer::Snapshot.import(snapshot, 50)
      raise "Species changed" unless imported.species == species
      raise "Item changed" unless imported.item_id == item
      raise "Moves changed" unless imported.moves.map { |move| move.id } == moves
      imported.moves.each do |move|
        battle_move = PokeBattle_Move.from_pokemon_move(nil, move)
        raise "Move cannot instantiate" unless battle_move && battle_move.id == move.id
      end
      foe = KIFMultiplayer::Snapshot.import(snapshot, 50)
      opponent = NPCTrainer.new("Catalog validator", $Trainer.trainer_type)
      opponent.party = [foe]
      engine = PokeBattle_Battle.new(Object.new, [imported], [foe], $Trainer, opponent)
      engine.internalBattle = false
      engine.setBattleMode("single")
      engine.pbEnsureParticipants
      engine.pbSetUpSides
      imported.moves.each_with_index do |move, move_index|
        raise "Move cannot register with real battler" unless engine.pbRegisterMove(0, move_index, false)
        engine.battlers[0].moves[move_index].pbTarget(engine.battlers[0])
      end
      log.call("CANDIDATE_PASS index=#{index} species=#{species} item=#{item} moves=#{moves.join(',')} hp=#{imported.totalhp} engine_registered_moves=#{moves.length}")
      {"id" => "rental-v1-#{index + 1}", "body" => body.to_s, "head" => head.to_s,
       "types" => [imported.type1.to_s, imported.type2.to_s].uniq, "snapshot" => snapshot}
    end
    relevant = %w[Data/species.dat Data/moves.dat Data/items.dat Data/abilities.dat Data/types.dat]
    data_files = relevant.each_with_object({}) do |path, values|
      values[path] = Digest::SHA256.hexdigest(File.binread(path)) if File.file?(path)
    end
    compatibility = KIFMultiplayer::Client.new.compatibility
    output = {"version" => 1, "generator" => "native-game-reviewed-rental-v1", "protocol" => KIFMultiplayer::PROTOCOL,
              "game_version" => Settings::GAME_VERSION.to_s, "rules_version" => KIFMultiplayer::RULES_VERSION,
              "native_ruby" => RUBY_VERSION, "data_files" => data_files, "candidates" => candidates,
              "compatibility" => compatibility, "pokemon" => candidates.map { |entry| entry["snapshot"] }}
  end
  path = "server/multiplayer/catalog-rental-v1.json"
  File.open(path, "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump(output)) }
  item_ids = %i[POTION SUPERPOTION HYPERPOTION MAXPOTION FULLRESTORE ANTIDOTE PARALYZEHEAL PARLYZHEAL BURNHEAL ICEHEAL AWAKENING FULLHEAL REVIVE MAXREVIVE ETHER MAXETHER ELIXIR MAXELIXIR POKEBALL GREATBALL ULTRABALL REPEL SUPERREPEL MAXREPEL RARECANDY HPUP PROTEIN IRON CALCIUM ZINC CARBOS FIRESTONE WATERSTONE THUNDERSTONE LEAFSTONE MOONSTONE SUNSTONE]
  missing_items = item_ids.reject { |id| GameData::Item::DATA.key?(id) }
  log.call("TRADING_ITEM_UNAVAILABLE #{missing_items.join(',')}") unless missing_items.empty?
  item_ids -= missing_items
  raise "Required trading test items are missing" unless %i[POTION RARECANDY POKEBALL].all? { |id| item_ids.include?(id) }
  items = item_ids.map do |id|
    item = GameData::Item.get(id)
    raise "Bound item cannot enter trading catalog: #{id}" if item.is_important?
    {"id" => item.id.to_s, "name" => item.name, "tradeable" => true, "price" => item.price, "pocket" => item.pocket}
  end
  item_catalog = {"version" => 1, "compatibility" => output["compatibility"], "items" => items}
  File.open("server/multiplayer/catalog-trading-items-v1.json", "wb") { |file| file.write(KIFMultiplayer::WireJSON.dump(item_catalog)) }
  log.call("TRADING_ITEM_CATALOG_PASS count=#{items.length}")
  log.call("RENTAL_CATALOG_PASS count=#{output['candidates'].length} sha256=#{Digest::SHA256.hexdigest(File.binread(path))}")
  passed = true
rescue Exception => error
  log.call("RENTAL_CATALOG_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  exit!(passed ? 0 : 1)
end
