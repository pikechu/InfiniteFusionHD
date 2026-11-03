begin
  load "scripts/multiplayer/test-bootstrap.rb"
  module KIFNative
    class << self; attr_accessor :scene; end
  end
  # The embedded game Ruby ships the existing wire JSON codec, not stdlib json.
  module JSON
    def self.generate(value); KIFMultiplayer::WireJSON.dump(value); end
    def self.parse(value); KIFMultiplayer::WireJSON.parse(value); end
  end
  load "server/multiplayer/native/scene.rb"
  load "tests/multiplayer/original_reference_cases.rb"
  module PBDebug
    def self.logonerr; yield; end
  end
  ids = %w[TACKLE SWORDSDANCE THUNDERBOLT TRICKROOM GROWTH FLY TRANSFORM METRONOME REST STEALTHROCK]
  ids = GameData::Move::DATA.values.uniq.map { |move| move.id.to_s } if ENV["KIF_ORIGINAL_REFERENCE_ALL"] == "1"
  result = KIFOriginalReference.run(ids)
  File.write(File.join($kif_test_directory, "original-reference.json"), KIFMultiplayer::WireJSON.dump(result))
  KIFMultiplayerFeatureTest.check(result["cases"].values.none? { |value| value["error"] }, "ORIGINAL_REFERENCE_CASES_NO_ERROR")
  KIFMultiplayerFeatureTest.log("ORIGINAL_REFERENCE_GAME_PASS cases=#{ids.length}")
  exit!(0)
rescue Exception => error
  $kif_test_log.call("ORIGINAL_REFERENCE_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
  exit!(1)
end
