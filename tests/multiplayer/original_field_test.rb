require_relative "../../server/multiplayer/native/world"
KIFNative.capture_global_baseline
KIFNative.reset(time: 1_792_713_600, seed: 244)
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
$Trainer.party = [Pokemon.new(:BULBASAUR,25)]
KIFNative.identify

$PokemonBag.pbStoreItem(:REPEL,1)
raise "Native field item failed" unless pbUseItem($PokemonBag,:REPEL) == 1
raise "Native repel was not consumed" unless $PokemonBag.pbQuantity(:REPEL) == 0 && $PokemonGlobal.repel == 100
KIFNative.scene = KIFNative::Scene.new
window = pbCreateMessageWindow
fiber = Fiber.new { pbWaitMessage(window,5) }
prompt = fiber.resume
raise "Fishing wait window missing" unless prompt["kind"] == "fishing" && prompt["phase"] == "wait" && (prompt["seconds"]-2.4).abs < 0.001
KIFNative.input_elapsed = 2.4
raise "Fishing wait cancelled without input" unless fiber.resume(nil) == false && !fiber.alive?
fiber = Fiber.new { pbWaitMessage(window,5) }
fiber.resume
KIFNative.input_elapsed = 0.3
raise "Early fishing cancellation lost" unless fiber.resume("back") == true
fiber = Fiber.new { pbWaitForInput(window,"A bite!",30) }
fiber.resume
KIFNative.input_elapsed = 0.2
raise "Native fishing valid reaction failed" unless fiber.resume("use") == true
fiber = Fiber.new { pbWaitForInput(window,"A bite!",30) }
fiber.resume
KIFNative.input_elapsed = 1.5
raise "Native fishing accepted a late reaction" unless fiber.resume("use") == false

data = load_data("Data/town_map.dat")[0][2]
spot = data.find { |entry| entry[4] && entry[5] && entry[6] }
$PokemonGlobal.visitedMaps[spot[4]] = true
fiber = Fiber.new { pbBetterRegionMap(-1,true,true) }
prompt = fiber.resume
raise "Native fly selection missing" unless prompt["choices"].include?(spot[2])
result = fiber.resume(prompt["choices"].index(spot[2]))
raise "Native fly destination was client supplied" unless result == spot[4,3]

$PokemonTemp.darknessSprite = DarknessSprite.new
HiddenMoveHandlers.triggerUseMove(:FLASH,$Trainer.party.first)
raise "Original Flash did not expand the native visibility radius" unless $PokemonGlobal.flashUsed && $PokemonTemp.darknessSprite.radius == 176
puts "ORIGINAL_FIELD_ITEMS_FISHING_FLY_AND_FLASH_PASS"
