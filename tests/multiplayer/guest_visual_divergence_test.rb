load File.expand_path("guest_scene_test.rb", __dir__)
entry = {"slot" => 1, "species" => "PIKACHU", "level" => 50, "name" => "Public Pokemon", "hp" => 43,
         "totalhp" => 100, "status" => "NONE", "party_index" => 0, "form" => 0, "gender" => 0,
         "shiny" => false, "appearance" => {}}
%w[species hp totalhp status level party_index].each do |field|
  battler = entry.reject { |key, _| %w[slot form gender shiny appearance].include?(key) }.merge("index" => 1)
  visual = Marshal.load(Marshal.dump(entry))
  visual[field] = {"species" => "BLASTOISE", "hp" => 42, "totalhp" => 101, "status" => "POISON", "level" => 51, "party_index" => 1}[field]
  presenter = KIFMultiplayer::GuestBattlePresenter.allocate
  presenter.instance_variable_set(:@failed, false)
  def presenter.build(*); @divergent_build_called = true; end
  def presenter.fallback(error); @divergence_error = error; end
  state = {"battlers" => [battler], "visuals" => {"version" => 1, "seq" => 1, "complete" => true, "events" => [], "battlers" => [visual]}}
  presenter.accept(state)
  error = presenter.instance_variable_get(:@divergence_error)
  assert(error.is_a?(KIFMultiplayer::BattleError) && error.message.include?("differs from authoritative #{field}"), "Live observer accepted a divergent final #{field}")
  assert(!presenter.instance_variable_get(:@divergent_build_called), "Divergent visual metadata allocated/played the native scene before validation")
end
puts "GUEST_VISUAL_DIVERGENCE_PASS checks=#{$checks}"
