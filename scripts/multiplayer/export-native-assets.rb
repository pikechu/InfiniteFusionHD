# Build trusted presence metadata for rules which inspect installed sprite sets.
# The server does not need or ship the image files themselves.
require_relative "../../server/multiplayer/native/world"
folders = lambda { |path| Dir.children(path).select { |name| File.directory?(File.join(path, name)) } }
clothes = folders.call(get_clothes_sets_list_path)
hats = folders.call(get_hats_sets_list_path)
hair_types = folders.call(get_hair_sets_list_path)
hair = hair_types.flat_map { |name| (1..10).filter_map { |version| id = "#{version}_#{name}"; id if [".png", ".gif", ".bmp"].any? { |extension| File.file?(getOverworldHairFilename(id) + extension) } } }
maximum = NB_POKEMON * NB_POKEMON + NB_POKEMON
local = (1..NB_POKEMON).flat_map do |number|
  Dir[Settings::CUSTOM_BATTLERS_FOLDER_INDEXED + number.to_s + "/*"].filter_map do |path|
    id = getDexNumFromFilename(File.basename(path, ".*"))
    id if id && id > 0 && id <= maximum
  end
end
online = File.file?(Settings::CUSTOM_SPRITES_FILE_PATH) ? File.readlines(Settings::CUSTOM_SPRITES_FILE_PATH).filter_map { |name| id = getDexNumFromFilename(name); id if id && id > 0 && id <= maximum } : []
document = {"clothes" => clothes, "hats" => hats, "hair_types" => hair_types, "hair" => hair,
            "custom_local" => local, "custom_online" => online,
            "bitmaps" => Dir[File.join(KIFNative::ROOT, "Graphics/**/*")].select { |path| File.file?(path) && %w[.png .gif .bmp].include?(File.extname(path).downcase) }.map { |path| path.delete_prefix(KIFNative::ROOT+"/") }}
File.write(File.join(KIFNative::ROOT, "server/multiplayer/native/asset-index.json"), JSON.generate(document) + "\n")
puts "NATIVE_ASSETS_INDEX clothes=#{clothes.length} hats=#{hats.length} hair=#{hair.length} custom_local=#{local.length} custom_online=#{online.length}"
