check = UpstreamTest.method(:check)
folder = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "sprite-import")
Dir.mkdir(folder)
source, bases, indexed = ["in", "base", "indexed"].map { |part| File.join(folder, part) }
Dir.mkdir(source)
image = Bitmap.new(2, 2)
image.set_pixel(1, 1, Color.new(255, 10, 20, 255))
["1a.png", "1.2b.png", "0.2.png", "1.9999.png", "bad.png"].each { |name| image.save_to_png(File.join(source, name)) }
File.binwrite(File.join(source, "2.3.png"), "not a PNG")
File.binwrite(File.join(source, "2.4.png"), KIF::SpriteImport::PNG)
result = KIF::SpriteImport.run(source, bases, indexed)
check.call(result[:imported] == 2, "imports valid base and fusion files")
check.call(File.file?(File.join(bases, "1a.png")), "base import targets BaseSprites")
check.call(File.file?(File.join(indexed, "1", "1.2b.png")), "fusion import targets indexed head folder")
check.call(result[:invalid].length == 5 && File.file?(File.join(source, "2.3.png")), "invalid names IDs and truncated PNG bytes remain untouched")
destination = File.join(bases, "1a.png")
original = File.binread(destination)
image.save_to_png(File.join(source, "1a.png"))
result = KIF::SpriteImport.run(source, bases, indexed)
check.call(result[:imported] == 0 && result[:duplicates].length == 1 && File.binread(destination) == original, "duplicate imports never overwrite existing art")
result = KIF::SpriteImport.run(File.join(folder, "missing"), bases, indexed)
check.call(result[:imported] == 0, "missing input folder is harmless")
check.call(KIF::SpriteIndex.parse_name("../1.2.png").nil? && KIF::SpriteIndex.parse_name("1.2.PNG")[:body] == 2, "parser bounds file names and normalizes PNG case")
percent = get_total_completion_percent()
check.call(percent > 0 && percent <= 100, "completion percent uses actual valid index instead of zero stub")
letters = KIF::SpriteIndex.fusion_alts(1, 1)
check.call(letters.is_a?(Array) && letters.any?, "fusion index exposes available alternatives")
copy = KIF::SpriteIndex.fusion_alts(1, 1)
copy.clear
check.call(KIF::SpriteIndex.fusion_alts(1, 1) == letters, "callers cannot mutate cached alternatives")
main = File.read("Data/Scripts/999_Main/999_Main.rb")
eval(main[/^def sortCustomBattlers\(\).*?^end/m], TOPLEVEL_BINDING)
settings = {:CUSTOM_BATTLERS_FOLDER => source, :CUSTOM_BASE_SPRITE_FOLDER => bases, :CUSTOM_BATTLERS_FOLDER_INDEXED => indexed}
previous = settings.keys.map { |key| [key, Settings.const_get(key)] }.to_h
begin
  settings.each { |key, value| Settings.send(:remove_const, key); Settings.const_set(key, value) }
  image.save_to_png(File.join(source, "3.4.png"))
  check.call(sortCustomBattlers == 1 && $game_temp.nb_imported_sprites == 1, "actual startup importer updates count")
  check.call($game_temp.unimportedSprites.length == 1, "startup importer retains duplicate prompt data")
ensure
  previous.each { |key, value| Settings.send(:remove_const, key); Settings.const_set(key, value) }
end
customs, base_index = File.join(folder, "CUSTOM_SPRITES"), File.join(folder, "BASE_SPRITES")
File.write(customs, "1.2.png\n1.2a.png\n1.2.png\n9999.2.png\n")
File.write(base_index, "1.png\n1b.png\n")
previous = [:CUSTOM_SPRITES_FILE_PATH, :BASE_SPRITES_FILE_PATH].map { |key| [key, Settings.const_get(key)] }.to_h
begin
  {:CUSTOM_SPRITES_FILE_PATH => customs, :BASE_SPRITES_FILE_PATH => base_index}.each { |key, value| Settings.send(:remove_const, key); Settings.const_set(key, value) }
  first = KIF::SpriteIndex.completion_percent
  expected = 200.0 / (Settings::NB_POKEMON * Settings::NB_POKEMON + Settings::NB_POKEMON)
  check.call((first - expected).abs < 0.000001, "coverage counts species once rather than counting all alternatives")
  File.open(customs, "a") { |file| file.puts("2.3.png") }
  check.call(KIF::SpriteIndex.completion_percent > first, "changed index invalidates cached coverage")
  File.delete(customs)
  check.call(KIF::SpriteIndex.completion_percent > 0, "missing custom index still retains valid base index")
ensure
  previous.each { |key, value| Settings.send(:remove_const, key); Settings.const_set(key, value) }
  KIF::SpriteIndex.reset
end
image.dispose
