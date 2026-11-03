require_relative "../../server/multiplayer/native/world"
require_relative "../../Data/Scripts/054_Multiplayer/001_Client"
KIFNative.capture_global_baseline
KIFNative.reset(time: 1_792_713_600, seed: 8321)
KIFNative.initialize_world
KIFNative.begin_identities(8321)
$Trainer.party = [Pokemon.new(:BULBASAUR, 10)]
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
$PokemonStorage.boxes.each_with_index do |box, index|
  box.pokemon.each_index { |slot| $PokemonStorage[index, slot] = Pokemon.new(:PIDGEY, 20) }
end
KIFNative.identify
blob = KIFNative.export_state
serialized = JSON.generate({"ok" => true, "original" => {"view" => KIFNative.world_view}})
KIFMultiplayer::WireJSON.parse(serialized)
KIFNative.scene = KIFNative::Scene.new
screen = PokemonStorageScreen.new(PokemonStorageScene.new, $PokemonStorage)
fiber = Fiber.new { screen.pbStartScreen(0) }
prompt = fiber.resume
raise "Expected native storage prompt" unless prompt["kind"] == "storage"
storage_response = JSON.generate({"view" => KIFNative.world_view, "prompt" => prompt})
KIFMultiplayer::WireJSON.parse(storage_response)
KIFNative.import_state(blob)
raise "Full storage lost assets" unless KIFNative.all_monsters.length == 1201
seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC)-started
puts "ORIGINAL_SCALE_PASS " + JSON.generate({"monsters" => 1201, "state_bytes" => blob.bytesize,
  "view_bytes" => serialized.bytesize, "storage_response_bytes" => storage_response.bytesize, "elapsed_seconds" => seconds.round(3)})
