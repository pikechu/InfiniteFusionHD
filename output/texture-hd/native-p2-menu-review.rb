# Review unchanged party, summary and ready-menu resources in production scenes.
directory = File.expand_path('output/texture-hd/p2-evidence/native-menu')
logfile = File.join(directory,'menus-result.txt')
passed = false
begin
  File.write(logfile,"MENUS_BEGIN\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384)
  $GameSpeed = 1
  srand(12345)
  $texture_review_loaded = []
  module TextureReviewBitmap
    def initialize(*args)
      $texture_review_loaded << GameLanguage.bitmap_path(args[0]) if args[0].is_a?(String)
      super(*args)
    end
  end
  Bitmap.prepend(TextureReviewBitmap)
  renders = []
  capture = lambda do |label|
    Graphics.update
    bitmap = Graphics.snap_to_bitmap
    bitmap.to_file(File.join(directory,"#{label}.png"))
    bitmap.dispose
    renders << label
  end
  rows = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-audit.json'))['sources'].select { |r| r['batch'][6..-1].to_i.between?(64,76) }
  input_hashes = rows.to_h { |row| [row['source'],Digest::SHA256.hexdigest(File.binread(row['source']))] }
  [0,2].each do |language|
    GameLanguage.load(language)
    $Trainer.trainer_type = :POKEMONTRAINER_Red
    party = [:BULBASAUR,:CHARMANDER,:SQUIRTLE].map { |id| Pokemon.new(id,25,$Trainer) }
    party[0].learn_move(:TACKLE)
    party[0].learn_move(:GROWL)
    party[0].item = :POTION
    party[1].hp = 0
    party[2].hp = [party[2].totalhp/5,1].max
    $Trainer.party = party
    scene = PokemonParty_Scene.new
    scene.pbStartScene(party,_INTL('Choose a Pokémon.'))
    (0..Settings::MAX_PARTY_SIZE).each { |index| scene.pbSelect(index); scene.update; capture.call("party-#{language}-select-#{index}") }
    sprites = scene.instance_variable_get(:@sprites)
    [0,1].each do |index|
      panel = sprites["pokemon#{index}"]
      pokemon = party[index]
      [false,true].each do |fainted|
        [false,true].each do |selected|
          pokemon.hp = fainted ? 0 : pokemon.totalhp
          panel.preselected = false
          panel.switching = false
          panel.selected = selected
          panel.refresh
          scene.update
          capture.call("party-#{language}-#{index}-faint-#{fainted}-select-#{selected}")
        end
      end
      pokemon.heal
      [[true,false,false],[true,true,false],[false,true,true]].each_with_index do |(pre,selected,switching),state|
        panel.preselected = pre
        panel.switching = switching
        panel.selected = selected
        panel.refresh
        scene.update
        capture.call("party-#{language}-#{index}-swap-#{state}")
      end
    end
    scene.pbEndScene
    scene = PokemonParty_Scene.new
    scene.pbStartScene(party,_INTL('Choose a Pokémon.'),nil,true)
    [0,Settings::MAX_PARTY_SIZE,Settings::MAX_PARTY_SIZE+1].each { |index| scene.pbSelect(index); scene.update; capture.call("party-#{language}-multi-#{index}") }
    scene.pbEndScene
    summary = PokemonSummary_Scene.new
    summary.pbStartScene(party,0)
    [1,2,3,4,3,2,1].each_with_index { |page,index| summary.drawPage(page); summary.pbUpdate; capture.call("summary-#{language}-#{index}-page-#{page}") }
    sprites = summary.instance_variable_get(:@sprites)
    [nil,Pokemon::Move.new(:CUT)].each_with_index do |move,state|
      summary.drawPageFourSelecting(move)
      sprites['movesel'].visible = true
      4.times do |index|
        sprites['movesel'].index = index
        sprites['movesel'].preselected = false
        summary.pbUpdate
        capture.call("summary-#{language}-move-#{state}-#{index}")
      end
    end
    sprites['movesel'].visible = false
    sprites['markingbg'].visible = true
    sprites['markingsel'].visible = true
    [0,1].each do |state|
      sprites['markingsel'].src_rect.set(0,state*sprites['markingsel'].bitmap.height/2,56,sprites['markingsel'].bitmap.height/2)
      summary.pbUpdate
      capture.call("summary-#{language}-marking-#{state}")
    end
    summary.pbEndScene
    egg = Pokemon.new(:BULBASAUR,1,$Trainer)
    egg.steps_to_hatch = 500
    summary = PokemonSummary_Scene.new
    summary.pbStartScene([egg],0)
    summary.pbUpdate
    capture.call("summary-#{language}-egg")
    summary.pbEndScene
    viewport = Viewport.new(0,0,512,384)
    [[false,:POTION],[true,:CUT]].each do |move,id|
      button = ReadyMenuButton.new(0,[id,move ? GameData::Move.get(id).name : GameData::Item.get(id).name,move,0],0,move ? 0 : 1,viewport)
      [0,1,0].each_with_index do |index,state|
        button.selected = index
        button.update
        capture.call("ready-#{language}-#{move}-#{state}")
      end
      button.dispose
    end
    viewport.dispose
    File.open(logfile,'a') { |f| f.puts("MENUS_LANGUAGE_PASS language=#{language}") }
  end
  scripts = ['Data/Scripts/016_UI/005_UI_Party.rb','Data/Scripts/016_UI/006_UI_Summary.rb','Data/Scripts/016_UI/016_UI_ReadyMenu.rb']
  File.write(File.join(directory,'menus-review.json'),KIFMultiplayer::WireJSON.dump({'renders'=>renders,'input_sha256'=>input_hashes,'loaded_paths'=>$texture_review_loaded.uniq.sort,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] }}))
  File.open(logfile,'a') { |f| f.puts("MENUS_PASS languages=2 renders=#{renders.length} menu_inputs=#{input_hashes.length}") }
  passed = true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("MENUS_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
ensure
  exit!(passed ? 0 : 1)
end
