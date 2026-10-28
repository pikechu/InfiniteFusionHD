# Production naming and dex rendering; all assets remain unchanged in this run.
directory=File.expand_path('output/texture-hd/p2-evidence/dex')
logfile=File.join(directory,'dex-naming-result.txt')
passed=false
begin
  File.write(logfile,"DEX_NAMING_BEGIN\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384)
  $GameSpeed=1
  srand(12345)
  $texture_dex_loaded=[]
  module TextureDexBitmap
    def initialize(*args)
      $texture_dex_loaded << GameLanguage.bitmap_path(args[0]) if args[0].is_a?(String)
      super(*args)
    end
  end
  Bitmap.prepend(TextureDexBitmap)
  $texture_dex_labels=[]
  $texture_dex_trace=[]
  $texture_dex_capture=lambda do |label|
    Graphics.update
    bitmap=Graphics.snap_to_bitmap
    bitmap.to_file(File.join(directory,"#{label}.png"));bitmap.dispose
    $texture_dex_labels << label
  end
  module TextureNamingObserve
    def pbUpdate
      super
      if $texture_naming_label
        bottom=@sprites['bottomtab'];top=@sprites['toptab']
        $texture_dex_trace << {'label'=>$texture_naming_label,'mode'=>@mode,
          'bottom'=>[bottom.x,bottom.y],'top'=>[top.x,top.y],'cursor_visible'=>@sprites['cursor'].visible}
      end
    end
  end
  PokemonEntryScene2.prepend(TextureNamingObserve)
  module TextureDexBack
    def trigger?(key)
      return key==Input::BACK if $texture_dex_back
      super
    end
    def repeat?(key)
      return false if $texture_dex_back
      super
    end
  end
  Input.singleton_class.prepend(TextureDexBack)
  module TextureDexParameterCapture
    def pbRefreshDexSearchParam(*args)
      super
      if $texture_dex_param_label
        pbUpdate
        $texture_dex_capture.call($texture_dex_param_label)
      end
    end
  end
  PokemonPokedex_Scene.prepend(TextureDexParameterCapture)
  [0,2].each do |language|
    GameLanguage.load(language)
    Graphics.frame_count=0
    $Trainer.name='Texture'
    $Trainer.has_pokedex=true
    pokemon=Pokemon.new(:BULBASAUR,25,$Trainer)
    [1,4,7,25].each { |species| $Trainer.pokedex.set_seen(species);$Trainer.pokedex.set_owned(species) }
    [2,4].each do |subject|
      scene=PokemonEntryScene2.new
      scene.pbStartScene(_INTL('Enter a name.'),0,10,language==2 ? '测试A' : 'TestA',subject,pokemon)
      4.times do |tab|
        $texture_naming_label="naming-#{language}-#{subject}-tab-#{tab}"
        scene.pbChangeTab(tab)
        sprites=scene.instance_variable_get(:@sprites)
        raise 'Naming tab lost anchor' unless [sprites['bottomtab'].x,sprites['bottomtab'].y]==[22,162]
        [0,64,PokemonEntryScene2::MODE1,PokemonEntryScene2::MODE4,PokemonEntryScene2::BACK,PokemonEntryScene2::OK].each_with_index do |pos,index|
          sprites['cursor'].setCursorPos(pos);scene.pbUpdate
          $texture_dex_capture.call("naming-#{language}-#{subject}-#{tab}-#{index}")
        end
      end
      $texture_naming_label="naming-#{language}-#{subject}-wrap"
      scene.pbChangeTab(0)
      raise 'Naming tab wrap failed' unless scene.instance_variable_get(:@mode)==0
      $texture_naming_label=nil
      scene.pbEndScene
    end
    dex=PokemonPokedexMenu_Scene.new
    dex.pbStartScene([_INTL('Full Pokédex'),_INTL('Owned Pokémon'),_INTL('Exit')],[[4,4,420],[4,4,420]])
    dex.pbUpdate;$texture_dex_capture.call("dex-menu-#{language}");dex.pbEndScene
    dex=PokemonPokedex_Scene.new
    dex.pbStartScene
    sprites=dex.instance_variable_get(:@sprites)
    [0,1,3,0].each_with_index do |index,state|
      sprites['pokedex'].index=index;dex.pbRefresh;dex.pbUpdate
      $texture_dex_capture.call("dex-list-#{language}-#{state}")
    end
    $texture_dex_back=true
    dex.pbDexSearch
    $texture_dex_back=false
    sprites.each { |key,sprite| sprite.visible=false unless %w[searchbg overlay searchcursor].include?(key) }
    sprites['searchbg'].visible=true
    sprites['searchcursor'].visible=true
    sprites['searchcursor'].mode=-1
    params=dex.instance_variable_get(:@searchParams)
    10.times do |index|
      sprites['searchcursor'].index=index;dex.pbRefreshDexSearch(params,index);dex.pbUpdate
      $texture_dex_capture.call("dex-search-#{language}-#{index}")
    end
    7.times do |mode|
      $texture_dex_param_label="dex-param-#{language}-#{mode}"
      $texture_dex_back=true
      dex.pbDexSearchCommands(mode,mode.between?(2,4) ? [-1,-1] : [0],0)
      $texture_dex_back=false
      $texture_dex_param_label=nil
    end
    dex.pbEndScene
    entry=PokemonPokedexInfo_Scene.new
    entry.pbStartScene([[1,'',0,0,1,false]],0,-1)
    [1,3,1].each_with_index do |page,state|
      entry.instance_variable_set(:@page,page)
      entry.drawPage(page);entry.pbUpdate
      $texture_dex_capture.call("dex-info-#{language}-#{state}-#{page}")
    end
    entry.pbEndScene
    File.open(logfile,'a') { |file| file.puts("DEX_NAMING_LANGUAGE_PASS language=#{language}") }
  end
  files=['Data/Scripts/016_UI/024_UI_TextEntry.rb','Data/Scripts/016_UI/002_UI_Pokedex_Menu.rb','Data/Scripts/016_UI/003_UI_Pokedex_Main.rb','Data/Scripts/016_UI/004_UI_Pokedex_Entry.rb','Data/Scripts/052_AddOns/UI_Pokedex_SpritesPage.rb']
  data={'renders'=>$texture_dex_labels,'traces'=>$texture_dex_trace,'loaded_paths'=>$texture_dex_loaded.uniq,
   'script_sha256'=>files.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
   'dex_area_page'=>'Current production navigation changes pages by 2 and skips page 2; legacy area assets retained unchanged, not claimed as active scene coverage.'}
  File.write(File.join(directory,'dex-naming-review.json'),KIFMultiplayer::WireJSON.dump(data))
  File.open(logfile,'a') { |file| file.puts("DEX_NAMING_PASS languages=2 renders=#{$texture_dex_labels.length} naming_tab_states=16") }
  passed=true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("DEX_NAMING_FAIL #{error.class}: #{error.message.to_s[0,1500]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
  $texture_dex_back=false
  $texture_naming_label=nil
  exit!(passed ? 0 : 1)
end


