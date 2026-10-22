check = UpstreamTest.method(:check)
old = $Trainer
hat = HAT_TEAM_ROCKET.dup
clothes = CLOTHES_TEAM_ROCKET_MALE.dup
old.unlocked_hats = [hat, hat]
old.unlocked_clothes = [clothes]
old.save_slot = "File A"
old.pokedex.set_owned(:PIKACHU)
Game.start_new(nil, nil, old)
check.call(!$Trainer.equal?(old), "NG+ creates a separate player")
check.call($Trainer.unlocked_hats.include?(hat) && $Trainer.unlocked_hats.count(hat) == 1, "hat unlocks inherited once")
check.call($Trainer.unlocked_clothes.include?(clothes), "clothes unlocks inherited")
check.call($Trainer.pokedex.owned?(:PIKACHU), "existing KIF pokedex migration remains active")
check.call(!$Trainer.unlocked_hats.equal?(old.unlocked_hats) && !$Trainer.unlocked_clothes.equal?(old.unlocked_clothes), "new save owns independent arrays")
$Trainer.unlocked_hats.find { |id| id == hat }.replace("changed fixture")
check.call(old.unlocked_hats == [hat, hat], "new save mutations cannot change original unlock strings")
check.call($Trainer.save_slot != old.save_slot, "old save slot is not inherited")
legacy = $Trainer
legacy.remove_instance_variable(:@unlocked_hats)
legacy.remove_instance_variable(:@unlocked_clothes)
Game.start_new(nil, nil, legacy)
check.call(!$Trainer.equal?(legacy), "old save missing cosmetic fields still starts NG+")
before = [$Trainer.unlocked_hats, $Trainer.unlocked_clothes]
Game.inherit_ngp_outfits(nil)
check.call([$Trainer.unlocked_hats, $Trainer.unlocked_clothes] == before, "ordinary new game does not inherit unrelated player unlocks")
