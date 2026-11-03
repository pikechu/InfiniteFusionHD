# frozen_string_literal: true
require_relative "../../server/multiplayer/native/world"

def transact(stock, answers, sell = false)
  KIFNative.scene = KIFNative::Scene.new
  screen = PokemonMartScreen.new(PokemonMart_Scene.new, stock)
  fiber = Fiber.new { sell ? screen.pbSellScreen : screen.pbBuyScreen }
  prompt = fiber.resume
  answers.each do |answer|
    raise "Unexpected end of shop input" unless fiber.alive?
    answer = prompt.fetch("choices").index { |label| label.b.start_with?((GameData::Item.get(answer).name + " ").b) } if answer.is_a?(Symbol)
    prompt = fiber.resume(answer)
  end
  raise "Missing shop input: #{prompt}" if fiber.alive?
end

KIFNative.reset
KIFNative.initialize_world
$Trainer.money = 3000
transact([:POKEBALL], [0, 10, true, 1])
raise "Native purchase price differs" unless $Trainer.money == 1000
raise "Native purchase stock differs" unless $PokemonBag.pbQuantity(:POKEBALL) == 10
raise "Native ten-ball gift missing" unless $PokemonBag.pbQuantity(:PREMIERBALL) == 1
money = KIFNative.scene.events.select { |event| event["kind"] == "money" }
raise "Native shop purchase journal differs" unless money.length == 1 && money.first.values_at("source", "amount") == ["npc_purchase", -2000]

transact([], [:POKEBALL, 2, true, -1], true)
raise "Native selling price differs" unless $Trainer.money == 1200
raise "Native sold stock differs" unless $PokemonBag.pbQuantity(:POKEBALL) == 8
raise "Native shop sale source differs" unless KIFNative.scene.events.any? { |event| event["kind"] == "money" && event["source"] == "npc_sale" && event["amount"] == 200 }
transact([:POTION], [0, 0, -1])
raise "Cancelled purchase changed money" unless $Trainer.money == 1200
raise "Cancelled purchase added items" unless $PokemonBag.pbQuantity(:POTION) == 0

begin
  transact([:POTION], [0, 9999])
  raise "Shop accepted an unaffordable input"
rescue ArgumentError => error
  raise unless error.message == "invalid_native_choice:number"
end
raise "Rejected number changed stock" unless $PokemonBag.pbQuantity(:POTION) == 0 && $Trainer.money == 1200

# Custom NPC prices are still interpreted by the original adapter.
$game_temp.mart_prices = {POTION: [5, 2]}
transact([:POTION], [0, 2, true, -1])
raise "NPC price override lost" unless $Trainer.money == 1190 && $PokemonBag.pbQuantity(:POTION) == 2
transact([], [:POTION, 2, true, -1], true)
raise "NPC selling override lost" unless $Trainer.money == 1192 && $PokemonBag.pbQuantity(:POTION) == 0

puts "ORIGINAL_MART_PURCHASE_SALE_GIFT_CANCEL_AND_INPUT_PASS"
