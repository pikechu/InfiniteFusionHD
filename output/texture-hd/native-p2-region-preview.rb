# Targeted native P2 checks with original/candidate bitmap routing.
phase=REGION_PHASE
directory=File.expand_path('output/texture-hd/p2-evidence/region')
logfile=File.join(directory,"#{phase}-result.txt")
passed=false
begin
  File.write(logfile,"REGION_BEGIN phase=#{phase}\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384);$GameSpeed=1;srand(12345)
  $region_paths=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-region-work/native-paths.json'))[phase]
  $region_loaded=[];$region_captures=[];$region_map_traces=[]
  module RegionBitmap
    def initialize(*args)
      if args[0].is_a?(String)
        resolved=GameLanguage.bitmap_path(args[0])
        key=File.expand_path(resolved).tr('\\','/').downcase.sub(/\.(png|jpg|jpeg)\z/,'')
        args[0]=$region_paths.fetch(key,args[0])
        args[0]=args[0].sub(/\A#{Regexp.escape(Dir.pwd.tr('\\','/'))}\//i,'')
        $region_loaded << [resolved,args[0]]
      end
      super(*args)
    end
  end
  Bitmap.prepend(RegionBitmap)
  inputs=$region_paths.transform_values { |p| Digest::SHA256.hexdigest(File.binread(p)) }
  extra=%w[Graphics/Pictures/mapCursor Graphics/Pictures/mapArrowRight Graphics/Pictures/mapArrowDown]
  extra.each { |p| actual=pbResolveBitmap(p);inputs[p]=Digest::SHA256.hexdigest(File.binread(actual)) }
  File.write(File.join(directory,"#{phase}-inputs.json"),KIFMultiplayer::WireJSON.dump(inputs))
  rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-region-work/scope.json'))['entries']
  rows.each do |row|
    bmp=Bitmap.new(row['source']);raise "Size changed #{row['source']}" unless [bmp.width,bmp.height]==row['size'];bmp.dispose
  end
  $region_capture=lambda do |label,meta|
    Graphics.update
    image=Graphics.snap_to_bitmap;image.to_file(File.join(directory,"#{label}-#{REGION_PHASE}.png"));image.dispose
    $region_captures << {'label'=>label,**meta}
  end
  module RegionInput
    def update
      super
      if $region_map_driver
        raise 'Map input exhausted' if $region_map_queue.empty?
        $region_map_key=$region_map_queue.shift
      end
    end
    def press?(key);return key==$region_map_key if $region_map_driver;super;end
    def trigger?(key);return key==$region_map_key if $region_map_driver;super;end
    def repeat?(key);return key==$region_map_key if $region_map_driver;super;end
  end
  Input.singleton_class.prepend(RegionInput)
  module RegionMapObserve
    def main
      @i=0
      @sprites['cursor'].src_rect.x=0
      @window.keys.grep(/^point/).each { |key| @window[key].src_rect.x=0 }
      {'arrowLeft'=>[12,192],'arrowRight'=>[500,192],'arrowUp'=>[256,24],'arrowDown'=>[256,360]}.each { |key,xy| @sprites[key].x,@sprites[key].y=xy }
      expected=isPostgame? ? 'Graphics/Pictures/map/map_postgame' : 'Graphics/Pictures/map/map'
      recent=$region_loaded[$region_map_load_start..-1]
      raise 'Wrong map variant loaded' unless recent.any? { |pair| pair[0].downcase.sub(/\.png\z/,'')==expected.downcase }
      raise 'Wrong map canvas' unless [@window['map'].bitmap.width,@window['map'].bitmap.height]==[820,628]
      $region_map_driver=true;$region_map_tick=0
      super
    ensure
      $region_map_driver=false
    end
    def update(update_gfx=true)
      super
      return unless $region_map_driver && update_gfx
      $region_map_tick+=1
      cursor=@sprites['cursor'];point=@window.keys.find { |key| key.to_s.start_with?('point') }
      fly=point ? @window[point] : nil
      row={'case'=>$region_map_case,'tick'=>$region_map_tick,'map'=>[@window['map'].x,@window['map'].y],
       'cursor'=>[cursor.x,cursor.y,cursor.src_rect.x,cursor.src_rect.width],
       'fly'=>fly ? [fly.src_rect.x,fly.src_rect.width] : nil,
       'arrows'=>%w[arrowLeft arrowRight arrowUp arrowDown].map { |key| [@sprites[key].x,@sprites[key].y] },
       'selection'=>$PokemonGlobal.regionMapSel.dup}
      $region_map_traces << row
      if $region_map_tick<=41 || $region_map_tick==481 || ($region_map_tick>481 && $region_map_tick%40==0)
        $region_capture.call("map-#{$region_map_case}-#{$region_map_tick}",{'kind'=>'map','map_x'=>@window['map'].x,'map_y'=>@window['map'].y,'tick'=>$region_map_tick})
      end
    end
    def dispose
      $region_map_driver=false
      super
    end
  end
  BetterRegionMap.prepend(RegionMapObserve)
  backgrounds=rows.select { |r| r['source'].include?('Trainer Card/backgrounds/') }
  raise 'Unexpected card background count' unless backgrounds.length==93
  [0,2].each do |language|
    GameLanguage.load(language)
    $Trainer.name=language==2 ? '测试训练师' : 'Texture'
    $Trainer.id=123456;$Trainer.money=12345;$Trainer.badges=Array.new(16,true)
    $PokemonGlobal.startTime=Time.local(2026,10,29)
    [[0,false],[1,true]].each do |gender,postgame|
      $Trainer.trainer_type=gender==0 ? :POKEMONTRAINER_Red : :POKEMONTRAINER_Leaf
      $Trainer.character_ID=gender
      $game_switches[SWITCH_BEAT_THE_LEAGUE]=postgame
      scene=PokemonTrainerCard_Scene.new;Graphics.frame_count=0;scene.pbStartScene
      backgrounds.each do |row|
        name=row['source'].sub('Graphics/Pictures/Trainer Card/backgrounds/','').sub(/\.png\z/,'')
        $Trainer.card_background=name
        old=scene.instance_variable_get(:@sprites)['card'];scene.setCardBackground;old.dispose
        Graphics.frame_count=0;scene.pbDrawTrainerCardFront;scene.pbUpdate
        $region_capture.call("card-#{language}-#{gender}-#{name.tr('/','_')}",{'kind'=>'card','source'=>row['source'],'gender'=>gender,'postgame'=>postgame,'language'=>language})
      end
      %w[GOLD BRONZE SILVER GOLD].each_with_index do |name,state|
        $Trainer.card_background=name;scene.setCardBackground;Graphics.frame_count=0;scene.pbDrawTrainerCardFront;scene.pbUpdate
        $region_capture.call("card-cycle-#{language}-#{gender}-#{state}",{'kind'=>'card','source'=>"Graphics/Pictures/Trainer Card/backgrounds/#{name}.png",'gender'=>gender,'postgame'=>postgame,'language'=>language})
      end
      trainer=scene.instance_variable_get(:@sprites)['trainer'].bitmap
      trainer.to_file(File.join(directory,"avatar-#{language}-#{gender}-#{phase}.png"))
      scene.pbEndScene
      # The remaining pre/postgame combinations for all three refined backgrounds.
      $game_switches[SWITCH_BEAT_THE_LEAGUE]=!postgame
      scene=PokemonTrainerCard_Scene.new;Graphics.frame_count=0;scene.pbStartScene
      %w[GOLD BRONZE SILVER].each do |name|
        $Trainer.card_background=name;old=scene.instance_variable_get(:@sprites)['card'];scene.setCardBackground;old.dispose
        Graphics.frame_count=0;scene.pbDrawTrainerCardFront;scene.pbUpdate
        $region_capture.call("card-extra-#{language}-#{gender}-#{name}",{'kind'=>'card','source'=>"Graphics/Pictures/Trainer Card/backgrounds/#{name}.png",'gender'=>gender,'postgame'=>!postgame,'language'=>language})
      end
      scene.pbEndScene
      gear=PokemonPokegear_Scene.new
      gear.pbStartScene([['map',_INTL('Map')],['phone',_INTL('Phone')],['jukebox',_INTL('Jukebox')]])
      [0,1,2,0].each_with_index do |index,state|
        gear.instance_variable_set(:@index,index);gear.pbUpdate
        $region_capture.call("gear-#{language}-#{gender}-#{state}",{'kind'=>'unchanged_ui'})
      end
      gear.pbEndScene
    end
    [false,true].each do |postgame|
      $game_switches[SWITCH_BEAT_THE_LEAGUE]=postgame
      $Trainer.trainer_type=:POKEMONTRAINER_Red
      (0..1100).each { |map| $PokemonGlobal.visitedMaps[map]=true }
      $region_map_case="#{language}-#{postgame ? 1 : 0}"
      $region_map_queue=Array.new(481)+Array.new(80,Input::RIGHT)+Array.new(80,Input::DOWN)+Array.new(80,Input::LEFT)+Array.new(80,Input::UP)+[Input::BACK]
      $region_map_load_start=$region_loaded.length
      BetterRegionMap.new(-1,true,true,false,nil,true)
    end
    viewport=Viewport.new(0,0,512,384);viewport.z=99999
    help=ButtonEventScene.new(viewport)
    (1..4).each do |page|
      help.set_up_screen(page);help.update
      $region_capture.call("help-#{language}-#{page}",{'kind'=>'unchanged_ui'})
    end
    help.dispose;viewport.dispose
    File.open(logfile,'a') { |file| file.puts("REGION_LANGUAGE_PASS language=#{language}") }
  end
  # Tutor.net visual styles and its actual first-cell indicator behavior.
  tutor_settings=[:BLUE_PARTY_BACKGROUND,:BIGGER_FRAME_STYLE].to_h { |key| [key,Settings.const_get(key)] }
  [0,2].each do |language|
    GameLanguage.load(language);$Trainer.party=[Pokemon.new(:BULBASAUR,25,$Trainer),Pokemon.new(:CHARMANDER,25,$Trainer)]
    [false,true].product([false,true]).each do |blue,big|
      [[:BLUE_PARTY_BACKGROUND,blue],[:BIGGER_FRAME_STYLE,big]].each { |key,value| Settings.send(:remove_const,key);Settings.const_set(key,value) }
      tutor=PokemonTutorNet_Scene.new
      moves=[ [[:TACKLE,100,:MONEY],[]], [[:GROWL,100,:MONEY],[]], nil ]
      tutor.pbStartScene([GameData::Move.get(:TACKLE).name,GameData::Move.get(:GROWL).name,_INTL('Exit')],$Trainer.party,moves)
      sprites=tutor.instance_variable_get(:@sprites)
      2.times do |index|
        sprites['commands'].index=index;tutor.update_indicators;sprites["pokemon#{index}"].selected=true;tutor.pbUpdate
        $region_capture.call("tutor-#{language}-#{blue}-#{big}-#{index}",{'kind'=>'unchanged_ui'})
      end
      tutor.pbEndScene
    end
  end
  tutor_settings.each { |key,value| Settings.send(:remove_const,key);Settings.const_set(key,value) }
  files=['Data/Scripts/016_UI/012_UI_TrainerCard.rb','Data/Scripts/016_UI/008_UI_Pokegear.rb','Data/Scripts/052_AddOns/BetterRegionMap.rb','Data/Scripts/016_UI/001_Non-interactive UI/002_UI_Controls.rb',"Data/Scripts/102_DemICE's Tutor.net/Tutor.net.rb"]
  data={'captures'=>$region_captures,'map_traces'=>$region_map_traces,'loaded_paths'=>$region_loaded.uniq,'frame_rate'=>Graphics.frame_rate,
    'script_sha256'=>files.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
    'tutor_indicator_scope'=>'Four-cell PNG; current production panel draws the first 20x28 cell without playing its AnimatedSprite. Retained unchanged.'}
  File.write(File.join(directory,"#{phase}-review.json"),KIFMultiplayer::WireJSON.dump(data))
  File.open(logfile,'a') { |file| file.puts("REGION_PASS phase=#{phase} images=#{rows.length} captures=#{$region_captures.length} map_cases=4 card_backgrounds=#{backgrounds.length}") }
  passed=true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("REGION_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(10).join("\n")}") }
ensure
  $region_map_driver=false
  exit!(passed ? 0 : 1)
end
