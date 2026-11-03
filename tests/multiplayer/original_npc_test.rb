require_relative "../../server/multiplayer/native/world"
KIFNative.capture_global_baseline
KIFNative.reset(time: 1_792_713_600, seed: 84211)
KIFNative.initialize_world
KIFNative.begin_identities(84211)
KIFNative.scene = KIFNative::Scene.new
$Trainer.party = [Pokemon.new(:BULBASAUR,10)]
$Trainer.money = 100_000
KIFNative.identify

gallery = generateArtGallery(6, VAR_GALLERY_FEATURED_ARTIST, VAR_GALLERY_FEATURED_SPRITES, VAR_GALLERY_ALL_ARTIST_SPRITES)
raise "Native gallery lost original curated data" unless gallery.length == 6 && gallery.all? { |sprite| sprite.is_a?(PIFSprite) }
raise "Native gallery omitted team flags" unless pbGet(VAR_GALLERY_TEAM_FLAGS).length == 4
fiber = Fiber.new { displayGalleryFrame(0) }
prompt = fiber.resume
raise "Native artwork was not presented" unless prompt["kind"] == "gallery" && prompt["text"].include?("By ")
fiber.resume(true)
raise "Native gallery did not close" if fiber.alive?

fiber = Fiber.new { prompt_flag_purchase("flags/test", "Test", 10000) }
raise "Flag purchase did not ask" unless fiber.resume["kind"] == "confirm"
fiber.resume(true)
fiber.resume(false)
raise "Original flag purchase did not settle" unless !fiber.alive? && $Trainer.money == 90000 && $Trainer.unlocked_card_backgrounds.include?("flags/test")
raise "Original flag purchase missing journal" unless KIFNative.scene.events.any? { |event| event["kind"] == "money" && event["amount"] == -10000 }
fiber = Fiber.new { purchaseCardBackground(1000) }
prompt = fiber.resume
raise "Original card catalog did not open" unless prompt["kind"] == "choice"
prompt = fiber.resume(0)
raise "Original card did not confirm" unless prompt["kind"] == "confirm"
fiber.resume(true)
fiber.resume(false)
raise "Native card background fee changed" unless !fiber.alive? && $Trainer.money == 89000

before = $Trainer.party.first.instance_variable_get(:@controlled_id)
$game_variables[VAR_STANDARD_WONDERTRADE_LEFT] = 1
fiber = Fiber.new { pbWonderTrade(1,[],[],false) }
prompt = fiber.resume
20.times do
  break unless fiber.alive?
  answer = prompt["kind"] == "confirm" ? true : 0
  prompt = fiber.resume(answer)
end
raise "Original NPC Wonder Trade did not finish" if fiber.alive?
KIFNative.identify
raise "Original NPC Wonder Trade ticket was not consumed" unless pbGet(VAR_STANDARD_WONDERTRADE_LEFT) == 0
raise "Original NPC trade duplicated identity" unless $Trainer.party.length == 1 && $Trainer.party.first.instance_variable_get(:@controlled_id) != before
raise "Native received monster was not native trade" unless $Trainer.party.first.obtain_method == 2
quest_id = QUESTS.keys.first
pbAcceptNewQuest(quest_id,20,false)
finishQuest(quest_id, true)
owned = KIFNative.export_state
raise "Original quest did not complete" unless pbCompletedQuest?(quest_id)
KIFNative.reset_global_baseline
KIFNative.reset(time: 1_792_713_900, seed: 7)
raise "Quest completion leaked into another role's catalog" if QUESTS[quest_id].completed
KIFNative.import_state(owned)
raise "Owned quest completion was not persisted" unless pbCompletedQuest?(quest_id)
KIFNative.scene = KIFNative::Scene.new
quiz = FusionQuiz.new
fiber = Fiber.new { quiz.start_quiz(1) }
prompt = fiber.resume
100.times do
  break unless fiber.alive?
  raise "Unexpected quiz prompt #{prompt}" unless prompt["kind"] == "choice"
  value = if prompt["text"].include?("final answer")
            0
          elsif prompt["text"].include?("body")
            prompt["choices"].index(getPokemon(quiz.instance_variable_get(:@body_id)).real_name)
          elsif prompt["text"].include?("head")
            prompt["choices"].index(getPokemon(quiz.instance_variable_get(:@head_id)).real_name)
          else
            0
          end
  prompt = fiber.resume(value)
end
raise "Original fusion quiz did not finish" if fiber.alive?
raise "Original quiz points were not recorded" unless quiz.get_score > 0 && pbGet(VAR_STAT_FUSION_QUIZ_TOTAL_PTS) == quiz.get_score
raise "Quiz picture leaked after completion" unless KIFNative.quiz_picture.nil?

$Trainer.money = 3000
KIFNative.scene = KIFNative::Scene.new
storage_scene = PokemonStorageScene.new
storage_scene.pbStartBox(PokemonStorageScreen.new(storage_scene,$PokemonStorage),0)
fiber = Fiber.new { storage_scene.pbKuraShinify([-1,0],nil) }
fiber.resume
fiber.resume(0)
fiber.resume(1)
raise "Original paid shiny attempt did not settle" unless !fiber.alive? && $Trainer.money == 2000
$Trainer.party.first.shiny = true
fiber = Fiber.new { storage_scene.pbShinySell([-1,0],nil) }
fiber.resume
fiber.resume(0)
raise "Original shininess sale changed its payout" unless $Trainer.money == 3000 && !$Trainer.party.first.shiny?
raise "Net-zero original income/expense was lost" unless KIFNative.scene.events.select { |event| event["kind"] == "money" }.map { |event| event["amount"] } == [-1000,1000]

KIFNative.scene = KIFNative::Scene.new
$scene = Scene_Credits.new
fiber = Fiber.new { $scene.update }
raise "Credits were skipped by the native map loop" unless fiber.resume["kind"] == "credits"
fiber.resume(true)
raise "Credits did not restore the native map scene" unless !fiber.alive? && $scene.is_a?(KIFNative::MapScene) && $PokemonGlobal.creditsPlayed
puts "ORIGINAL_NPC_GALLERY_FLAGS_AND_WONDERTRADE_PASS"
