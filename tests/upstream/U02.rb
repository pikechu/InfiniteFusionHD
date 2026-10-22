check = UpstreamTest.method(:check)
def $scene.spritesetGlobal; nil; end
scene = Object.new
def scene.pbDisplay(*); end
def scene.pbRefresh; end
pokemon = Pokemon.new(:BLISSEY, 70, $Trainer)
pokemon.hp = pokemon.totalhp - 80
before = pokemon.hp
check.call(ItemHandlers.triggerUseOnPokemon(:COFFEE, pokemon, scene) && pokemon.hp == before + 50, "coffee restores 50 HP outside battle")
pokemon.hp = pokemon.totalhp
check.call(!ItemHandlers.triggerUseOnPokemon(:COFFEE, pokemon, scene), "full HP rejects coffee outside battle")
check.call(!ItemHandlers.triggerCanUseInBattle(:COFFEE, pokemon, nil, nil, true, nil, scene, false), "full HP rejects coffee before battle consumption")
pokemon.hp = pokemon.totalhp - 20
check.call(ItemHandlers.triggerBattleUseOnPokemon(:COFFEE, pokemon, nil, [], scene) && pokemon.hp == pokemon.totalhp, "battle handler uses five-argument scene contract and caps HP")
pokemon.hp = 0
check.call(!ItemHandlers.triggerUseOnPokemon(:COFFEE, pokemon, scene), "coffee cannot revive")
$game_switches[SWITCH_JOINED_TEAM_ROCKET] = false
check.call(ItemHandlers.triggerUseFromBag(:ROCKETUNIFORM) == 0, "uniform requires joining Rocket")
$game_switches[SWITCH_JOINED_TEAM_ROCKET] = true
$game_variables[VAR_TRAINER_GENDER] = GENDER_MALE
clothes, hat = $Trainer.clothes, $Trainer.hat
UpstreamTest.override(Object, :playOutfitChangeAnimation, proc {}) do
  UpstreamTest.override(Kernel.singleton_class, :pbConfirmMessage, proc { |*| false }) do
    check.call(useRocketUniform == 0 && [$Trainer.clothes, $Trainer.hat] == [clothes, hat], "cancel does not change outfit")
  end
  UpstreamTest.override(Kernel.singleton_class, :pbConfirmMessage, proc { |*| true }) do
    check.call(ItemHandlers.triggerUseFromBag(:ROCKETUNIFORM) == 1 && isWearingTeamRocketOutfit(), "bag puts on complete uniform")
    check.call(ItemHandlers.triggerUseInField(:ROCKETUNIFORM) == 1 && [$Trainer.clothes, $Trainer.hat] == [clothes, hat], "registered uniform restores previous clothes and hat")
    $game_variables[VAR_TRAINER_GENDER] = GENDER_FEMALE
    check.call(useRocketUniform == 1 && $Trainer.clothes == CLOTHES_TEAM_ROCKET_FEMALE, "female uniform supported")
    $Trainer.last_worn_outfit = CLOTHES_TEAM_ROCKET_FEMALE
    $Trainer.last_worn_hat = HAT_TEAM_ROCKET
    check.call(useRocketUniform == 1 && !isWearingTeamRocketOutfit(), "old saves with uniform as previous outfit recover to defaults")
  end
end
