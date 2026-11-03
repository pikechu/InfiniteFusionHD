# Exercise the complete production multiplier method; no game or saves are loaded.
require "ostruct"
module PBEffects
  ParentalBond, MeFirst, HelpingHand, Charge, Minimize = (1..5).to_a
end
module Effectiveness; NORMAL_EFFECTIVE = 8; end
load File.expand_path("../../Data/Scripts/011_Battle/002_Move/003_Move_Usage_Calculations.rb", __dir__)
class PokeBattle_Confusion < PokeBattle_Move; end
class WeatherBattler
  attr_reader :effects, :damageState
  def initialize(type)
    @type = type
    @effects = { PBEffects::Charge => 0 }
    @damageState = OpenStruct.new(critical: false, typeMod: Effectiveness::NORMAL_EFFECTIVE)
  end
  def abilityActive?; false; end
  def itemActive?; false; end
  def eachAlly; end
  def pbHasType?(type); @type == type; end
  def hasActiveAbility?(*); false; end
  def status; :NONE; end
end
class WeatherMove < PokeBattle_Move
  attr_reader :function
  def initialize(weather, physical, function)
    @physical, @function = physical, function
    @battle = OpenStruct.new(moldBreaker: false, internalBattle: false,
      field: OpenStruct.new(terrain: :None), pbWeather: weather)
    def @battle.pbCheckGlobalAbility(*); false; end
  end
  def physicalMove?; @physical; end
  def specialMove?; !@physical; end
  def ignoresReflect?; true; end
  def pbBaseDamageMultiplier(value, *); value; end
  def pbModifyDamage(value, *); value; end
end
$PokemonSystem = OpenStruct.new(damage_variance: 0, frostbite: 0, drowsy: 0)
user = WeatherBattler.new(:NORMAL)
# Explicit expected behavior, including disabled/old-save settings and other weather.
cases = [
  [:Hail, :ICE, false, "000", 1, 1.0],
  [:Hail, :ICE, false, "003", 2, 1.0],
  [:Hail, :ICE, false, "000", 0, 1.0],
  [:Hail, :ICE, false, "000", nil, 1.0],
  [:Hail, :ICE, false, "000", false, 1.0],
  [:Hail, :ICE, true, "000", 1, 1.5],
  [:Hail, :ICE, true, "000", 2, 1.5],
  [:Hail, :ICE, true, "000", 0, 1.0],
  [:Hail, :ICE, false, "122", 1, 1.5],
  [:Hail, :ICE, false, "122", 2, 1.5],
  [:Hail, :ICE, false, "122", 0, 1.0],
  [:Hail, :NORMAL, false, "000", 1, 1.0],
  [:Hail, :NORMAL, true, "000", 1, 1.0],
  [:Hail, :NORMAL, false, "122", 1, 1.0],
  [:None, :ICE, false, "000", 1, 1.0],
  [:Sandstorm, :ROCK, false, "000", 1, 1.5],
  [:Sandstorm, :ROCK, false, "122", 1, 1.0],
  [:Sandstorm, :ROCK, true, "000", 1, 1.0]
]
failures, checks = [], 0
cases.each do |weather, type, physical, function, mode, expected|
  $PokemonSystem.modernhail = mode
  move = WeatherMove.new(weather, physical, function)
  target = WeatherBattler.new(type)
  2.times do |turn|
    multipliers = {base_damage_multiplier: 1.0, attack_multiplier: 1.0,
      defense_multiplier: 1.0, final_damage_multiplier: 1.0}
    move.pbCalcDamageMultipliers(user, target, 1, :PSYCHIC, 80, multipliers)
    label = [weather, type, physical, function, mode, turn].inspect
    failures << "wrong defense #{label}: #{multipliers[:defense_multiplier]} != #{expected}" unless multipliers[:defense_multiplier] == expected
    failures << "move function mutated #{label}: #{move.function}" unless move.function == function
    checks += 2
  end
end
raise "#{failures.length} hail regressions:\n#{failures.join("\n")}" unless failures.empty?
puts "HAIL_DAMAGE_PASS checks=#{checks} cases=#{cases.length} game_loaded=false"
