load File.join(ENV.fetch("KIF_QA_SUPPORT"),"scripts/multiplayer/test-bootstrap.rb")
GameLanguage.load(2)
check=KIFMultiplayerFeatureTest.method(:check)
translations=KIFMultiplayer::WireJSON.parse(File.binread("Data/localization/zh-CN-quest-dialogue.json"))
failures=[]
translations.fetch("script_texts").each { |source,target| failures << ["script",source] unless _INTL(source)==target }
translations.fetch("map_texts").each { |map,rows| rows.each { |source,target| failures << [map,source] unless _MAPINTL(map.to_i,source)==target } }
translations.fetch("indexed_texts").each { |entry| failures << [entry["section"],entry["id"]] unless MessageTypes.get(entry["section"],entry["id"])==entry["translation"] }
check.call(failures.empty?,"all reviewed dialogue/UI/item additions resolve in the installed Android runtime: #{failures.first(3)}")
opening_count=0
[42,43,48,76,77,78,80,81].each do |map_id|
  map=load_data("Data/Map%03d.rxdata" % map_id)
  map.events.each_value do |event|
    event.pages.each do |page|
      page.list.each_with_index do |command,index|
        texts=[]
        if command.code==101
          text=command.parameters[0].dup
          while page.list[index+1]&.code==401
            index+=1
            line=page.list[index].parameters[0]
            text+=" " if !line.empty? && text[-1]!=" "
            text+=line
          end
          texts << text
        elsif command.code==102
          texts.concat(command.parameters[0])
        end
        texts.each do |text|
          next unless text.match?(/[A-Za-z]{3}/)
          next if ["Mooooooooo!","Sluuuuuurp!","Graah!"].include?(text)
          failures << [map_id,event.id,text] unless _MAPINTL(map_id,text).match?(/[\u3400-\u9fff]/)
          opening_count+=1
        end
      end
    end
  end
end
check.call(failures.empty?,"all opening event pages/choices use Chinese; #{opening_count} texts")
# Keep real map rendering while isolating automatic story progression.
module AndroidScenarioNoAutorun
  def check_event_trigger_auto; end
  def update
    return if [3,4].include?(trigger)
    super
  end
end
Game_Event.prepend(AndroidScenarioNoAutorun)
{:@clothes=>STARTING_OUTFIT,:@hat=>nil,:@hair=>"3_"+DEFAULT_OUTFIT_MALE,:@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
$MapFactory.setup(43)
$game_player.moveto(3,6)
$scene=Scene_Map.new
$scene.createSpritesets
Graphics.update
# Real accept/complete/reward methods; only the message wait is automated.
$Trainer.quests=[]
$game_variables[96]=0
$game_variables[97]=0
$game_variables[98]=0
$PokemonGlobal.questRewardsObtained=[]
captured=[]
original=Object.instance_method(:pbMessageDisplay)
Object.send(:define_method,:pbMessageDisplay) do |window,text,*args,&callback|
  captured << text
  original.bind(self).call(window,text,false)
end
begin
  pbAcceptNewQuest("pewter_1")
  check.call($Trainer.quests.length==1 && $game_variables[96]==1 && $game_variables[97]==1,"accepting a quest updates the real quest log/counters")
  pbAcceptNewQuest("pewter_1")
  check.call($Trainer.quests.length==1 && $game_variables[96]==1,"repeated acceptance cannot duplicate a quest")
  check.call(captured.any? { |text| text.include?("收集蘑菇") } && captured.all? { |text| text.match?(/[\u3400-\u9fff]/) },"quest acceptance title/description popups are Chinese")
  finishQuest("pewter_1")
  check.call(pbCompletedQuest?("pewter_1") && $game_variables[97]==0 && $game_variables[98]==1,"completing a quest preserves real completion behavior")
  finishQuest("pewter_1")
  check.call($game_variables[98]==1,"repeated completion cannot duplicate progress")
  before=$PokemonBag.pbQuantity(:HM08)
  getQuestReward(0)
  check.call($PokemonBag.pbQuantity(:HM08)==before+1 && $PokemonGlobal.questRewardsObtained.any? { |item| GameData::Item.get(item).id==:HM08 },"the first real quest reward grants HM08")
  getQuestReward(0)
  check.call($PokemonBag.pbQuantity(:HM08)==before+1,"a reward cannot be collected twice")
  pbSet(VAR_TYPE_EXPERTS_BEATEN,7)
  show_nb_type_experts_defeated
  check.call(captured.last.include?("7/12") && captured.last.match?(/[\u3400-\u9fff]/),"expert progress formats7/12 after translation")
  window=pbCreateMessageWindow
  examples=[[77,"Recently, my colleague Professor Elm in Johto came across some new information concerning the whereabouts of Mewtwo.","oak-postgame"],[232,"It's a picture of yourself... Wait, what?","saffron-photo"],[129,"\\GFantastic! You can now make an unlimited amount of Wonder Trade!","wonder-trade"]]
  examples.each do |map,source,name|
    $game_temp.player_new_map_id=map
    coordinates={77=>[9,24],232=>[8,8],129=>[7,11]}.fetch(map)
    $game_temp.player_new_x=coordinates[0]
    $game_temp.player_new_y=coordinates[1]
    $game_temp.player_new_direction=2
    $game_temp.transition_processing=false
    $scene.transfer_player
    Graphics.update
    text=_MAPINTL(map,source)
    check.call(text.match?(/[\u3400-\u9fff]/) && !text.include?("Recently") && !text.include?("Wait, what?"),"representative postgame branch #{name} is Chinese")
    original.bind(self).call(window,text,false)
    Graphics.update
    Graphics.screenshot(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"),name+"-android.png"))
  end
  pbDisposeMessageWindow(window)
ensure
  Object.send(:define_method,:pbMessageDisplay,original)
  $scene.dispose if $scene.is_a?(Scene_Map)
end
summary={"opening_texts"=>opening_count,"reviewed_script_keys"=>translations["script_texts"].length,"reviewed_map_keys"=>translations["map_texts"].values.sum(&:length),"reviewed_item_fields"=>translations["indexed_texts"].length,"quest_accept_complete_reward"=>true,"messages"=>captured,"normal_player_saves"=>false,"story_progression_scope"=>"All opening dialogue pages and reviewed map texts; representative actual quest methods. No claim of every late-game flag path."}
File.write(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"),"scenarios-result.json"),KIFMultiplayer::WireJSON.dump(summary))
KIFMultiplayerFeatureTest.log("ANDROID_SCENARIOS_PASS opening=#{opening_count} quest_accept_complete_reward=true")
exit!(0)
