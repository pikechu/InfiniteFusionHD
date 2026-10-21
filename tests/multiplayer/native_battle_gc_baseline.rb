# Diagnostic control: real native battles without any network worker, replay,
# online subclass, or guest presenter. Does not alter production Data sources.
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  result_path = File.join(directory, "native-battle-baseline.json")
  result = {"pid" => Process.pid, "ruby" => RUBY_VERSION, "http_requests" => 0, "rounds" => [], "finished" => false}
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
  $PokemonSystem.battlescene = 0
  $GameSpeed = 2
  original_trigger = Input.method(:trigger?)
  next_use = KIFMultiplayer.monotonic
  Input.define_singleton_method(:trigger?) do |button|
    if button == Input::USE && KIFMultiplayer.monotonic >= next_use
      next_use = KIFMultiplayer.monotonic + 0.2
      true
    else
      original_trigger.call(button)
    end
  end
  $Trainer.party = [:PALKIA, :KYOGRE, :LUGIA].map { |species| test.pokemon(species, [:SURF, :ICEBEAM, :SHADOWBALL, :PROTECT], :SITRUSBERRY) }
  original_globals = test.globals
  original_digest = test.digest(original_globals)
  KIFMultiplayer.with_ui_fonts do
    8.times do |index|
      test.log("NATIVE_BASELINE_BEGIN round=#{index} gc=#{GC.stat[:count]}")
      decision = KIFMultiplayer::BattleIsolation.with do
        first = $Trainer.party.map { |pokemon| pokemon.level = 50; pokemon.calc_stats; pokemon.heal; pokemon }
        second = [test.pokemon(:VENUSAUR, [:GIGADRAIN, :SLUDGEBOMB, :LEECHSEED, :PROTECT])]
        second.each { |pokemon| pokemon.level = 50; pokemon.calc_stats; pokemon.heal }
        opponent = NPCTrainer.new("Native baseline", :POKEMONTRAINER_Red)
        opponent.party = second
        scene = pbNewBattleScene
        engine = PokeBattle_Battle.new(scene, first, second, $Trainer, opponent)
        engine.controlPlayer = true
        engine.internalBattle = false
        engine.expGain = false
        engine.moneyGain = false
        engine.canRun = false
        KIFMultiplayer::BattlePresentation.with(scene) { engine.pbStartBattle }
      end
      test.check([1, 2, 3, 5].include?(decision), "offline native battle #{index} reached an engine decision")
      test.check(test.digest(original_globals) == original_digest, "offline native battle #{index} protects globals")
      result["rounds"] << {"index" => index, "decision" => decision, "gc" => GC.stat[:count]}
      File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
      test.log("NATIVE_BASELINE_END round=#{index} decision=#{decision} gc=#{GC.stat[:count]}")
    end
  end
  result["finished"] = true
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result))
  test.log("NATIVE_BASELINE_ALL_PASS rounds=8 no_http=true")
rescue Exception => error
  message = "#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}"
  test.log("NATIVE_BASELINE_FAIL #{message}") if defined?(test)
  result["error"] = message if defined?(result)
  File.write(result_path, KIFMultiplayer::WireJSON.dump(result)) if defined?(result_path)
ensure
  exit!
end
