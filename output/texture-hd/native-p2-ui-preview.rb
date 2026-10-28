# Exercise UI states and bar animation with candidate bitmaps in memory.
phase = TEXTURE_P2_PHASE
directory = File.expand_path('output/texture-hd/p2-evidence/native-ui')
Dir.mkdir(directory) unless File.directory?(directory)
logfile = File.join(directory, "#{phase}-result.txt")
passed = false
begin
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384)
  $GameSpeed = 1
  srand(12345)
  paths = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-work/native-paths.json'))
  $texture_p2_paths = paths[phase]
  module TextureP2Bitmap
    def initialize(*args)
      if args[0].is_a?(String)
        resolved = GameLanguage.bitmap_path(args[0])
        key = File.expand_path(resolved).tr('\\','/').downcase.sub(/\.(png|jpg|jpeg)\z/, '')
        args[0] = $texture_p2_paths.fetch(key, args[0])
      end
      super(*args)
    end
  end
  Bitmap.prepend(TextureP2Bitmap)
  input_hashes = $texture_p2_paths.transform_values { |path| Digest::SHA256.hexdigest(File.binread(path)) }
  File.write(File.join(directory,"#{phase}-inputs.json"), HTTPLite::JSON.stringify(input_hashes))
  sources = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-audit.json'))['sources']
  sources = sources.select { |row| row['batch'][6..-1].to_i.between?(58,63) }
  sources.each do |row|
    bitmap = Bitmap.new(row['source'])
    raise "Image size changed: #{row['source']}" unless [bitmap.width,bitmap.height] == row['size']
    bitmap.dispose
  end
  File.write(logfile,"P2_UI_BEGIN phase=#{phase} images=#{sources.length}\n")
  viewport = Viewport.new(0,0,512,384)
  background = BitmapSprite.new(512,384,viewport)
  background.bitmap.fill_rect(0,0,512,384,Color.new(40,55,70))
  count = 0
  traces = []
  [0,2].each do |language|
    GameLanguage.load(language)
    [[0,0],[0,1],[2,0]].each do |gui,dark|
      $PokemonSystem.battlegui = gui
      $PokemonSystem.darkmode = dark
      menu = CommandMenuDisplay.new(viewport,10)
      menu.setTexts([language == 2 ? '请选择行动。' : 'Choose an action.', 'Fight','Bag','Pokemon','Run'])
      menu.visible = true
      5.times do |mode|
        4.times do |index|
          menu.setIndexAndMode(index,mode)
          menu.update
          menu.instance_variable_get(:@buttons).each do |button|
            raise 'Command state cell changed' unless button.src_rect.width == 130 && button.src_rect.height == 46
          end
          Graphics.update
          image = Graphics.snap_to_bitmap
          image.to_file(File.join(directory,"command-#{language}-#{gui}-#{dark}-#{mode}-#{index}-#{phase}.png"))
          image.dispose
          count += 1
        end
      end
      menu.dispose
    end
    [[0,0],[0,1],[1,0],[1,1],[2,0],[2,1]].each do |gui,dark|
      $PokemonSystem.battlegui = gui
      $PokemonSystem.darkmode = dark
      $PokemonSystem.typedisplay = 0
      own = Pokemon.new(:BULBASAUR,50,$Trainer)
      opponent = NPCTrainer.new('UI fixture',$Trainer.trainer_type)
      enemy = Pokemon.new(:PIKACHU,50,opponent)
      opponent.party = [enemy]
      battle = PokeBattle_Battle.new(Object.new,[own],[enemy],$Trainer,opponent)
      battle.internalBattle = false
      battle.setBattleMode('single')
      battle.pbEnsureParticipants
      battle.pbSetUpSides
      battler = battle.battlers[0]
      box = PokemonDataBox.new(battler,1,viewport)
      box.visible = true
      box.selected = 1
      old_hp = battler.totalhp
      target_hp = [old_hp/3,1].max
      battler.hp = target_hp
      box.animateHP(old_hp,target_hp,old_hp)
      hp = []
      180.times do |frame|
        box.update(frame)
        hp << box.instance_variable_get(:@currentHP)
        break unless box.animatingHP
      end
      raise 'HP animation failed to finish' if box.animatingHP || hp[-1] != target_hp
      raise 'HP animation reversed' unless hp.each_cons(2).all? { |left,right| right <= left }
      box.animateExp(0,100,100)
      exp = []
      180.times do |frame|
        box.update(frame)
        exp << box.instance_variable_get(:@currentExp)
        break unless box.animatingExp
      end
      raise 'EXP animation failed to finish' if box.animatingExp || exp[-1] != 100
      raise 'EXP animation reversed' unless exp.each_cons(2).all? { |left,right| right >= left }
      traces << {'language'=>language,'gui'=>gui,'dark'=>dark,'hp'=>hp,'exp'=>exp}
      Graphics.update
      image = Graphics.snap_to_bitmap
      image.to_file(File.join(directory,"bars-#{language}-#{gui}-#{dark}-#{phase}.png"))
      image.dispose
      box.dispose
    end
  end
  background.dispose
  viewport.dispose
  File.write(File.join(directory,"#{phase}-animation-traces.json"),HTTPLite::JSON.stringify(traces))
  File.open(logfile,'a') { |file| file.puts("P2_UI_PASS phase=#{phase} images=#{sources.length} command_states=#{count} animation_cases=#{traces.length}") }
  passed = true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("P2_UI_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
ensure
  exit!(passed ? 0 : 1)
end
