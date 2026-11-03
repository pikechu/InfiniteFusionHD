phase = TEXTURE_STORAGE_PHASE
directory = File.expand_path('output/texture-hd/p2-evidence/dex')
logfile = File.join(directory,"storage-#{phase}-result.txt")
passed = false
begin
  File.write(logfile,"STORAGE_BEGIN phase=#{phase}\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384)
  $GameSpeed = 1
  srand(12345)
  paths = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-dex-work/native-paths.json'))
  $texture_storage_paths = paths[phase]
  $texture_storage_loaded = []
  module TextureStorageBitmap
    def initialize(*args)
      if args[0].is_a?(String)
        resolved = GameLanguage.bitmap_path(args[0])
        key = File.expand_path(resolved).tr('\\','/').downcase.sub(/\.(png|jpg|jpeg)\z/, '')
        args[0] = $texture_storage_paths.fetch(key,args[0])
        args[0] = args[0].sub(/\A#{Regexp.escape(Dir.pwd.tr('\\','/'))}\//i, '')
        $texture_storage_loaded << [resolved,args[0]]
      end
      super(*args)
    end
  end
  Bitmap.prepend(TextureStorageBitmap)
  inputs = $texture_storage_paths.transform_values { |path| Digest::SHA256.hexdigest(File.binread(path)) }
  File.write(File.join(directory,"storage-#{phase}-inputs.json"),KIFMultiplayer::WireJSON.dump(inputs))
  rows = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-dex-work/scope.json'))['entries']
  rows.each do |row|
    image = Bitmap.new(row['source'])
    raise "Wrong size #{row['source']}" unless [image.width,image.height] == row['size']
    image.dispose
  end
  $texture_storage_traces = []
  module TextureStorageObserve
    def update
      super
      if $texture_storage_label
        box = @sprites['box']
        arrow = @sprites['arrow']
        $texture_storage_traces << {'label'=>$texture_storage_label,'box'=>[box.x,box.y,box.ox,box.oy],
         'box_color'=>[box.color.red,box.color.green,box.color.blue,box.color.alpha],
         'party_y'=>@sprites['boxparty'].y,'arrow'=>[arrow.x,arrow.y,arrow.instance_variable_get(:@frame),arrow.instance_variable_get(:@grabbingState),arrow.instance_variable_get(:@placingState)],
         'mode'=>arrow.cursormode,'holding'=>arrow.holdingSingle?}
      end
    end
  end
  PokemonStorageScene.prepend(TextureStorageObserve)
  labels=[]
  capture=lambda do |label|
    Graphics.update
    bitmap=Graphics.snap_to_bitmap
    bitmap.to_file(File.join(directory,"#{label}-#{phase}.png"));bitmap.dispose
    labels << label
  end
  [0,2].each do |language|
    GameLanguage.load(language)
    Graphics.frame_count = 0
    $Trainer.name='Texture'
    $Trainer.party=[Pokemon.new(:BULBASAUR,25,$Trainer)]
    storage=PokemonStorage.new(3)
    storage.unlockedWallpapers=Array.new(200,true)
    [0,5,29].each_with_index { |slot,index| storage[0,slot]=Pokemon.new([:BULBASAUR,:CHARMANDER,:SQUIRTLE][index],25,$Trainer) }
    storage[1,0]=Pokemon.new(:PIKACHU,25,$Trainer)
    storage[1].background=32
    storage[2].background=33
    scene=PokemonStorageScene.new
    screen=PokemonStorageScreen.new(scene,storage)
    scene.pbStartBox(screen,0)
    (0...200).each do |id|
      storage[0].background=id
      scene.sprites['box'].refreshBox=true
      scene.sprites['box'].refresh
      raise 'Wallpaper cache did not update' unless scene.sprites['box'].instance_variable_get(:@bg)==id
      scene.pbUpdateOverlay(0)
      scene.update
      box=scene.sprites['box']
      raise 'Storage box anchor moved' unless [box.x,box.y,box.ox,box.oy]==[184,18,0,0]
      capture.call("storage-#{language}-wallpaper-#{id}")
    end
    storage[0].background=32
    scene.sprites['box'].refreshBox=true
    scene.sprites['box'].refresh
    arrow=scene.sprites['arrow']
    arrow.instance_variable_set(:@frame,0)
    $texture_storage_label="cursor-#{language}"
    (Graphics.frame_rate+1).times do |frame|
      scene.update
      capture.call("storage-#{language}-cursor-#{frame}")
    end
    $texture_storage_label="box-right-#{language}"
    scene.pbJumpToBox(1)
    raise 'Wrong final right box anchor' unless scene.sprites['box'].x==184
    $texture_storage_label="box-left-#{language}"
    scene.pbJumpToBox(0)
    raise 'Wrong final left box anchor' unless scene.sprites['box'].x==184
    $texture_storage_label="party-open-#{language}"
    scene.pbShowPartyTab
    capture.call("storage-#{language}-party-open")
    $texture_storage_label="party-close-#{language}"
    scene.pbHidePartyTab
    %w[default quickswap multiselect].each do |mode|
      scene.pbSetCursorMode(mode)
      $texture_storage_label="hold-#{language}-#{mode}"
      scene.pbHold([0,0])
      capture.call("storage-#{language}-#{mode}-hold")
      $texture_storage_label="place-#{language}-#{mode}"
      scene.pbPlace([0,0],nil)
      capture.call("storage-#{language}-#{mode}-placed")
    end
    $texture_storage_label="background-fade-#{language}"
    scene.pbChangeBackground(33)
    capture.call("storage-#{language}-background-switched")
    $texture_storage_label=nil
    scene.pbCloseBox
    File.open(logfile,'a') { |file| file.puts("STORAGE_LANGUAGE_PASS language=#{language} wallpapers=200") }
  end
  files=['Data/Scripts/016_UI/017_UI_PokemonStorage.rb','Data/Scripts/014_Pokemon/001_Pokemon-related/004_PokemonStorage.rb','Data/Scripts/001_Technical/004_Language.rb']
  data={'renders'=>labels,'traces'=>$texture_storage_traces,'loaded_paths'=>$texture_storage_loaded.uniq,
   'script_sha256'=>files.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },'frame_rate'=>Graphics.frame_rate}
  File.write(File.join(directory,"storage-#{phase}-review.json"),KIFMultiplayer::WireJSON.dump(data))
  File.open(logfile,'a') { |file| file.puts("STORAGE_PASS phase=#{phase} images=#{rows.length} renders=#{labels.length}") }
  passed = true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("STORAGE_FAIL #{error.class}: #{error.message.to_s[0,1500]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
  $texture_storage_label=nil
  exit!(passed ? 0 : 1)
end

