require_relative "../../server/multiplayer/native/world"
require_relative "original_reference_cases"
KIFNative.reset
KIFNative.initialize_world
ids = %w[TACKLE SWORDSDANCE THUNDERBOLT TRICKROOM GROWTH FLY TRANSFORM METRONOME REST STEALTHROCK]
ids = GameData::Move::DATA.values.uniq.map { |move| move.id.to_s } if ARGV.include?("--all")
result = KIFOriginalReference.run(ids)
File.write(ARGV.fetch(0), JSON.pretty_generate(result) + "\n")
raise "Original reference cases failed" if result["cases"].values.any? { |value| value["error"] }
puts "ORIGINAL_REFERENCE_SERVER_PASS cases=#{ids.length}"
