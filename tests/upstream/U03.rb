check = UpstreamTest.method(:check)
$game_temp.in_battle = true
$game_switches[SWITCH_DOUBLE_ABILITIES] = true
scene = Object.new
def scene.pbChangePokemon(*); end
def scene.pbAnimation(*); @animations = (@animations || 0) + 1; end
def scene.pbRefreshOne(*); end
def scene.animations; @animations || 0; end
trainer = NPCTrainer.new("Shape fixture", $Trainer.trainer_type)
make = lambda do |secondary|
  pokemon = Pokemon.new(getFusedPokemonIdFromSymbols(:MINIOR_M, :BULBASAUR), 50, $Trainer)
  pokemon.ability = secondary ? :OVERGROW : :SHIELDSDOWN
  pokemon.ability2 = secondary ? :SHIELDSDOWN : :OVERGROW
  pokemon.shinyValue = 37
  enemy = Pokemon.new(:PIKACHU, 50, trainer)
  trainer.party = [enemy]
  battle = PokeBattle_Battle.new(scene, [pokemon], [enemy], $Trainer, trainer)
  battle.internalBattle = false
  battle.setBattleMode("single")
  battle.pbEnsureParticipants
  battle.pbSetUpSides
  battle.define_singleton_method(:pbDisplay) { |*| }
  [battle.battlers[0], pokemon]
end
[false, true].each do |secondary|
  battler, pokemon = make.call(secondary)
  battler.hp = battler.totalhp / 2
  check.call(pokemon.isFusionOf(:MINIOR_C), "HP crossing changes core form with #{secondary ? 'secondary' : 'primary'} ability")
  check.call(battler.attack == pokemon.attack && battler.defense == pokemon.defense, "form refreshes battler stats")
  count = scene.animations
  battler.hp = battler.hp
  check.call(scene.animations == count, "same HP does not duplicate form animation")
  battler.hp = battler.totalhp
  KIFMultiplayerFeatureTest.log("FORM_STATE species=#{pokemon.species} ability=#{battler.ability_id} hp=#{battler.hp}/#{battler.totalhp} hue=#{pokemon.shinyValue}")
  check.call(pokemon.isFusionOf(:MINIOR_M) && pokemon.shinyValue == 37, "healing restores meteor without losing appearance")
  battler.hp = 0
  check.call(pokemon.isFusionOf(:MINIOR_M), "KO does not animate a new form")
end
battler, pokemon = make.call(true)
$game_switches[SWITCH_DOUBLE_ABILITIES] = false
battler.hp = battler.totalhp / 2
check.call(pokemon.isFusionOf(:MINIOR_M), "disabled secondary ability does not trigger")
$game_switches[SWITCH_DOUBLE_ABILITIES] = true
public_pokemon = KIFMultiplayer::PublicVisualPokemon.new(pokemon.species, 50, nil, false, false)
public_pokemon.freeze_visual_capacity({"level" => 50, "hp" => 100, "totalhp" => 100})
battler.instance_variable_set(:@pokemon, public_pokemon)
battler.ability = :SHIELDSDOWN
battler.hp = 30
check.call(public_pokemon.isFusionOf(:MINIOR_M), "guest authoritative visuals never execute a local form change")
foreign = Pokemon.new(getFusedPokemonIdFromSymbols(:MINIOR_M, :EEVEE), 50, trainer)
core = getFusedPokemonIdFromSymbols(:MINIOR_C, :EEVEE)
check.call(!$Trainer.pokedex.owned?(core), "opponent form fixture starts unowned")
foreign.changeFormSpecies(:MINIOR_M, :MINIOR_C)
check.call($Trainer.pokedex.seen?(core) && !$Trainer.pokedex.owned?(core), "opponent form cannot grant owned dex credit")
