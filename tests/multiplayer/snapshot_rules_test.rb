# Contract tests for the standard snapshot scope; real Pokemon cases are native.
load File.expand_path("../../Data/Scripts/054_Multiplayer/001_Client.rb", __dir__)
class PokemonSystem
  attr_accessor :level_cap, :download_sprites, :shinyadvanced
  def initialize; @level_cap = 0; @download_sprites = 0; @shinyadvanced = 1; end
end
$PokemonSystem = PokemonSystem.new
$PokemonSystem.level_cap = 20
$game_switches = {:no_levels => true}
$game_variables = {:damage => 900}
originals = [$PokemonSystem, $game_switches, $game_variables]
bytes = originals.map { |value| Marshal.dump(value) }
original_export = KIFMultiplayer::Snapshot.method(:export)
KIFMultiplayer::Snapshot.define_singleton_method(:export) do |pokemon|
  raise KIFMultiplayer::Error, "invalid Pokemon" if pokemon == :invalid
  {"ability" => $game_switches[:no_levels] ? "MODIFIED" : "STANDARD",
   "cap" => $PokemonSystem.level_cap, "damage" => $game_variables[:damage] || 0,
   "expanded_colors" => $PokemonSystem.shinyadvanced}
end
checks = 0
verify = lambda do |value, message|
  raise "FAIL #{message}" unless value
  checks += 1
end
begin
  verify.call(KIFMultiplayer::Snapshot.export(:fixture)["ability"] == "MODIFIED", "fixture really observes local gameplay options")
  data = KIFMultiplayer::Snapshot.export_for_battle(:fixture)
  verify.call(data == {"ability" => "STANDARD", "cap" => 0, "damage" => 0, "expanded_colors" => 2}, "battle snapshot uses standard rules instead of current single-player options")
  verify.call([$PokemonSystem, $game_switches, $game_variables].each_with_index.all? { |value, i| value.equal?(originals[i]) }, "normal snapshot restores original option objects")
  verify.call(originals.map { |value| Marshal.dump(value) } == bytes, "normal snapshot leaves original option contents untouched")
  begin
    KIFMultiplayer::Snapshot.export_for_battle(:invalid)
    raise "invalid fixture accepted"
  rescue KIFMultiplayer::Error
    checks += 1
  end
  verify.call([$PokemonSystem, $game_switches, $game_variables].each_with_index.all? { |value, i| value.equal?(originals[i]) } && originals.map { |value| Marshal.dump(value) } == bytes, "snapshot error restores all original option state")
  puts("SNAPSHOT_RULES_CONTRACT_PASS checks=#{checks}; real engine is a separate native test")
ensure
  KIFMultiplayer::Snapshot.define_singleton_method(:export, original_export)
end
