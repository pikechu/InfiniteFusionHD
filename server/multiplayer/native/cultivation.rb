# frozen_string_literal: true
# Display adapters for the native item/evolution/fusion implementations. Their
# original state-changing methods are retained, including consumption and IVs.
require_relative "session"

module Graphics
  def self.width; Settings::SCREEN_WIDTH; end
  def self.height; Settings::SCREEN_HEIGHT; end
  def self.update; end
end
module Input
  B = :back
  C = :use
  def self.trigger?(*); false; end
  def self.update; end
end
module KIFNative
  class PresentationObject
    def disposed?; true; end
    attr_accessor :text, :bitmap, :x, :y, :z, :visible
    def initialize; @text = ""; @bitmap = self; end
    def getBitmap; self; end
    def dispose; end
  end
end
class BitmapSprite
  attr_reader :bitmap
  def initialize(*); @bitmap = KIFNative::PresentationObject.new; end
end
class PokemonPartyScreen; end
class PokemonStorageScene; end
class PokemonTemp
  attr_accessor :cueBGM # audio presentation state normally supplied by overworld
end
class MoveRelearner_Scene
  def pbStartScene(pokemon, moves)
    @pokemon, @native_moves = pokemon, moves
  end
  def pbChooseMove
    selected = KIFNative.scene.pbShowCommands("Move", @native_moves.map { |id| GameData::Move.get(id).name })
    selected < 0 ? nil : @native_moves.fetch(selected)
  end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  def pbEndScene; end
end
class PokemonParty_Scene
  def pbStartScene(party, text, *)
    @party, @native_help = party, text
  end
  def pbChoosePokemon(*)
    KIFNative.scene.pbShowCommands(@native_help || "Pokémon", @party.map(&:name))
  end
  def pbSetHelpText(text); @native_help = text; end
  def pbShowCommands(text, choices, *)
    KIFNative.scene.pbShowCommands(text, choices)
  end
  def pbDisplay(text, *); KIFNative.scene.pbDisplay(text); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  %i[pbEndScene pbRefresh pbHardRefresh pbClearAnnotations pbRefreshAnnotations
     pbAnnotate pbSelect update pbSwitchBegin pbSwitchEnd pbPreSelect].each do |name|
    define_method(name) { |*| nil }
  end
end
class PokemonTrade_Scene
  def pbStartScreen(pokemon, received, first, second)
    raise ArgumentError, "native_borrowed_asset" if pokemon.instance_variable_get(:@controlled_rental)
    @pokemon, @pokemon2, @trader1, @trader2 = pokemon, received, first, second
    @sprites = {"msgwindow" => KIFNative::PresentationObject.new}
    @viewport = KIFNative::PresentationObject.new
  end
  def pbUpdate; end
  def pbScene1; end
  def pbScene2
    KIFNative.scene.events << {"kind" => "npc_trade", "given" => @pokemon.species, "received" => @pokemon2.species}
  end
end
def pbFadeOutAndHide(*); end
def pbDisposeMessageWindow(window); window&.dispose; end
class FusionPreviewScreen
  def initialize(first, second, *)
    @options = [first, second]
  end
  def getSelection
    selected = KIFNative.scene.pbShowCommands("Fusion head", @options.map(&:name))
    selected < 0 ? -1 : @options.fetch(selected)
  end
  def dispose; end
end
class SpriteMetafilePlayer
  def initialize(*); end
  def play; end
  def update; end
  def playing?; false; end
end
class Pokemon
  def self.play_cry(*); end
  def play_cry(*); end
end
class GameData::Species
  def self.cry_length(*); 0; end
  def self.play_cry_from_species(*); end
end
def pbPlayCry(*); end
def pbCryFrameLength(*); 0; end
def pbPlayDecisionSE; end
def pbPlayBuzzerSE; end
def pbPlayCancelSE; end
def pbPlayCursorSE; end
def pbPlayCloseMenuSE; end
def pbMEFade(*); end
def pbGetWildVictoryME; nil; end
def pbSaveSpriteState(*); nil; end
def pbMessageWaitForInput(*); end
def pbMessageDisplay(_window, text, *); KIFNative.scene.pbDisplayMessage(text); end
def pbFadeOutInWithMusic(*); yield; end
def pbFadeOutIn(*); yield; end
def pbTopRightWindow(text, *); KIFNative.scene.pbDisplayMessage(text); end
def pbForgetMove(pokemon, move); KIFNative.scene.pbForgetMove(pokemon, move); end
def clearUIForMoves; end

# RGSS exposes these helpers on Kernel; plain Ruby keeps top-level definitions
# private on Object. Forward to the same native helper, without changing it.
Object.private_instance_methods.grep(/\Apb[A-Z]/).each do |name|
  Kernel.define_singleton_method(name) { |*arguments, &block| TOPLEVEL_BINDING.receiver.send(name, *arguments, &block) }
end

class PokemonEvolutionScene
  def pbStartScreen(pokemon, species, *)
    @pokemon, @newspecies, @scene = pokemon, species, KIFNative.scene
    @sprites = {"msgwindow" => KIFNative::PresentationObject.new, "rsprite2" => KIFNative::PresentationObject.new}
  end
  def pbEvolution(cancel = true, reversing = false)
    return if cancel && !KIFNative.scene.pbDisplayConfirmMessage(_INTL("Evolve {1}?", @pokemon.name))
    pbEvolutionSuccess(reversing) # original rules, held-item effects and moves
  end
  def pbUpdate(*); end
  def pbEndScreen; end
end

class PokemonFusionScene
  def pbStartScreen(first, second, species, _item)
    @pokemon1, @pokemon2, @newspecies = first, second, species
    @scene = KIFNative.scene
    @sprites = %w[rsprite1 rsprite2 rsprite3 dnasplicer msgwindow].to_h { |key| [key, KIFNative::PresentationObject.new] }
    true
  end
  def pbEndScreen; end
end
module KIFNativeFusionLineage
  def pbFusionScreen(*arguments)
    original_species = @pokemon1.species
    lineage = [@pokemon1.instance_variable_get(:@controlled_id), @pokemon2.instance_variable_get(:@controlled_id)].compact.uniq.sort
    result = super
    @pokemon1.instance_variable_set(:@controlled_lineage, lineage) if @pokemon1.species != original_species
    result
  end
end
PokemonFusionScene.prepend(KIFNativeFusionLineage)

class FusionSelectOptionsScene
  def native_choices
    if shouldSelectNickname
      selected = KIFNative.scene.pbShowCommands("Nickname", [@pokemon1.name, @pokemon2.name])
      raise ArgumentError, "fusion_choice_cancelled" if selected < 0
      @nickname = [@pokemon1.name, @pokemon2.name].fetch(selected)
    end
    if @abilityList
      selected = KIFNative.scene.pbShowCommands("Ability", @abilityList.map(&:name))
      raise ArgumentError, "fusion_choice_cancelled" if selected < 0
      @selectedAbility = @abilityList.fetch(selected)
    end
    selected = KIFNative.scene.pbShowCommands("Nature", @natureList.map(&:real_name))
    raise ArgumentError, "fusion_choice_cancelled" if selected < 0
    @selectedNature = @natureList.fetch(selected)
  end
end
class PokemonOptionScreen
  def pbStartScreen(*)
    raise "native_options_not_adapted" unless @scene.is_a?(FusionSelectOptionsScene)
    @scene.native_choices
  end
end

module KIFNative
  def self.cultivate(document)
    import_state(document.fetch("initial"))
    money_before = wallet_baseline(document)
    begin_identities(document.fetch("seed"), Digest::SHA256.hexdigest(document.fetch("initial")))
    self.clock = document.fetch("time")
    srand(document.fetch("seed"))
    self.scene = Scene.new
    action = document.fetch("action")
    pokemon = $Trainer.party.find { |candidate| candidate.instance_variable_get(:@controlled_id) == action["monster_id"] }
    raise ArgumentError, "native_party_monster_not_found" unless pokemon
    raise ArgumentError, "native_borrowed_asset" if pokemon.instance_variable_get(:@controlled_rental)
    fiber = Fiber.new do
      case action.fetch("kind")
      when "use_item", "give_item"
        item = action.fetch("item").to_sym
        raise ArgumentError, "unknown_native_item" unless GameData::Item::DATA.key?(item)
        raise ArgumentError, "item_not_owned" unless $PokemonBag.pbQuantity(item) > 0
        if action["kind"] == "use_item"
          pbUseItemOnPokemon(item, pokemon, scene)
        else
          pbGiveItemToPokemon(item, pokemon, scene, $Trainer.party.index(pokemon))
        end
      when "take_item"
        pbTakeItemFromPokemon(pokemon, scene)
      else
        raise ArgumentError, "unknown_native_cultivation"
      end
    end
    prompt = fiber.resume
    document.fetch("inputs").each do |input|
      raise ArgumentError, "native_history_after_end" unless fiber.alive?
      raise ArgumentError, "native_prompt_conflict" unless input.fetch("prompt") == prompt
      self.clock = input.fetch("time", document.fetch("time"))
      prompt = fiber.resume(input.fetch("value"))
    end
    finished = !fiber.alive?
    identify if finished
    {"prompt" => finished ? nil : prompt, "events" => scene.events, "view" => view, "money_delta" => $Trainer.money - money_before,
     "state" => finished ? export_state : nil}.tap do |result|
       result["restore_assets"] = all_monsters.to_h { |entry| [entry.instance_variable_get(:@controlled_id), {"blob" => pack_asset(entry)}] } if document["capture_assets"]
     end
  ensure
    self.scene = nil
  end
end
