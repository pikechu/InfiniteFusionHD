# frozen_string_literal: true
module KIFNative
  def self.asset_index
    @asset_index ||= JSON.parse(File.read(File.join(__dir__, "asset-index.json")))
  end
  def self.bitmap_index
    @bitmap_index ||= asset_index.fetch("bitmaps", []).to_h { |path| [path.downcase, path] }
  end
  def self.online_sprite_index
    @online_sprite_index ||= asset_index.fetch("custom_online").to_h { |id| [id, true] }
  end
end
KIFNative.register_data_path(File.join(KIFNative::ROOT, Settings::CREDITS_FILE_PATH))

def pbResolveBitmap(path)
  return nil unless path.is_a?(String)
  key = path.tr("\\", "/").delete_prefix("./").downcase
  KIFNative.bitmap_index[key] || %w[.png .gif .bmp].filter_map { |extension| KIFNative.bitmap_index[key+extension] }.first
end

module KIFNativeGraphicsDirectories
  def entries(path, *arguments)
    normalized = File.expand_path(path, KIFNative::ROOT).delete_prefix(KIFNative::ROOT+"/")
    return super unless normalized.start_with?("Graphics/")
    prefix = normalized.delete_suffix("/")+"/"
    [".", ".."] + KIFNative.bitmap_index.values.filter_map { |file| file.delete_prefix(prefix).split("/").first if file.start_with?(prefix) }.uniq
  end
end
Dir.singleton_class.prepend(KIFNativeGraphicsDirectories)

def download_custom_sprite(head, body, *_)
  id = getSpeciesIdForFusion(head, body)
  return nil unless KIFNative.online_sprite_index[id]
  "#{Settings::CUSTOM_BATTLERS_FOLDER_INDEXED}#{head}/#{head}.#{body}.png"
end

def displaySpriteWindowWithMessage(sprite, message = "", *)
  species = getPokemonSpeciesFromPifSprite(sprite)
  KIFNative.scene.ask("gallery", {"species" => species.id, "type" => sprite.type,
    "head" => sprite.head_id, "body" => sprite.body_id, "alt" => sprite.alt_letter, "text" => message})
end

def pbAllowSpeedup; $CanToggle = true; end
def pbDisallowSpeedup; $CanToggle = false; end
KIFNative.register_global_references("$CanToggle")

def pbListWindow(*); KIFNative::PresentationObject.new; end
def pbCommandsSortable(_window, commands, _cancel, _default = -1, _sortable = false)
  [0, KIFNative.scene.pbShowCommands("Select", commands)]
end
class TrainerCardBackgroundLister
  def initialize(cards)
    @commands, @cardsList, @index = [], cards, 0
  end
  def dispose; end
end
def pbListScreen(title, lister)
  selected = KIFNative.scene.pbShowCommands(title, lister.commands)
  lister.value(selected)
ensure
  lister.dispose
end
class BetterRegionMap
  def initialize(_region = -1, _show_player = true, can_fly = false, wallmap = false, _species = nil, fly_anywhere = false)
    @fly_anywhere, @data = fly_anywhere, load_data("Data/town_map.dat")[0]
    @flydata = nil
    unless can_fly
      pbShowMap(0, wallmap)
      return
    end
    spots = (@data[2] || []).filter_map do |location|
      spot = pbGetHealingSpot(location[0],location[1])
      [location,spot] if can_fly_to_location(spot)
    end
    selected = KIFNative.scene.pbShowCommands("Fly", spots.map { |location, _spot| location[2].to_s } + ["Cancel"])
    @flydata = spots[selected][1] if selected >= 0 && selected < spots.length
  end
end

def pbHiddenMoveAnimation(pokemon)
  return false unless pokemon
  KIFNative.scene.events << {"kind" => "hidden_move_animation", "monster_id" => pokemon.instance_variable_get(:@controlled_id)}
  true
end
class DarknessSprite
  def initialize(*); @radius, @disposed = radiusMin, false; end
  def dispose; @disposed = true; end
  def disposed?; @disposed; end
  def refresh; end
end
def pbCreateMessageWindow(*); KIFNative::PresentationObject.new; end
def pbUpdateSceneMap
  $scene.miniupdate if $scene && $scene.respond_to?(:miniupdate)
end

module KIFNative
  class << self; attr_accessor :fishing_input, :input_elapsed; end
  def self.fishing_window(phase, seconds)
    key = scene.ask("fishing", {"phase" => phase, "seconds" => seconds})
    elapsed = input_elapsed || 0
    raise ArgumentError, "native_wait_early" if phase == "wait" && key.nil? && elapsed + 0.001 < seconds
    self.fishing_input = {"frame" => 0, "press" => [(elapsed*Graphics.frame_rate).floor, 1].max,
                          "key" => key == "use" ? Input::USE : key == "back" ? Input::BACK : nil}
    yield
  ensure
    self.fishing_input = nil
  end
end
module KIFNativeFishingKeys
  def update
    return super unless KIFNative.fishing_input
    KIFNative.fishing_input["frame"] += 1
  end
  def trigger?(key)
    data = KIFNative.fishing_input
    return super unless data
    data["frame"] == data["press"] && data["key"] == key
  end
end
Input.singleton_class.prepend(KIFNativeFishingKeys)
alias native_original_fishing_wait pbWaitMessage
def pbWaitMessage(window, time)
  seconds = (time+1) * ((Graphics.frame_rate*4/10).to_f / Graphics.frame_rate)
  KIFNative.fishing_window("wait", seconds) { native_original_fishing_wait(window,time) }
end
alias native_original_fishing_hook pbWaitForInput
def pbWaitForInput(window, message, frames)
  KIFNative.fishing_window("hook", frames.to_f / Graphics.frame_rate) { native_original_fishing_hook(window,message,frames) }
end
class OutfitSelector
  def parse_clothes_folder; KIFNative.asset_index.fetch("clothes").dup; end
  def parse_hats_folder; KIFNative.asset_index.fetch("hats").dup; end
  def parse_hairstyle_types_folder; KIFNative.asset_index.fetch("hair_types").dup; end
  def parse_hairstyles_folder; KIFNative.asset_index.fetch("hair").dup; end
  def display_outfit_preview; TOPLEVEL_BINDING.receiver.send(:display_outfit_preview); end
end
def display_outfit_preview(*)
  KIFNative.scene.events << {"kind" => "outfit_preview"}
end
def hide_outfit_preview; end
def getCustomSpeciesList(online = true, _redownload = false)
  local = KIFNative.asset_index.fetch("custom_local")
  pool = online && local.length <= 20_000 ? KIFNative.asset_index.fetch("custom_online") : local
  pool.dup
end

def pbChooseSpeciesTextList(_default = nil)
  species = (1..NB_POKEMON).map { |number| GameData::Species.get(number) }
  selected = KIFNative.scene.pbShowCommands("Species", species.map { |entry| "#{entry.id_number}: #{entry.real_name}" })
  selected < 0 ? nil : species.fetch(selected).id
end
def pbChooseMove(pokemon, variable, name_variable)
  return unless pokemon
  choice = KIFNative.scene.pbShowCommands(pokemon.name, pokemon.moves.map(&:name))
  $game_variables[variable] = choice
  $game_variables[name_variable] = choice < 0 ? "" : pokemon.moves.fetch(choice).name
  $game_map.need_refresh = true if $game_map
end
def pbShowMap(region = -1, wallmap = true)
  position = GameData::MapMetadata.try_get($game_map.map_id)&.town_map_position
  region = position ? position[0] : 0 if region < 0
  KIFNative.scene.ask("region_map", {"region" => region, "wallmap" => wallmap})
end
%i[pbDownloadMysteryGift pbEditMysteryGift pbDebugMysteryGift extract_custom_sprites_that_evolve_into_non_customs extract_incomplete_evolution_lines extract_pokes_with_non_custom_final_evos].each do |name|
  Object.define_method(name) { |*| raise ArgumentError, "native_offline_only_feature" }
  Object.send(:private, name)
end
