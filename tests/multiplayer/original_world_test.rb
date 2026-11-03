# frozen_string_literal: true
require_relative "../../server/multiplayer/native/world"
KIFNative.reset
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
fiber = Fiber.new { KIFNative.advance_world }
prompt = fiber.resume
30.times do
  break unless fiber.alive?
  puts JSON.generate(prompt)
  value = case prompt.fetch("kind")
          when "confirm" then true
          when "name" then "Original"
          when "choice"
            prompt.fetch("choices").index("Confirm") || prompt.fetch("choices").index("Normal") || 0
          else 0
          end
  prompt = fiber.resume(value)
end
puts JSON.generate({"map" => $game_map.map_id, "position" => [$game_player.x, $game_player.y],
                    "pending" => fiber.alive? ? prompt : nil, "messages" => KIFNative.scene.events.last(5)})
raise "Opening did not finish" if fiber.alive? || $game_map.map_id != 157
raise "Opening granted an extra starter" unless $Trainer.party.empty?
raise "Normal difficulty not applied" if $game_switches[SWITCH_GAME_DIFFICULTY_EASY] || $game_switches[SWITCH_GAME_DIFFICULTY_HARD]
before = [$game_map.map_id, $game_player.x, $game_player.y, $Trainer.name, $Trainer.money]
snapshot = KIFNative.export_state
KIFNative.import_state(snapshot)
raise "Native world restore differs" unless before == [$game_map.map_id, $game_player.x, $game_player.y, $Trainer.name, $Trainer.money]
raise "Checkpoint marker lost" unless KIFNative.checkpoint_exists
puts "ORIGINAL_WORLD_OPENING_AND_RESTORE_PASS bytes=#{snapshot.bytesize}"
