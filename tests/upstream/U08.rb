check = UpstreamTest.method(:check)
def $scene.spritesetGlobal; nil; end
setupStartingOutfit()
pokemon = Pokemon.new(:BULBASAUR, 30, $Trainer)
pokemon.shinyKRS = [1, 2, 3]
$Trainer.party = [pokemon]
$PokemonGlobal.hallOfFame = [[pokemon.clone]]
$PokemonGlobal.hallOfFameLastNumber = 1
record = $PokemonGlobal.hallOfFame.first
check.call(record[:TEAM].length == 1 && !record[:DATE] && !record[:MODE], "legacy arrays migrate without inventing date or rules")
scene = HallOfFame_Scene.new
scene.instance_variable_set(:@hallEntry, [])
scene.saveHallEntry
fresh = $PokemonGlobal.hallOfFame.last
check.call(fresh[:DATE] == Time.now.strftime("%Y-%m-%d") && fresh[:MODE] && fresh[:DIFFICULTY], "new hall record captures date mode and difficulty")
check.call(fresh[:TRAINER_CLOTHES] == $Trainer.clothes && fresh.key?(:TRAINER_HAT), "records save full trainer appearance including no hat")
pokemon.shinyKRS << 99
check.call(fresh[:TEAM][0].shinyKRS == [1, 2, 3], "history owns independent KIF appearance data")
copy = Marshal.load(Marshal.dump($PokemonGlobal))
check.call(copy.hallOfFame.last[:DATE] == fresh[:DATE] && copy.hallOfFame.last[:TEAM][0].species == pokemon.species, "local save round-trip preserves metadata and team")
legacy = PokemonGlobalMetadata.allocate
legacy.hallOfFame = [{"TEAM" => [pokemon], "DATE" => "2020-01-02", "MODE" => "Old mode", "DIFFICULTY" => "Old difficulty"}]
check.call(legacy.hallOfFame.first[:DATE] == "2020-01-02", "string-key records remain compatible")
args = nil
scene.instance_variable_set(:@hallRecord, fresh.merge(:TRAINER_HAIR => "hair fixture", :TRAINER_CLOTHES => "clothes fixture", :TRAINER_SKIN => 1, :TRAINER_HAT => nil))
UpstreamTest.override(Object, :generate_front_trainer_sprite_bitmap, proc { |*values| args = values; Bitmap.new(2, 2) }) do
  bitmap = scene.historyTrainerBitmap
  bitmap.dispose
end
check.call(args[2] == "clothes fixture" && args[3].nil? && args[-1] == false, "historical appearance uses explicit values instead of current outfit defaults")
if ENV["KIF_TEST_CLOUD_CODEC"]
  load ENV["KIF_TEST_CLOUD_CODEC"]
  graph = KIFMultiplayer::CloudCodec::Encoder.new.encode(legacy)
  json = KIFMultiplayer::WireJSON.encode(graph, 0)
  restored = KIFMultiplayer::CloudCodec::Decoder.new.decode(KIFMultiplayer::WireJSON.parse(json))
  check.call(restored.hallOfFame.first[:DATE] == "2020-01-02" && restored.hallOfFame.first[:TEAM][0].species == pokemon.species, "existing online branch cloud graph codec round-trips hall records")
end
pc = HallOfFame_Scene.new
pc.pbStartScenePC
pc.instance_variable_set(:@battlerIndex, pc.instance_variable_get(:@hallEntry).length)
check.call(pc.pbUpdatePC, "native history overview renders after last Pokemon")
3.times { Graphics.update }
bitmap = Graphics.snap_to_bitmap
bitmap.save_to_png(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "hall-history.png"))
check.call(bitmap.width == Graphics.width && bitmap.height == Graphics.height, "native history screenshot captured")
bitmap.dispose
pc.instance_variable_set(:@battlerIndex, pc.instance_variable_get(:@hallEntry).length + 1)
check.call(pc.pbUpdatePC && pc.instance_variable_get(:@hallIndex) == 0, "history browsing reaches legacy entries")
pc.instance_variable_set(:@battlerIndex, pc.instance_variable_get(:@hallEntry).length)
check.call(pc.pbUpdatePC && !pc.instance_variable_get(:@hallRecord)[:DATE], "legacy overview retains unknown date and rules")
pc.instance_variable_set(:@battlerIndex, -1)
check.call(pc.pbUpdatePC && pc.instance_variable_get(:@hallIndex) == 1, "history browsing returns to new-format records")
pc.pbEndScene
