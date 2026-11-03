# frozen_string_literal: true
# Broad native-engine dependency exercise. Each installed move is attempted in
# an actual round; this is not a proof of every effect's situational semantics.
require_relative "../../server/multiplayer/native/cultivation"
require "timeout"
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
rules_hash = KIFNative.source_hash
failures = []
passed = 0
GameData::Move::DATA.values.uniq.each do |move|
  begin
    Timeout.timeout(5) do
    KIFNative.reset
    srand(1234)
    own = Pokemon.new(:MEW, 50)
    own.moves = [Pokemon::Move.new(move.id)]
    enemy = Pokemon.new(:SNORLAX, 50)
    enemy.moves = [Pokemon::Move.new(:SPLASH)]
    $Trainer.party = [own]
    scene = KIFNative::Scene.new
    KIFNative.scene = scene
    battle = PokeBattle_Battle.new(scene, [own], [enemy], $Trainer, nil)
    battle.showAnims = false
    fiber = Fiber.new { battle.pbStartBattle }
    prompt = fiber.resume
    30.times do
      break if !fiber.alive? || battle.turnCount > 0
      value = case prompt.fetch("kind")
              when "confirm" then false
              when "target" then 1
              when "item" then nil
              else 0
              end
      prompt = fiber.resume(value)
    end
    raise "round_did_not_progress" if battle.turnCount == 0 && battle.decision == 0
    passed += 1
    end
  rescue StandardError => error
    failures << {"move" => move.id, "error" => error.class.name, "message" => error.message,
                 "trace" => error.backtrace.first(4)}
  ensure
    KIFNative.scene = nil
  end
end
result = {"passed" => passed, "failed" => failures.length, "failures" => failures,
          "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, "rules_hash" => rules_hash}
if ARGV[0]
  File.write(ARGV[0], JSON.pretty_generate(result))
end
puts JSON.generate(result)
exit(failures.empty? ? 0 : 1)
