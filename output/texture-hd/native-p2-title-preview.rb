# Actual layered title consumers; isolated deterministic inputs, bounded evidence.
directory=File.expand_path('output/texture-hd/p2-evidence/titles')
logfile=File.join(directory,"#{TITLE_PHASE}-result.txt");passed=false
begin
  File.write(logfile,"TITLE_BEGIN phase=#{TITLE_PHASE}\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
  KIFMultiplayer::OnlineMode.instance_variable_set(:@mode,:offline)
  KIFMultiplayer::OnlineMode.instance_variable_set(:@selection_needed,false)
  $title_routes=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-title-work/native-paths.json'))[TITLE_PHASE]
  $title_loads=[];$title_traces=[];$title_captures=[];$title_waits=[];$title_fusions=[];$title_resets=[]
  module TitleBitmapRoute
    def initialize(*args)
      if args[0].is_a?(String)
        resolved=GameLanguage.bitmap_path(args[0])
        key=File.expand_path(resolved).tr('\\','/').downcase.sub(/\.(png|jpg|jpeg)\z/,'')
        args[0]=$title_routes.fetch(key,args[0]);args[0]=args[0].sub(/\A#{Regexp.escape(Dir.pwd.tr('\\','/'))}\//i,'')
        $title_loads << [resolved,args[0]]
      end
      super(*args)
    end
  end
  Bitmap.prepend(TitleBitmapRoute)
  # Fixed offline pair controls random sprite selection, not animation code.
  module TitleOfflinePair
    def getRandomCustomFusionForIntro(*args);[1,4];end
    def downloadAllowed?;false;end
    def find_newer_available_version;nil;end
  end
  Object.prepend(TitleOfflinePair)
  module TitleOfflineLoad
    def checkEnableSpritesDownload;end
    def copyKeybindings;end
  end
  PokemonLoadScreen.prepend(TitleOfflineLoad)
  module TitleOfflineStartup
    def startup(*args);end
  end
  KIF::OfflineResources.singleton_class.prepend(TitleOfflineStartup)
  module TitleInput
    def press?(key);return key==$title_key if $title_driver;super;end
    def trigger?(key)
      return key==Input::C && $title_confirm if $title_driver
      return key==Input::USE && $title_credit_tick>=160 if $title_credit_driver
      super
    end
  end
  Input.singleton_class.prepend(TitleInput)
  $title_capture=lambda do |label,extra={}|
    bitmap=Graphics.snap_to_bitmap;bitmap.to_file(File.join(directory,"#{label}-#{TITLE_PHASE}.png"));bitmap.dispose
    $title_captures << {'label'=>label,'case'=>$title_case,**extra}
  end
  $title_snapshot=lambda do
    sprites=$title_style.instance_variable_get(:@sprites)
    layers=sprites.to_h do |key,s|
      drawable=s.is_a?(LargePlane) ? s.instance_variable_get(:@__sprite) : s
      rect=drawable.src_rect
      [key,{'xy'=>[drawable.x,drawable.y],'origin'=>[s.ox,s.oy],'z'=>s.z,'opacity'=>s.opacity,'visible'=>s.visible,
       'rect'=>[rect.x,rect.y,rect.width,rect.height],'zoom'=>[s.zoom_x,s.zoom_y],
       'tone'=>[s.tone.red,s.tone.green,s.tone.blue,s.tone.gray]}]
    end
    {'case'=>$title_case,'tick'=>$title_tick,'outer'=>$title_outer,'phase'=>$title_mode,
     'frame'=>$title_style.instance_variable_get(:@currentFrame),'layers'=>layers}
  end
  module TitleGraphicsObserve
    def update(*args)
      super
      if $title_driver && $title_style
        $title_tick+=1
        row=$title_snapshot.call;$title_traces << row
        if $title_tick<=2 || $title_tick%40==0
          $title_capture.call("#{$title_case}-#{$title_tick}",{'trace_index'=>$title_traces.length-1})
        end
      end
    end
  end
  Graphics.singleton_class.prepend(TitleGraphicsObserve)
  module TitleWaitObserve
    def wait(frames)
      $title_waits << {'case'=>$title_case,'outer'=>$title_outer,'requested'=>frames,'skipped'=>!!@skip,'start'=>$title_tick}
      super
    end
    def getFusedIdIntro(a,b)
      value=super
      $title_fusions << {'case'=>$title_case,'outer'=>$title_outer,'key'=>$title_key,'a'=>a,'b'=>b,'id'=>value}
      value
    end
  end
  GenOneStyle.prepend(TitleWaitObserve)
  module TitleLoadObserve
    def pbChoose(commands,*args)
      if $title_reach_load
        pbUpdate;Graphics.update
        $title_capture.call("load-#{$title_language}",{'kind'=>'load','commands'=>commands})
        pbEndScene
        throw :title_load_drawn
      end
      super
    end
  end
  PokemonLoad_Scene.prepend(TitleLoadObserve)
  module TitleCreditsObserve
    def update
      $title_credit_tick+=1
      super
      row={'case'=>$title_case,'tick'=>$title_credit_tick,'background'=>@bg_index,'oy'=>@realOY,
           'text_oy'=>@credit_sprites.map { |s| s.oy }}
      $title_credit_traces << row
      $title_capture.call("#{$title_case}-#{$title_credit_tick}",{'kind'=>'credits'}) if [1,40,80,120,159].include?($title_credit_tick)
    end
  end
  Scene_Credits.prepend(TitleCreditsObserve)
  # Fixed delta makes the native credits text trace comparable across runs.
  module TitleCreditsDelta
    def delta_s;return 1.0/40 if $title_credit_driver;super;end
  end
  Graphics.singleton_class.prepend(TitleCreditsDelta)
  rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-title-work/scope.json'))['entries']
  rows.each do |row|
    b=Bitmap.new(row['source']);raise "Bad size #{row['source']}" unless [b.width,b.height]==row['size'];b.dispose
  end
  $title_credit_traces=[]
  [0,2].each do |language|
    GameLanguage.load(language);$title_language=language;srand(103)
    $title_case="gen1-#{language}";$title_tick=0;$title_outer=0;$title_mode='intro';$title_key=nil;$title_confirm=false
    $title_style=GenOneStyle.new;$title_driver=true;$title_style.intro
    $title_mode='loop'
    600.times do |i|
      $title_outer=i+1;$title_key=i<300 ? Input::LEFT : Input::RIGHT
      $title_style.update;Graphics.update;Input.update
    end
    # Exercise the real title-confirm and load-screen construction path.
    intro=Scene_Intro.new;intro.instance_variable_set(:@screen,$title_style)
    $title_mode='confirm';$title_confirm=true;$title_reach_load=true
    catch(:title_load_drawn) { intro.update;raise 'Title confirm did not reach the load menu' }
    $title_reach_load=false;$title_driver=false;$title_style=nil;$title_confirm=false;Kernel.pbClearText
    $title_case="gen3-#{language}";$title_tick=0;$title_outer=0;$title_mode='intro';$title_key=nil
    $title_style=GenThreeStyle.new;$title_driver=true;$title_style.intro
    $title_mode='production-reset'
    begin
      remaining=$title_style.instance_variable_get(:@totalFrames)-$title_style.instance_variable_get(:@currentFrame)
      (remaining+1).times { |i| $title_outer=i+1;$title_style.update;Graphics.update }
      raise 'Expected original GenThree reset threshold was not reached'
    rescue Reset
      $title_resets << {'case'=>$title_case,'frame'=>$title_style.instance_variable_get(:@currentFrame),'outer'=>$title_outer}
    end
    # Legacy style resets after its long intro. Extend only this isolated fixture
    # to inspect its unchanged complete star-plane/blink/opacity combination.
    $title_style.instance_variable_set(:@totalFrames,100000)
    $title_mode='extended-legacy-loop'
    769.times { |i| $title_outer=i+1;$title_style.update;Graphics.update;Input.update }
    $title_driver=false;$title_style.dispose;$title_style=nil
    $title_case="credits-#{language}";$title_credit_tick=0;$title_credit_driver=true
    $PokemonGlobal.creditsPlayed=true;$scene=Scene_Credits.new;$scene.main
    $title_credit_driver=false
    File.open(logfile,'a') { |f| f.puts("TITLE_LANGUAGE_PASS #{language}") }
  end
  files=['Data/Scripts/052_AddOns/IntroScreen.rb','Data/Scripts/052_AddOns/DisplayText.rb',
         'Data/Scripts/016_UI/013_UI_Load.rb','Data/Scripts/016_UI/001_Non-interactive UI/007_UI_Credits.rb',
         'Data/Scripts/007_Objects and windows/009_Planes.rb','Data/localization/zh-CN-images.json',
         'Data/Scripts/054_Multiplayer/019_OnlineMode.rb','Data/Scripts/052_AddOns/MultiSaves.rb']
  data={'phase'=>TITLE_PHASE,'frame_rate'=>Graphics.frame_rate,'decoded_images'=>rows.length,'traces'=>$title_traces,
        'captures'=>$title_captures,'waits'=>$title_waits,'fusions'=>$title_fusions,'legacy_resets'=>$title_resets,
        'credits_traces'=>$title_credit_traces,'loaded_paths'=>$title_loads.uniq,
        'script_sha256'=>files.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
        'fixture'=>'Fixed offline 1/4 pair and credits delta; skip network version checks, resource-pack startup, download prompts and keybinding writes in this isolated fixture. Actual title animations and load-scene construction run. Gen3 reset is observed before extending its fixture-only threshold. No game script changes.'}
  # This local full-frame diagnostic exceeds the network message size limit.
  encoded=KIFMultiplayer::WireJSON.encode(data,0)
  raise 'Diagnostic exceeded 49 MiB cap' if encoded.bytesize>49*1024*1024
  File.write(File.join(directory,"#{TITLE_PHASE}-review.json"),encoded)
  File.open(logfile,'a') { |f| f.puts("TITLE_PASS captures=#{$title_captures.length} frames=#{$title_traces.length}") }
  passed=true
rescue Exception => error
  File.open(logfile,'a') { |f| f.puts("TITLE_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(10).join("\n")}") }
ensure
  $title_driver=false;$title_credit_driver=false
  exit!(passed ? 0 : 1)
end
