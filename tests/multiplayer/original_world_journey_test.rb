# Runs the original opening scripts beyond character creation; no reward or
# story flags are injected by this driver.
require_relative "../../server/multiplayer/native/world"
def drive_original(fiber)
  prompt = fiber.resume
  100.times do |step|
    unless fiber.alive?
      KIFNative.identify
      return
    end
    puts JSON.generate(prompt)
    $journey_record_approach = false if prompt["kind"] == "command"
    value = case prompt.fetch("kind")
            when "confirm" then true
            when "name" then "Blue"
            when "command"
              KIFNative.active_battle&.wildBattle? ? ($journey_capture && $PokemonBag.pbQuantity(:POKEBALL) > 0 ? 1 : 3) : 0
            when "move" then 0
            when "item" then {"item" => "POKEBALL", "target" => 1}
            when "target" then 1
            when "switch" then KIFNative.active_battle.pbParty(prompt.fetch("battler")).index { |pokemon| pokemon.able? }
            when "choice"
              choices = prompt.fetch("choices")
              choices.index("Confirm") || choices.index("Normal") || choices.index("Classic") ||
                choices.index("Change clothes") || choices.index("Wear") || 0
            else raise "Unsupported journey prompt: #{prompt}"
            end
    prompt = fiber.resume(value)
  end
  raise "Journey prompt limit" if fiber.alive?
end

def walk_original_to(target, expected_map, same_map = false)
  100.times do |step|
    return if block_given? && yield
    reached = lambda do |point|
      case target
      when :north then point[1] == 0 && $game_player.can_move_from_coordinate?(*point, 8)
      when :south then point[1] == $game_map.height - 1 && $game_player.can_move_from_coordinate?(*point, 2)
      else point == target
      end
    end
    return if $game_map.map_id == expected_map && (!same_map || reached.call([$game_player.x, $game_player.y]))
    start = [$game_player.x, $game_player.y]
    queue, paths = [start], {start => []}
    found = nil
    until queue.empty?
      x, y = queue.shift
      if reached.call([x,y])
        found = [x,y]
        break
      end
      [[2,0,1], [4,-1,0], [6,1,0], [8,0,-1]].each do |direction, dx, dy|
        point = [x+dx, y+dy]
        next if paths.key?(point) || !$game_map.valid?(*point)
        next unless $game_player.can_move_from_coordinate?(x, y, direction)
        paths[point] = paths[[x,y]] + [direction]
        queue << point
      end
    end
    path = found && paths[found]
    raise "No native path to #{target} on #{$game_map.map_id}" unless path && !path.empty?
    drive_original(Fiber.new do
      $journey_fixtures["rival_approach"] << path.first if $journey_record_approach
      $game_player.move_generic(path.first)
      KIFNative.advance_world(40)
    end)
    if $game_map.map_id != expected_map && [$game_player.x, $game_player.y] == start
      drive_original(Fiber.new { $game_player.check_event_trigger_there([0,2]); KIFNative.advance_world(40) })
    end
  end
  raise "Native travel did not reach map #{expected_map}"
end

KIFNative.reset
$journey_fixtures = {"rival_approach" => []}
KIFNative.clock = 1_792_713_600
srand(123_456)
KIFNative.begin_identities(123_456)
KIFNative.initialize_world
$Trainer.money = 1000 # Existing controlled-account initial grant policy.
KIFNative.scene = KIFNative::Scene.new
last_map = nil
300.times do |segment|
  fiber = Fiber.new { KIFNative.advance_world(40) }
  drive_original(fiber)
  if last_map != $game_map.map_id
    puts JSON.generate({"segment" => segment, "map" => $game_map.map_id, "name" => $game_map.name,
                        "x" => $game_player.x, "y" => $game_player.y, "party" => $Trainer.party.map(&:species)})
    last_map = $game_map.map_id
  end
  break if $game_map.map_id == 69
end
raise "Opening did not reach the player's room" unless $game_map.map_id == 69
raise "Opening minted an unearned starter" unless $Trainer.party.empty?
puts "ORIGINAL_WORLD_FULL_OPENING_PASS"
walk_original_to([8,5], 69, true)
drive_original(Fiber.new do
  $game_player.turn_up
  $game_player.check_event_trigger_there([0,2])
  KIFNative.advance_world(40)
end)
raise "Wardrobe did not equip unlocked clothes" if isWearingClothes(STARTING_OUTFIT)
walk_original_to([10,5], 43)
puts JSON.generate({"map" => $game_map.map_id, "name" => $game_map.name, "x" => $game_player.x, "y" => $game_player.y})
walk_original_to([7,10], 42)
walk_original_to([20,0], 77)
walk_original_to([13,16], 77, true)
drive_original(Fiber.new do
  $game_player.turn_up
  $game_player.check_event_trigger_there([0,2])
  KIFNative.advance_world(40)
end)
raise "Original starter was not granted" unless $Trainer.party.length == 1 && $Trainer.party.first.level == 5
$journey_fixtures["before_rival"] = {"state" => KIFNative.export_state, "view" => KIFNative.world_view}
$journey_record_approach = true
walk_original_to([9,25], 42)
raise "Rival battle did not run" unless KIFNative.scene.events.any? { |event| event["kind"] == "battle_end" }
walk_original_to([20,0], 42, true)
drive_original(Fiber.new { $game_player.move_generic(8); KIFNative.advance_world(40) })
raise "Original map connection failed" unless $game_map.map_id == 78
walk_original_to(:north, 78, true)
drive_original(Fiber.new { $game_player.move_generic(8); KIFNative.advance_world(40) })
raise "Viridian connection failed" unless $game_map.map_id == 79
walk_original_to([25,29], 79, true)
drive_original(Fiber.new { $game_player.move_generic(8); KIFNative.advance_world(40) })
raise "Native shop door failed" unless $game_map.map_id == 81
walk_original_to([6,8], 81, true)
drive_original(Fiber.new { $game_player.turn_up; $game_player.check_event_trigger_there([0,2]); KIFNative.advance_world(40) })
raise "Original delivery parcel missing" unless $PokemonBag.pbQuantity(:OAKSPARCEL) == 1 && $PokemonBag.pbQuantity(:DNASPLICERS) == 1
walk_original_to([6,12], 81, true)
drive_original(Fiber.new { $game_player.move_generic(2); KIFNative.advance_world(40) })
raise "Native shop exit failed" unless $game_map.map_id == 79
walk_original_to(:south, 79, true)
drive_original(Fiber.new { $game_player.move_generic(2); KIFNative.advance_world(40) })
raise "Return to Route 1 failed" unless $game_map.map_id == 78
walk_original_to(:south, 78, true)
drive_original(Fiber.new { $game_player.move_generic(2); KIFNative.advance_world(40) })
raise "Return to Pallet failed" unless $game_map.map_id == 42
walk_original_to([31,18], 42, true)
drive_original(Fiber.new { $game_player.move_generic(8); KIFNative.advance_world(40) })
raise "Return to original lab failed" unless $game_map.map_id == 77
walk_original_to([12,14], 77, true)
drive_original(Fiber.new { $game_player.turn_up; $game_player.check_event_trigger_there([0,2]); KIFNative.advance_world(40) })
raise "Original parcel delivery did not settle" unless $PokemonBag.pbQuantity(:OAKSPARCEL) == 0 && $PokemonBag.pbQuantity(:POKEBALL) == 5 && $Trainer.has_pokedex
walk_original_to([9,25], 42)
walk_original_to(:north, 42, true)
$journey_capture = true
drive_original(Fiber.new { $game_player.move_generic(8); KIFNative.advance_world(40) })
raise "Capture journey did not reach Route 1" unless $game_map.map_id == 78
walk_original_to(:north, 78, true) { $Trainer.party.length > 1 }
raise "Natural capture did not add a creature" unless $Trainer.party.length > 1
raise "Natural capture did not consume an earned ball" unless $PokemonBag.pbQuantity(:POKEBALL) < 5
identifiers = KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }
raise "Native capture identifiers conflict" unless identifiers.all? { |id| id.is_a?(String) && id.match?(/\Acm_[a-f0-9]{32}\z/) } && identifiers.uniq.length == identifiers.length
before = KIFNative.world_view
KIFNative.import_state(KIFNative.export_state)
raise "Natural journey restore lost state" unless KIFNative.world_view == before
puts "ORIGINAL_WORLD_STARTER_RIVAL_DELIVERY_AND_CAPTURE_PASS"
if ARGV[0]
  $journey_fixtures["after_capture"] = {"state" => KIFNative.export_state, "view" => KIFNative.world_view}
  $journey_fixtures["rules_hash"] = KIFNative.source_hash
  File.write(ARGV[0], JSON.generate($journey_fixtures))
end
