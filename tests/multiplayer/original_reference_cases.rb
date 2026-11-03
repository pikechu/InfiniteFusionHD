# Shared inputs and observations for differential checks against real Game.exe.
module KIFOriginalReference
  def self.reset
    $PokemonSystem = PokemonSystem.new
    $PokemonTemp = PokemonTemp.new
    $game_temp = Game_Temp.new
    $game_switches = Game_Switches.new
    $game_variables = Game_Variables.new
    $PokemonGlobal = PokemonGlobalMetadata.new
    $Trainer = Player.new("Reference", :POKEMONTRAINER_Red)
    $Trainer.id = 123_456
    $PokemonBag = PokemonBag.new
    $PokemonStorage = PokemonStorage.new
  end
  def self.pokemon(species, move)
    result = Pokemon.new(species, 50)
    GameData::Stat.each_main { |stat| result.iv[stat.id] = 15; result.ev[stat.id] = 0 }
    result.personalID = 1234
    result.ability_index = 0
    result.ability = nil
    result.nature = :HARDY
    result.moves = [Pokemon::Move.new(move)]
    result.calc_stats
    result.heal
    result
  end
  def self.observe(pokemon)
    {"species" => pokemon.species.to_s, "level" => pokemon.level, "hp" => pokemon.hp,
     "status" => pokemon.status.to_s, "status_count" => pokemon.statusCount,
     "exp" => pokemon.exp, "ev" => pokemon.ev.transform_keys(&:to_s),
     "item" => pokemon.item_id&.to_s, "ability" => pokemon.ability_id&.to_s,
     "moves" => pokemon.moves.map { |move| [move.id.to_s, move.pp] },
     "stats" => [pokemon.totalhp, pokemon.attack, pokemon.defense, pokemon.spatk, pokemon.spdef, pokemon.speed]}
  end
  def self.run(ids)
    observations = {}
    ids.each do |id|
      Graphics.update
      begin
        reset
        srand(1234)
        own = pokemon(:MEW, id.to_sym)
        enemy = pokemon(:SNORLAX, :SPLASH)
        $Trainer.party = [own]
        scene = KIFNative::Scene.new
        battle = PokeBattle_Battle.new(scene, [own], [enemy], $Trainer, nil)
        battle.showAnims = false
        srand(1234)
        fiber = Fiber.new { battle.pbStartBattle }
        prompt = fiber.resume
        30.times do
          break if !fiber.alive? || battle.turnCount > 0
          value = case prompt.fetch("kind")
                  when "confirm" then false
                  when "target" then 1
                  when "item" then nil
                  else 0
                  end
          prompt = fiber.resume(value)
        end
        observations[id] = {"party" => observe(own), "enemy" => observe(enemy), "round" => battle.turnCount,
                            "decision" => battle.decision, "weather" => battle.field.weather.to_s,
                            "terrain" => battle.field.terrain.to_s, "stages" => battle.battlers.map { |b| b.stages.transform_keys(&:to_s) }}
      rescue StandardError => error
        observations[id] = {"error" => error.class.name, "message" => error.message}
      end
    end
    {"catalog" => {"moves" => GameData::Move::DATA.values.uniq.length,
                    "items" => GameData::Item::DATA.values.uniq.length,
                    "species" => GameData::Species::DATA.values.uniq.length,
                    "abilities" => GameData::Ability::DATA.values.uniq.length}, "cases" => observations}
  end
end
