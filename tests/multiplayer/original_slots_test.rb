require_relative "../../server/multiplayer/native/world"
def slot_scene
  scene = SlotMachineScene.new
  scene.pbStartScene(1)
  scene
end
KIFNative.reset(time: 1_792_713_600, seed: 1234)
KIFNative.scene = KIFNative::Scene.new
$Trainer.coins = 100
[[[1,1,1],1,8,false], [[5,6,5],1,90,false], [[5,5,5],3,1500,false], [[7,7,7],1,0,true], [[0,0,1],1,4,false], [[3,2,1],1,0,false]].each do |symbols, wager, expected, replay|
  scene = slot_scene
  sprites = scene.instance_variable_get(:@sprites)
  sprites["credit"].score = 0
  symbols.each_with_index do |value, index|
    reel = sprites["reel#{index + 1}"]
    reel.instance_variable_set(:@reel, [value,value,value])
    reel.instance_variable_set(:@index, 0)
  end
  scene.wager = wager
  scene.pbPayout
  raise "Native slot payout differs: #{symbols}" unless sprites["credit"].score == expected && scene.replay == replay
  scene.pbEndScene
end

run = lambda do
  KIFNative.reset(time: 1_792_713_600, seed: 1234)
  KIFNative.begin_identities(1234)
  KIFNative.scene = KIFNative::Scene.new
  $Trainer.coins = 10
  scene = slot_scene
  fiber = Fiber.new { scene.pbMain; scene.pbEndScene }
  prompt = fiber.resume
  rounds = 0
  100.times do |index|
    break unless fiber.alive?
    value = if prompt["mode"] == "stop"
              0
            elsif rounds > 0
              2
            elsif prompt["wager"] == 0
              0
            else
              rounds += 1
              1
            end
    KIFNative.clock += 0.2
    prompt = fiber.resume(value)
  end
  raise "Native slots did not finish" if fiber.alive?
  [$Trainer.coins, KIFNative.scene.events]
end
raise "Native slot timing history cannot replay" unless run.call == run.call

KIFNative.reset(time: 1_792_713_600, seed: 1234)
KIFNative.scene = KIFNative::Scene.new
$Trainer.coins = 10
game = VoltorbFlip.new
game.pbStart
hidden = game.instance_variable_get(:@squares)
fiber = Fiber.new { game.pbScene; game.pbEndScene }
prompt = fiber.resume
raise "Voltorb hidden board leaked into its prompt" unless prompt["tiles"].all?(&:nil?)
5.times do |row|
  values = hidden[row*5,5].map { |entry| entry[2] }
  raise "Voltorb row clues differ" unless prompt["rows"][row] == [values.sum, values.count(0)]
end
position = hidden.index { |entry| entry[2] > 1 }
row, column = position.divmod(5)
value = hidden[position][2]
prompt = fiber.resume({"row" => row, "column" => column, "mark" => false})
raise "Original Voltorb flip did not award its multiplier" unless prompt["points"] == value && prompt["tiles"][position] == value
prompt = fiber.resume({"row" => -1, "column" => -1, "mark" => false})
raise "Original Voltorb quit must confirm its payout" unless prompt["kind"] == "confirm"
fiber.resume(true)
raise "Original Voltorb payout differs" unless !fiber.alive? && $Trainer.coins == 10 + value
puts "ORIGINAL_SLOTS_PAYOUT_REPLAY_TIMING_AND_COIN_LIMITS_PASS"
