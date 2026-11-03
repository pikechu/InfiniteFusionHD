# Actual Android command menus and HP/EXP animation with the accepted textures.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  directory = ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  check = KIFMultiplayerFeatureTest.method(:check)
  Graphics.resize_screen(512, 384)
  $GameSpeed = 1
  hashes = {
    "cursor_command" => ["d10703c988e81815b33da8c87acacefc10f4c5b71fe50cec388ed6fffa0d32e8", "68454f5d1f77baf5794974374fae5ed36071e794c067871fee8f54eb1c87db3a"],
    "cursor_command_darkmode" => ["4dbc47ec6313d8a86bd323fc55cd104bdabd6b3212580fa5921ab7b61ae76bd2", "faa6e057af4cebe381552648ad13d1e9bf043bee59944d0cb8c7166ee5ffa03f"],
    "cursor_mega" => ["fdc1fa9908ceaaa6cda9f7068cedaffe710a5abb2e73b0055c25e3378f08b26e", "ce90ce6421347e28f6b940232b61de82df435c0f60a37889ce47da02bc27c3d9"]
  }
  viewport = Viewport.new(0, 0, 512, 384)
  background = IconSprite.new(0, 0, viewport)
  background.setBitmap("Graphics/Battlebacks/battlebg/field")
  command_states = 0
  animations = []
  resolved = []
  [0, 2].each do |language|
    GameLanguage.load(language)
    hashes.each do |name, pair|
      source = "Graphics/Pictures/Battle/#{name}.png"
      actual = GameLanguage.bitmap_path(source)
      check.call(Digest::SHA256.hexdigest(File.binread(actual)) == pair[language == 2 ? 1 : 0], "accepted localized texture #{language}/#{name}")
      image = Bitmap.new(source)
      check.call(image.width > 0 && image.height > 0, "native texture decode #{language}/#{name}")
      resolved << [language, source, actual, image.width, image.height]
      image.dispose
    end
    [[0, 0], [0, 1], [2, 0]].each do |gui, dark|
      $PokemonSystem.battlegui, $PokemonSystem.darkmode = gui, dark
      menu = CommandMenuDisplay.new(viewport, 10)
      menu.setTexts([_INTL("What will {1} do?", "TEST"), "Fight", "Bag", "Pokemon", "Run"])
      menu.visible = true
      5.times do |mode|
        4.times do |index|
          menu.setIndexAndMode(index, mode)
          menu.update
          check.call(menu.instance_variable_get(:@buttons).all? { |button| button.src_rect.width == 130 && button.src_rect.height == 46 }, "command cell #{language}/#{gui}/#{dark}/#{mode}/#{index}")
          Graphics.update
          command_states += 1
        end
      end
      Graphics.screenshot(File.join(directory, "command-#{language}-#{gui}-#{dark}.png"))
      menu.dispose
    end
    [[0, 0], [0, 1], [1, 0], [1, 1], [2, 0], [2, 1]].each do |gui, dark|
      $PokemonSystem.battlegui, $PokemonSystem.darkmode = gui, dark
      $PokemonSystem.typedisplay = 0
      own = Pokemon.new(:BULBASAUR, 50, $Trainer)
      trainer = NPCTrainer.new("UI fixture", $Trainer.trainer_type)
      enemy = Pokemon.new(:PIKACHU, 50, trainer)
      trainer.party = [enemy]
      battle = PokeBattle_Battle.new(Object.new, [own], [enemy], $Trainer, trainer)
      battle.internalBattle = false
      battle.setBattleMode("single")
      battle.pbEnsureParticipants
      battle.pbSetUpSides
      battler = battle.battlers[0]
      box = PokemonDataBox.new(battler, 1, viewport)
      box.visible = true
      old_hp = battler.totalhp
      battler.hp = target_hp = [old_hp / 3, 1].max
      box.animateHP(old_hp, target_hp, old_hp)
      hp = []
      180.times { |frame| box.update(frame); hp << box.instance_variable_get(:@currentHP); break unless box.animatingHP }
      check.call(!box.animatingHP && hp.last == target_hp && hp.each_cons(2).all? { |left, right| right <= left }, "monotonic HP animation #{language}/#{gui}/#{dark}")
      box.animateExp(0, 100, 100)
      exp = []
      180.times { |frame| box.update(frame); exp << box.instance_variable_get(:@currentExp); break unless box.animatingExp }
      check.call(!box.animatingExp && exp.last == 100 && exp.each_cons(2).all? { |left, right| right >= left }, "monotonic EXP animation #{language}/#{gui}/#{dark}")
      Graphics.update
      Graphics.screenshot(File.join(directory, "bars-#{language}.png")) if gui == 0 && dark == 0
      animations << {"language" => language, "gui" => gui, "dark" => dark, "hp" => hp, "exp" => exp}
      box.dispose
    end
  end
  check.call(command_states == 120 && animations.length == 12, "all bilingual command and data-box cases completed")
  File.write(File.join(directory, "texture-release-result.json"), KIFMultiplayer::WireJSON.dump({"command_states" => command_states, "animations" => animations, "resolved_textures" => resolved}))
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("TEXTURE_RELEASE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.first(12).join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  [background, viewport].each { |object| object.dispose if object && !object.disposed? }
  exit!(passed ? 0 : 1)
end
