# frozen_string_literal: true
# Native map and interpreter context required by map-sensitive original rules.
require_relative "cultivation"
require_relative "mart"
require_relative "storage"
require_relative "field_ui"
require_relative "minigames"

module HTTPLite
  JSON = ::JSON # local trusted outfit data parser; no HTTP client in the worker
end
module Graphics
  def self.frame_count; @native_frames || 0; end
  def self.update; @native_frames = frame_count + 1; end
  def self.freeze; end # RGSS screen transition, not Object#freeze
  def self.transition(*); end
  def self.frame_reset; end
end
module Input
  USE = C
  BACK = B
  ACTION = :action
  SPECIAL = :special
  CTRL = :ctrl
  F9 = :f9
  def self.dir4; 0; end
  def self.press?(*); false; end
end
module System
  def self.power_state; {discharging: false}; end
end
module Audio
  %i[bgm_play bgm_stop bgm_fade bgs_play bgs_stop bgs_fade me_play me_stop me_fade se_play se_stop].each do |name|
    define_singleton_method(name) { |*| nil }
  end
end
class TrainerClothesPreview
  def initialize(*); end
  %i[show resetOutfits updatePreview erase].each { |name| define_method(name) { nil } }
end
class LocationWindow
  def initialize(text)
    KIFNative.scene.events << {"kind" => "location", "text" => text} if KIFNative.scene
  end
end
class CharacterSelectionMenuView
  def initialize
    @sprites = {"select" => KIFNative::PresentationObject.new}
    @textValues = {}
    @presenter = CharacterSelectMenuPresenter.new(self)
    @max_index = 5
  end
  def start
    @presenter.setInitialValues
    @presenter.native_main
  end
  %i[displayText displayAge showSideArrows hideSideArrows].each { |name| define_method(name) { |*| nil } }
end
class CharacterSelectMenuPresenter
  def native_main
    until @closed
      selected = KIFNative.scene.pbShowCommands("Character", @options)
      next if selected < 0
      case @options[selected]
      when OPTION_GENDER
        value = KIFNative.scene.pbShowCommands(OPTION_GENDER, GENDERS_IDS)
        setGender(selected, value - @gender) if value >= 0
      when OPTION_AGE
        value = KIFNative.scene.pbShowCommands(OPTION_AGE, (MIN_AGE..MAX_AGE).map(&:to_s))
        setAge(selected, value + MIN_AGE - @age) if value >= 0
      when OPTION_SKIN
        value = KIFNative.scene.pbShowCommands(OPTION_SKIN, SKIN_COLOR_IDS)
        setSkinColor(selected, value + MIN_SKIN_COLOR - @skinTone) if value >= 0
      when OPTION_HAIR
        value = KIFNative.scene.pbShowCommands(OPTION_HAIR, HAIR_COLOR_NAMES)
        setHairColor(selected, value - @hairColor) if value >= 0
      else
        action_button_pressed(selected)
      end
    end
    KIFNative.all_monsters.each do |pokemon|
      next unless pokemon.instance_variable_get(:@controlled_v1_migrated) && pokemon.owner.id == $Trainer.id
      owner = pokemon.owner
      pokemon.owner = Pokemon::Owner.new(owner.id, $Trainer.name, owner.gender, owner.language)
    end
  end
end
def pbEnterText(text, minimum, maximum, *)
  value = KIFNative.scene.ask("name", {"text" => text, "maximum" => maximum})
  raise ArgumentError, "native_name_limit" unless value.length.between?(minimum, maximum)
  value
end
def pbEnterPlayerName(*arguments); pbEnterText(*arguments); end
def pbEnterNPCName(*arguments); pbEnterText(*arguments); end
def pbEnterPokemonName(*arguments); pbEnterText(*arguments); end
def pbClearNumber; end
def pbClearText; end
def pbDisposeSpriteHash(*); end
def refreshPlayerOutfit; end # player sprite refresh; clothing setters still run
def updatePinkanBerryDisplay; end
def pbCallBub(status = 0, value = 0, down = false, up = false)
  speaker = respond_to?(:get_character, true) ? get_character(value)&.id : value
  KIFNative.scene.events << {"kind" => "speaker", "event_id" => speaker, "bubble" => status, "down" => down, "up" => up} if KIFNative.scene
end
def pbCallBubUp(status = 0, value = 0); pbCallBub(status, value, false, true); end
def pbCallBubDown(status = 0, value = 0); pbCallBub(status, value, true, false); end
%i[pbClearNumber pbClearText].each do |name|
  Kernel.define_singleton_method(name) { |*arguments| TOPLEVEL_BINDING.receiver.send(name, *arguments) }
end

module SaveData
  # New controlled realms have no legacy local save to migrate. This query is
  # answered from the online realm lifecycle; never inspect a user's disk saves.
  def self.exists?; KIFNative.checkpoint_exists == true; end
end
class Player
  attr_accessor :save_slot # Virtual online slot used by the original autosave checks.
end
module KIFNative
  def self.world_state
    {"factory" => $MapFactory, "player" => $game_player, "system" => $game_system,
     "screen" => $game_screen, "self_switches" => $game_self_switches,
     "map_metadata" => $PokemonMap, "encounters" => $PokemonEncounters,
     "temp" => $game_temp, "pokemon_temp" => $PokemonTemp,
     "checkpoint_exists" => checkpoint_exists, "frames" => Graphics.frame_count}
  end
  def self.restore_world_state(world)
    $data_system = load_data("Data/System.rxdata")
    $data_tilesets = load_data("Data/Tilesets.rxdata")
    $data_common_events = load_data("Data/CommonEvents.rxdata")
    $MapFactory, $game_player, $game_system, $game_screen, $game_self_switches, $PokemonMap, $PokemonEncounters, $game_temp, $PokemonTemp =
      world.values_at("factory", "player", "system", "screen", "self_switches", "map_metadata", "encounters", "temp", "pokemon_temp")
    $game_map = $MapFactory.map
    $scene = MapScene.new
    self.checkpoint_exists = world["checkpoint_exists"]
    Graphics.instance_variable_set(:@native_frames, world.fetch("frames"))
  end
  class << self; attr_accessor :checkpoint_exists; end
end
module Game
  def self.save(*)
    $Trainer.save_slot ||= "controlled_online"
    KIFNative.checkpoint_exists = true
    KIFNative.scene.events << {"kind" => "checkpoint_requested"}
    true
  end
end
def pbSave(*); Game.save; end
def pbSaveScreen
  return false unless pbConfirmMessage("Save this online character?")
  Game.save
end
class Interpreter
  # Preserve native evaluation of trusted packaged event scripts; let failures
  # propagate to the server transaction without invoking a graphical error UI.
  def execute_script(script); eval(script); end
end

module KIFNative
  class PlayerSprite
    def clearShadows; end
  end
  class GlobalSprites
    def playersprite; @player ||= PlayerSprite.new; end
  end
  class WorldSprites
    attr_reader :map
    def character_sprites; @character_sprites ||= []; end
    def initialize(map); @map = map; end
    def addUserAnimation(animation, x, y, *)
      KIFNative.scene.events << {"kind" => "map_animation", "animation" => animation, "x" => x, "y" => y} if KIFNative.scene
      PresentationObject.new
    end
    def addUserSprite(*); end
  end
  class MapScene < Scene_Map
    def initialize
      @spritesetGlobal = GlobalSprites.new
      @spritesets = {}
    end
    def reset_player_sprite; end
    def autofade(*); end
    def disposeSpritesets; end
    def createSpritesets
      $MapFactory.maps.each { |map| @spritesets[map.map_id] ||= WorldSprites.new(map) }
      $MapFactory.setSceneStarted(self)
    end
    def spriteset(map_id = $game_map.map_id)
      @spritesets[map_id] ||= WorldSprites.new($MapFactory.getMap(map_id))
    end
    def updateSpritesets(*)
      Events.onMapUpdate.trigger(self)
    end
  end
  def self.initialize_world
    $data_system = load_data("Data/System.rxdata")
    $data_tilesets = load_data("Data/Tilesets.rxdata")
    $data_common_events = load_data("Data/CommonEvents.rxdata")
    $game_switches = Game_Switches.new
    $game_variables = Game_Variables.new
    $game_self_switches = Game_SelfSwitches.new
    $game_screen = Game_Screen.new
    $PokemonMap = PokemonMapMetadata.new
    $game_system = Game_System.new
    $game_player = Game_Player.new
    $scene = MapScene.new
    $game_map = nil
    $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
    $game_player.moveto($data_system.start_x, $data_system.start_y)
    $PokemonEncounters = PokemonEncounters.new
    $PokemonEncounters.setup($game_map.map_id)
  end
  def self.advance_world(minimum_frames = 1)
    1200.times do |index|
      Graphics.update
      $scene.update
      waiting = $game_temp.common_event_id > 0 || $game_map.events.values.any?(&:starting)
      break if index + 1 >= minimum_frames && $scene.is_a?(Scene_Map) && !waiting && !pbMapInterpreterRunning? && !$game_player.moving? && !$game_temp.player_transferring
    end
  end
  def self.world_view
    result = view
    tone = $game_screen.tone
    result["world"] = {"map_id" => $game_map.map_id, "name" => $game_map.name,
      "x" => $game_player.x, "y" => $game_player.y, "direction" => $game_player.direction,
      "transparent" => $game_player.transparent, "pattern" => $game_player.pattern,
      "darkness_radius" => $PokemonTemp.darknessSprite && !$PokemonTemp.darknessSprite.disposed? ? $PokemonTemp.darknessSprite.radius : nil,
      "camera" => [$game_map.display_x.to_f / Game_Map::X_SUBPIXELS, $game_map.display_y.to_f / Game_Map::Y_SUBPIXELS],
      "tone" => [tone.red, tone.green, tone.blue, tone.gray], "brightness" => $game_screen.brightness,
      "bridge" => $PokemonGlobal.bridge, "maps" => $MapFactory.maps.map { |map| map_projection(map) },
      "pictures" => $game_screen.pictures.compact.reject { |picture| picture.name.empty? }.map do |picture|
        {"id" => picture.number, "name" => picture.name, "x" => picture.x, "y" => picture.y,
         "origin" => picture.origin, "zoom_x" => picture.zoom_x, "zoom_y" => picture.zoom_y,
         "opacity" => picture.opacity, "blend_type" => picture.blend_type, "angle" => picture.angle,
         "tone" => [picture.tone.red, picture.tone.green, picture.tone.blue, picture.tone.gray]}
      end,
      "weather" => $game_screen.weather_type,
      "events" => $game_map.events.values.map { |event| {"id" => event.id, "x" => event.x, "y" => event.y,
        "direction" => event.direction, "graphic" => event.character_name, "tile" => event.tile_id,
        "width" => event.width, "height" => event.height, "hue" => event.character_hue,
        "opacity" => event.opacity, "blend_type" => event.blend_type,
        "pattern" => event.pattern, "transparent" => event.transparent} }}
    result["trainer"] = {"name" => $Trainer.name, "id" => $Trainer.id, "badges" => $Trainer.badges,
      "character_id" => $Trainer.character_ID, "skin" => $Trainer.skin_tone, "hair" => $Trainer.hair,
      "hat" => $Trainer.hat, "clothes" => $Trainer.clothes, "pokedex" => $Trainer.has_pokedex,
      "hair_color" => $Trainer.hair_color, "hat_color" => $Trainer.hat_color, "clothes_color" => $Trainer.clothes_color,
      "running_shoes" => $Trainer.has_running_shoes}
    result["trainer"]["coins"] = $Trainer.coins
    result["trainer"]["battle_points"] = $Trainer.battle_points
    result["trainer"]["card_background"] = $Trainer.card_background
    result["quests"] = ($Trainer.quests || []).map { |quest| {"id" => quest.id, "name" => quest.name, "description" => quest.desc, "npc" => quest.npc, "location" => quest.location, "completed" => quest.completed} }
    result["field"] = {"surfing" => $PokemonGlobal.surfing, "bicycle" => $PokemonGlobal.bicycle, "fishing" => $PokemonGlobal.fishing, "repel_steps" => $PokemonGlobal.repel}
    result["quiz_picture"] = quiz_picture if quiz_picture
    if active_battle.is_a?(PokeBattle_SafariZone)
      battle = active_battle
      result["battle"] = {"mode" => "safari", "kind" => "wild", "balls" => battle.ballCount,
        "enemies" => battle.party2.map { |pokemon| monster_view(pokemon).slice("species", "name", "level", "hp", "max_hp", "status", "form", "gender", "shiny", "appearance") },
        "backdrop" => battle.backdrop, "backdrop_base" => battle.backdropBase, "time" => battle.time}
    elsif active_battle
      battle = active_battle
      result["battle"] = {"round" => battle.turnCount, "kind" => battle.trainerBattle? ? "trainer" : "wild",
        "weather" => battle.field.weather, "terrain" => battle.field.terrain, "double_abilities" => $game_switches[SWITCH_DOUBLE_ABILITIES] == true,
        "backdrop" => battle.backdrop, "backdrop_base" => battle.backdropBase, "time" => battle.time,
        "party" => battle.pbParty(0).map { |pokemon| monster_view(pokemon) },
        "enemies" => battle.pbParty(1).each_with_index.map do |pokemon, index|
          displayed = battle.battlers.compact.find { |battler| battler.index.odd? && battler.pokemonIndex == index }
          visual = displayed && displayed.respond_to?(:displayPokemon) ? displayed.displayPokemon : pokemon
          monster_view(pokemon).slice("level", "hp", "max_hp", "status").merge(monster_view(visual).slice("species", "name", "form", "gender", "shiny", "appearance"))
        end,
        "sides" => [battle.pbSideSize(0), battle.pbSideSize(1)],
        "party_starts" => battle.party1starts, "enemy_starts" => battle.party2starts,
        "players" => Array(battle.player).map { |trainer| {"name" => trainer.name, "type" => trainer.trainer_type} },
        "opponents" => Array(battle.opponent).map { |trainer| {"name" => trainer.name, "type" => trainer.trainer_type} },
        "battlers" => battle.battlers.compact.map { |b| {"index" => b.index, "party_index" => b.pokemonIndex,
          "hp" => b.hp, "status" => b.status, "stages" => b.stages} }}
    end
    result
  end
  def self.map_projection(map)
    @base_map_cells ||= {}
    unless @base_map_cells.key?(map.map_id)
      path = File.join(ROOT, sprintf("Data/Map%03d.rxdata", map.map_id))
      @base_map_cells[map.map_id] = File.file?(path) ? Marshal.load(File.binread(path)).data.instance_variable_get(:@data).freeze : nil
    end
    cells = map.data.instance_variable_get(:@data)
    base = @base_map_cells[map.map_id]
    changes = cells == base ? [] : cells.each_index.filter_map { |index| [index, cells[index]] if !base || cells[index] != base[index] }
    {"id" => map.map_id, "width" => map.width, "height" => map.height,
     "tileset" => map.instance_variable_get(:@map).tileset_id, "layers" => map.data.zsize,
     "origin" => $MapFactory.getRelativePos($game_map.map_id, 0, 0, map.map_id, 0, 0),
     "full" => base.nil?, "tiles" => changes}
  end
  def self.world_step(document)
    import_state(document.fetch("initial"))
    money_before = wallet_baseline(document)
    raise ArgumentError, "native_world_missing" unless $MapFactory
    self.clock = document.fetch("time")
    srand(document.fetch("seed"))
    begin_identities(document.fetch("seed"), Digest::SHA256.hexdigest(document.fetch("initial")))
    self.scene = Scene.new
    action = document.fetch("action")
    movement_seconds = 0
    fiber = Fiber.new do
      pbMapInterpreter.setup_starting_event unless pbMapInterpreterRunning?
      if action.fetch("kind") != "wait" && !pbMapInterpreterRunning?
        case action.fetch("kind")
        when "move", "turn"
          direction = action.fetch("direction")
          raise ArgumentError, "native_direction" unless [2,4,6,8].include?(direction)
          if action["kind"] == "move"
            if $game_player.can_move_in_direction?(direction)
              movement_seconds = Game_Map::REAL_RES_X.to_f / $game_player.move_speed_real / Graphics.frame_rate
            end
            $game_player.move_generic(direction)
          else
            $game_player.turn_generic(direction)
          end
        when "interact"
          handled = $game_player.check_event_trigger_here([0])
          handled |= $game_player.check_event_trigger_there([0,2])
          Events.onAction.trigger($scene) unless handled
        when "field_move"
          pokemon = $Trainer.party.find { |entry| entry.instance_variable_get(:@controlled_id) == action.fetch("monster_id") }
          move = action.fetch("move").to_sym
          raise ArgumentError, "native_field_move" unless pokemon && !pokemon.egg? && !pokemon.instance_variable_get(:@controlled_rental) && pokemon.hasMove?(move) && HiddenMoveHandlers.hasHandler(move)
          if pbCanUseHiddenMove?(pokemon, move) && pbConfirmUseHiddenMove(pokemon, move)
            if [:FLY, :TELEPORT].include?(move)
              $PokemonTemp.flydata = pbBetterRegionMap(-1, true, true)
              pbUseHiddenMove(pokemon, move) if $PokemonTemp.flydata
            else
              pbUseHiddenMove(pokemon, move)
            end
          end
        when "field_item"
          item = action.fetch("item").to_sym
          raise ArgumentError, "item_not_owned" unless $PokemonBag.pbQuantity(item) > 0
          result = pbUseItem($PokemonBag, item)
          pbUseKeyItemInField(item) if result == 2
        when "reorder"
          requested = action.fetch("party")
          by_id = $Trainer.party.to_h { |entry| [entry.instance_variable_get(:@controlled_id), entry] }
          raise ArgumentError, "native_party_order" unless requested.length == by_id.length && requested.uniq.sort == by_id.keys.sort
          $Trainer.party = requested.map { |id| by_id.fetch(id) }
        when "save"
          raise ArgumentError, "native_save_disabled" if $game_system.save_disabled
          pbSaveScreen
        else
          raise ArgumentError, "unknown_native_world_intent"
        end
      end
      advance_world(document.fetch("frames", 1))
    end
    prompt = fiber.resume
    document.fetch("inputs").each do |input|
      raise ArgumentError, "native_history_after_end" unless fiber.alive?
      raise ArgumentError, "native_prompt_conflict" unless input.fetch("prompt") == prompt
      self.clock = input.fetch("time", document.fetch("time"))
      self.input_elapsed = input["elapsed"]
      prompt = fiber.resume(input.fetch("value"))
    end
    finished = !fiber.alive?
    identify
    {"prompt" => finished ? nil : prompt, "events" => scene.events, "view" => world_view, "money_delta" => $Trainer.money - money_before,
     "movement_seconds" => movement_seconds,
     "state" => finished ? export_state : nil}.tap do |result|
       result["restore_assets"] = all_monsters.to_h { |pokemon| [pokemon.instance_variable_get(:@controlled_id), {"blob" => pack_asset(pokemon)}] } if document["capture_assets"]
     end
  ensure
    self.scene = nil
    self.active_battle = nil
    self.minigame = nil
    self.fishing_input = nil
    self.input_elapsed = nil
    self.purify_scene = nil
  end
end

require_relative "activities"

class Sprite_Character
  def initialize(*); end
  def dispose; end
end
class Spriteset_Map < KIFNative::WorldSprites
  def self.viewport; nil; end
end

def pbNewBattleScene
  KIFNative::Scene.new(KIFNative.scene.events)
end
def pbBattleAnimation(*)
  previous = $game_temp.in_battle
  $game_temp.in_battle = true
  yield
ensure
  $game_temp.in_battle = previous
end
def pbSceneStandby; yield; end
def pbMEStop; end
def pbResolveAudioFile(*); nil; end
def pbGetTrainerBattleBGM(*); nil; end
def pbGetTrainerVictoryME(*); nil; end
def pbGetWildBattleBGM(*); nil; end
def pbGetWildCaptureME(*); nil; end

module RPG::Cache
  def self.need_clearing; false; end
  def self.clear; end
end
class Game_Map
  def autoplay; end # map background audio only
end

if $PROGRAM_NAME == __FILE__
  KIFNative.reset
  KIFNative.initialize_world
  KIFNative.scene = KIFNative::Scene.new
  fiber = Fiber.new { KIFNative.advance_world }
  prompt = fiber.resume
  if ARGV.include?("--first-choice") && fiber.alive?
    prompt = fiber.resume(0)
  end
  puts JSON.generate({"map" => $game_map.map_id, "x" => $game_player.x, "y" => $game_player.y,
                      "events" => $game_map.events.length, "prompt" => prompt, "messages" => KIFNative.scene.events})
end
