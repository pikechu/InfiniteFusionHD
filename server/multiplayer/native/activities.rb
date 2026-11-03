# Presentation adapters retain the original activity models and controllers.
module KIFNative
  class << self; attr_accessor :purify_scene, :quiz_picture; end
end
class FusionQuiz
  def show_fusion_picture(obscured = false, *)
    KIFNative.quiz_picture = {"head" => @head_id, "body" => @body_id, "obscured" => obscured}
  end
  def hide_fusion_picture; KIFNative.quiz_picture = nil; end
  def refresh_streak_ui; end
  def dispose; hide_fusion_picture; end
end
class OnlineWondertrade
  def pbWonderTrade
    KIFNative.scene.pbDisplay("Original controlled characters use the controlled trading center. External community-pool assets stay in historical local play.")
    nil
  end
end
class Movie
  def play(image = 12)
    KIFNative.scene.ask("movie", {"path" => @framesPath, "bgm" => @bgm, "frames" => @maxFrame, "can_stop" => @canStopEarly, "image" => image})
    @finished = true
  end
end
class Scene_Credits
  def update
    KIFNative.scene.ask("credits", {"played" => $PokemonGlobal.creditsPlayed == true})
    $PokemonGlobal.creditsPlayed = true
    $scene = KIFNative::MapScene.new
    $scene.createSpritesets
  end
end
module KIFNativeMapSceneFactory
  def new(*arguments, &block)
    return KIFNative::MapScene.new(*arguments, &block) if self == Scene_Map
    super
  end
end
Scene_Map.singleton_class.prepend(KIFNativeMapSceneFactory)

module KIFNativeContestClock
  def pbStart(*arguments)
    super
    @controlled_started_at = KIFNative.clock
  end
  def timer
    return super unless @controlled_started_at && KIFNative.clock
    Graphics.frame_count - [(KIFNative.clock-@controlled_started_at)*Graphics.frame_rate,0].max.floor
  end
  def expired?
    return super unless @controlled_started_at && KIFNative.clock
    stored = @timer
    @timer = timer
    begin
      super
    ensure
      @timer = stored
    end
  end
end
BugContestState.prepend(KIFNativeContestClock)
class HallOfFame_Scene
  def pbStartSceneEntry
    @hallEntry = []
    saveHallEntry
    KIFNative.scene.events << {"kind" => "hall_of_fame", "number" => $PokemonGlobal.hallOfFameLastNumber,
      "party" => @hallEntry.map { |pokemon| KIFNative.monster_view(pokemon) }}
  end
  def pbAnimationLoop
    KIFNative.scene.pbShowCommands("Hall of Fame ##{$PokemonGlobal.hallOfFameLastNumber}\n#{@hallEntry.map { |pokemon| "#{pokemon.name} Lv.#{pokemon.level}" }.join("\n")}", ["Continue"], 1)
  end
  def pbStartScenePC; end
  def pbPCSelection
    rows = $PokemonGlobal.hallOfFame
    chosen = KIFNative.scene.pbShowCommands("Hall of Fame", rows.each_with_index.map { |party, index| "#{index+1}: #{party.map(&:name).join(', ')}" })
    return if chosen < 0
    KIFNative.scene.pbShowCommands(rows.fetch(chosen).map { |pokemon| "#{pokemon.name} Lv.#{pokemon.level}" }.join("\n"), ["Back"], 1)
  end
  def pbEndScene; end
end
class RelicStoneScene
  def pbStartScene(pokemon); @pokemon = pokemon; end
  def pbDisplay(text, *); KIFNative.scene.pbDisplay(text); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  def pbEndScene; end
end
class PurifyChamberScene
  attr_reader :heldpkmn
  def pbStart(chamber)
    @chamber = chamber
    KIFNative.purify_scene = self
  end
  def pbEnd; KIFNative.purify_scene = nil; end
  def pbChooseSet
    KIFNative.scene.pbShowCommands("Purify chamber", @chamber.sets.each_with_index.map { |set, index| "#{index+1}: #{set.shadow&.name || '-'} / #{set.list.map(&:name).join(', ')}" })
  end
  def pbSwitch(set)
    selected = pbChooseSet
    selected < 0 ? set : selected
  end
  def pbSetScreen
    positions = (0..[@chamber.setCount(@chamber.currentSet)*2,1].max).to_a
    names = positions.map do |position|
      pokemon = PurifyChamberHelper.pbGetPokemon(@chamber, position)
      "#{position}: #{pokemon ? pokemon.name : 'Empty'}"
    end
    selected = KIFNative.scene.pbShowCommands("Set #{@chamber.currentSet+1}#{@heldpkmn ? ' / Holding '+@heldpkmn.name : ''}", names+["Previous set", "Next set", "Back"])
    return [0,positions.fetch(selected)] if selected >= 0 && selected < positions.length
    return [1,(@chamber.currentSet-1)%PurifyChamber::NUMSETS] if selected == positions.length
    return [1,(@chamber.currentSet+1)%PurifyChamber::NUMSETS] if selected == positions.length+1
    [3,0]
  end
  def pbMove(position); @heldpkmn = PurifyChamberHelper.pbGetPokemon(@chamber,position); end
  def pbShift(position, _pokemon); @heldpkmn = PurifyChamberHelper.pbGetPokemon(@chamber,position); end
  def pbPlace(*); @heldpkmn = nil; end
  def pbWithdraw(*); @heldpkmn = nil; end
  def pbChoosePokemon
    PokemonStorageScreen.new(PokemonStorageScene.new, $PokemonStorage).pbChoosePokemon
  end
  def pbSummary(position, held)
    pokemon = held || PurifyChamberHelper.pbGetPokemon(@chamber,position)
    KIFNative.scene.pbShowCommands("#{pokemon.name} Lv.#{pokemon.level}\n#{pokemon.moves.map(&:name).join(', ')}", ["Back"], 1) if pokemon
  end
  def pbDisplay(text); KIFNative.scene.pbDisplay(text); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  def pbShowCommands(text, commands); KIFNative.scene.pbShowCommands(text, commands); end
  %i[pbUpdate pbRefresh pbOpenSet pbCloseSet pbOpenSetDetail pbCloseSetDetail pbPurify pbReplace pbRotate pbPositionHint pbChangeSet].each { |name| define_method(name) { |*| nil } }
end
