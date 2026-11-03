# frozen_string_literal: true
# Scene adapter: retains native command validation and effects. Only rendering,
# sound and input acquisition are replaced by structured events and prompts.
module KIFNative
  def self.message_text(value)
    text = value.to_s.dup.force_encoding(Encoding::UTF_8)
    text.gsub!(/\\\\/, "\5")
    text.gsub!(/\\pn/i) { $Trainer.name.to_s } if $Trainer
    text.gsub!(/\\pm/i) { _INTL("${1}", $Trainer.money.to_s_formatted) } if $Trainer
    32.times do
      previous = text.dup
      text.gsub!(/\\v\[(\d+)\]/i) { $game_variables[Regexp.last_match(1).to_i].to_s.dup.force_encoding(Encoding::UTF_8) }
      break if previous == text
    end
    raise ArgumentError, "native_message_variable_cycle" if text.match?(/\\v\[\d+\]/i)
    text.gsub!(/\\ch\[([^\]]*)\]/i) do
      commands = Regexp.last_match(1).dup
      variable = pbCsvPosInt!(commands)
      cancel = pbCsvField!(commands).to_i
      choices = []
      choices << pbCsvField!(commands) until commands.empty?
      $game_variables[variable] = scene.pbShowCommands("", choices, cancel)
      $game_map.need_refresh = true if $game_map
      ""
    end
    text.gsub!(/\\n/i, "\n")
    text.gsub!(/\\(?:sign|f|ff|ts|cl|me|se|wt|wtnp|w|c|l)\[[^\]]*\]/i, "")
    text.gsub!(/\\(?:pog|pg|cn|pt|ft|hs|wd|wm|op|cl|wu|g|b|r|\.|\||!|\^)/i, "")
    text.gsub("\5", "\\")
  end
  class Scene
    attr_reader :events, :battle
    def initialize(events = nil)
      @events = events || []
    end
    def ask(kind, detail = {})
      KIFNative.input_elapsed = nil if KIFNative.respond_to?(:input_elapsed=)
      KIFNative.identify if KIFNative.respond_to?(:identity_seed) && !KIFNative.identity_seed.nil?
      # RGSS Marshal labels can be binary-encoded; compare the same UTF-8 JSON
      # representation that crossed the RPC boundary, not Ruby encodings.
      prompt = JSON.parse(JSON.generate({"kind" => kind}.merge(detail)))
      value = Fiber.yield(prompt)
      valid = case kind
              when "confirm" then value == true || value == false
              when "region_map", "gallery", "movie", "credits" then value == true
              when "fishing" then value.nil? || ["use", "back"].include?(value)
              when "slot" then value.is_a?(Integer) && (detail.fetch("mode") == "stop" ? value == 0 : (0..2).include?(value))
              when "voltorb"
                value.is_a?(Hash) && value.keys.sort == %w[column mark row] && [true,false].include?(value["mark"]) &&
                  value["row"].is_a?(Integer) && value["column"].is_a?(Integer) &&
                  (((0..4).include?(value["row"]) && (0..4).include?(value["column"])) || (value["row"] == -1 && value["column"] == -1 && !value["mark"]))
              when "command" then value.is_a?(Integer) && (0..4).include?(value)
              when "safari_command" then value.is_a?(Integer) && (0..3).include?(value)
              when "move" then value.is_a?(Integer) && (-3..3).include?(value)
              when "switch" then value.is_a?(Integer) && (-1...@battle.pbParty(detail.fetch("battler")).length).include?(value)
              when "target" then value.is_a?(Integer) && (-1..@battle.maxBattlerIndex).include?(value)
              when "choice" then value.is_a?(Integer) && ((0...detail.fetch("choices").length).include?(value) || (value == -1 && detail.fetch("cancel", -1) != 0))
              when "number" then value.is_a?(Integer) && ((detail.fetch("minimum")..detail.fetch("maximum")).include?(value) || value == detail["cancellation"])
              when "forget_move" then value.is_a?(Integer) && (-1..3).include?(value)
              when "pokemon" then value.is_a?(Integer) && (-1...$Trainer.party.length).include?(value)
              when "name" then value.is_a?(String) && value.length <= detail.fetch("maximum", Pokemon::MAX_NAME_SIZE) && !value.match?(/[\\\p{Cc}\p{Cf}]/)
              when "item" then value.nil? || (value.is_a?(Hash) && (value.keys - %w[item target move]).empty? && value["item"].is_a?(String) && value.fetch("target", 0).is_a?(Integer) && value.fetch("move", -1).is_a?(Integer))
              when "storage"
                value.is_a?(Hash) && value.keys.sort == %w[box slot] && value["box"].is_a?(Integer) && value["slot"].is_a?(Integer) &&
                  (([-4,-3].include?(value["box"]) && value["slot"] == 0) || (value["box"] == -1 && (0...Settings::MAX_PARTY_SIZE).include?(value["slot"])) ||
                   ((0...$PokemonStorage.maxBoxes).include?(value["box"]) && (0...$PokemonStorage.maxPokemon(value["box"])).include?(value["slot"])))
              else false
              end
      raise ArgumentError, "invalid_native_choice:#{kind}" unless valid
      value
    end
    def pbStartBattle(battle)
      @battle = battle
      KIFNative.active_battle = battle if KIFNative.respond_to?(:active_battle=)
      @events << {"kind" => "battle_start"}
    end
    def pbEndBattle(decision)
      @events << {"kind" => "battle_end", "decision" => decision}
      KIFNative.active_battle = nil if KIFNative.respond_to?(:active_battle=)
    end
    def pbAnimation(move, user, targets, hit = 0)
      @events << {"kind" => "move_animation", "move" => move, "user" => user&.index,
                  "targets" => Array(targets).map { |target| target&.index }, "hit" => hit}
    end
    def pbCommonAnimation(name, user = nil, targets = nil)
      @events << {"kind" => "common_animation", "name" => name, "user" => user&.index,
                  "targets" => Array(targets).map { |target| target&.index }}
    end
    def pbThrow(ball, shakes, critical, target, show_player = false)
      @events << {"kind" => "throw", "ball" => ball, "shakes" => shakes, "critical" => critical, "target" => target, "show_player" => show_player}
    end
    def pbThrowAndDeflect(ball, target)
      @events << {"kind" => "throw_deflect", "ball" => ball, "target" => target}
    end
    def pbFaintBattler(battler)
      @events << {"kind" => "faint", "battler" => battler.index}
    end
    def pbEXPBar(battler, start_exp, end_exp, before, after)
      return unless battler
      @events << {"kind" => "exp_bar", "battler" => battler.index, "minimum" => start_exp, "maximum" => end_exp, "before" => before, "after" => after}
    end
    def pbLevelUp(pokemon, battler, *old_stats)
      return unless battler
      @events << {"kind" => "level_up", "battler" => battler.index, "monster" => KIFNative.monster_view(pokemon), "old_stats" => old_stats}
    end
    def pbDisplayMessage(text, *)
      @events << {"kind" => "message", "text" => KIFNative.message_text(text)}
      yield if block_given?
    end
    alias pbDisplayPausedMessage pbDisplayMessage
    alias pbDisplay pbDisplayMessage
    def pbConfirm(text); pbDisplayConfirmMessage(text); end
    def pbChoosePokemon(text = "")
      ask("pokemon", {"text" => text})
    end
    def pbDisplayConfirmMessage(text); ask("confirm", {"text" => KIFNative.message_text(text)}); end
    def pbShowCommands(text, commands, cancel = -1, *)
      selected = ask("choice", {"text" => KIFNative.message_text(text), "choices" => commands, "cancel" => cancel})
      selected == -1 && cancel > 0 ? cancel - 1 : selected
    end
    def pbCommandMenu(index, *)
      ask("command", {"battler" => index})
    end
    def pbSafariCommandMenu(index)
      ask("safari_command", {"battler" => index, "balls" => @battle.ballCount})
    end
    def pbSafariStart; end
    def pbThrowBait; @events << {"kind" => "safari_bait"}; end
    def pbThrowRock; @events << {"kind" => "safari_rock"}; end
    def pbFightMenu(index, mega)
      loop do
        value = ask("move", {"battler" => index, "mega" => mega})
        break if yield(value)
      end
    end
    def pbPartyScreen(index, cancel)
      loop do
        value = ask("switch", {"battler" => index, "cancel" => cancel})
        break if yield(value, self)
      end
    end
    def pbChooseTarget(index, target)
      ask("target", {"battler" => index, "target_type" => target.id})
    end
    def pbForgetMove(pokemon, move)
      ask("forget_move", {"species" => pokemon.species, "move" => move})
    end
    def pbNameEntry(text, pokemon)
      ask("name", {"text" => text, "species" => pokemon.species})
    end
    def pbItemMenu(index, first)
      loop do
        value = ask("item", {"battler" => index, "first" => first})
        break if value.nil?
        item = GameData::Item::DATA.fetch(value.fetch("item").to_sym)
        raise ArgumentError, "item_not_owned" unless $PokemonBag.pbQuantity(item.id) > 0
        target = value.fetch("target", index)
        raise ArgumentError, "invalid_item_target" unless (-1..[Settings::MAX_PARTY_SIZE, @battle.maxBattlerIndex].max).include?(target)
        raise ArgumentError, "invalid_item_move" unless (-1..3).include?(value.fetch("move", -1))
        break if yield(item.id, item.battle_use, value.fetch("target", index), value.fetch("move", -1), self)
      end
    end
    def pbHPChanged(battler, old_hp, *)
      @events << {"kind" => "hp", "battler" => battler.index, "before" => old_hp, "after" => battler.hp}
    end
    def pbHitAndHPLossAnimation(values)
      values.each { |battler, old_hp, _| pbHPChanged(battler, old_hp) }
    end
    # These callbacks exclusively change sprites, windows, sounds or animations.
    %i[pbDamageAnimation
       pbHideAbilitySplash pbHideCaptureBall pbHideHelp pbRecall
       pbRefresh pbRefreshOne pbReplaceAbilitySplash pbResetMoveIndex
       pbSendOutBattlers pbShowAbilitySplash pbShowHelp pbShowOpponent
       pbShowPartyLineup pbShowPokedex pbSwapBattlerSprites
       pbThrowSuccess pbTrainerBattleSuccess pbUpdate
       pbWildBattleSuccess pbBeginAttackPhase pbBeginCommandPhase
       pbBeginEndOfRoundPhase pbChangePokemon pbSetHelpText
       pbClearAnnotations pbHardRefresh pbRefreshAnnotations].each do |method|
      define_method(method) { |*args| nil }
    end
  end
end

# Native rules call these audio-only global helpers directly.
def pbSEPlay(*); end
def pbMEPlay(*); end
def pbBGMPlay(*); end
def pbBGMFade(*); end
def pbBGMStop(*); end
def pbWait(*); end
def updatePinkanBerryDisplay; end # overworld HUD refresh, no inventory mutation
