# Run the production bag scene with deterministic test input in an isolated profile.
phase = TEXTURE_MENU_PHASE
directory = File.expand_path('output/texture-hd/p2-evidence/native-menu')
Dir.mkdir(directory) unless File.directory?(directory)
logfile = File.join(directory, "bag-#{phase}-result.txt")
passed = false
begin
  File.write(logfile, "BAG_BEGIN phase=#{phase}\n")
  load 'scripts/multiplayer/test-bootstrap.rb'
  Graphics.resize_screen(512,384)
  $GameSpeed = 1
  srand(12345)
  paths = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-work/menu-native-paths.json'))
  $texture_menu_paths = paths[phase]
  module TextureMenuBitmap
    def initialize(*args)
      if args[0].is_a?(String)
        resolved = GameLanguage.bitmap_path(args[0])
        key = File.expand_path(resolved).tr('\\','/').downcase.sub(/\.(png|jpg|jpeg)\z/, '')
        args[0] = $texture_menu_paths.fetch(key, args[0])
        args[0] = args[0].sub(/\A#{Regexp.escape(Dir.pwd.tr('\\','/'))}\//i, '')
      end
      super(*args)
    end
  end
  Bitmap.prepend(TextureMenuBitmap)
  File.write(File.join(directory,"#{phase}-inputs.json"),KIFMultiplayer::WireJSON.dump($texture_menu_paths.transform_values { |path| Digest::SHA256.hexdigest(File.binread(path)) }))
  rows = KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-audit.json'))['sources'].select { |row| row['batch'][6..-1].to_i.between?(64,76) }
  rows.each do |row|
    bitmap = Bitmap.new(row['source'])
    raise "Size changed #{row['source']}" unless [bitmap.width,bitmap.height] == row['size']
    bitmap.dispose
  end
  module TextureBagInput
    def update
      super
      if $texture_bag_driver
        raise 'Input queue exhausted' if $texture_bag_queue.empty?
        $texture_bag_key = $texture_bag_queue.shift
      end
    end
    def trigger?(key); return key == $texture_bag_key if $texture_bag_driver; super; end
    def repeat?(key); return key == $texture_bag_key if $texture_bag_driver; super; end
    def press?(key); return key == $texture_bag_key if $texture_bag_driver; super; end
  end
  Input.singleton_class.prepend(TextureBagInput)
  module TextureBagObserve
    def pbUpdate
      super
      return unless $texture_bag_driver
      list = @sprites['itemlist']
      left, right = @sprites.values_at('leftarrow','rightarrow')
      bag = @sprites['bagsprite']
      raise 'Bag anchor/scale changed' unless [bag.x,bag.y,bag.ox,bag.oy,bag.zoom_x,bag.zoom_y] == [30,20,0,0,1,1]
      row = {'pocket'=>@bag.lastpocket,'index'=>list.index,'top_item'=>list.top_item,'sorting'=>list.sorting,
             'bag_name'=>bag.name,'description'=>@sprites['itemtext'].text,
             'left'=>[left.frame,left.src_rect.x,left.src_rect.y,left.src_rect.width,left.src_rect.height,left.x,left.y],
             'right'=>[right.frame,right.src_rect.x,right.src_rect.y,right.src_rect.width,right.src_rect.height,right.x,right.y]}
      $texture_bag_trace << row
      previous = $texture_bag_trace[-2]
      changed = !previous || row.values_at('pocket','index','top_item','sorting') != previous.values_at('pocket','index','top_item','sorting')
      if changed || $texture_bag_trace.length <= $texture_bag_cycle_frames
        image = Graphics.snap_to_bitmap
        image.to_file(File.join($texture_bag_directory,format('%s-%03d-%s.png',$texture_bag_case,$texture_bag_trace.length,TEXTURE_MENU_PHASE)))
        image.dispose
      end
    end
  end
  PokemonBag_Scene.prepend(TextureBagObserve)
  $texture_bag_directory = directory
  results = []
  [0,2].each do |language|
    GameLanguage.load(language)
    [:POKEMONTRAINER_Red,:POKEMONTRAINER_Leaf].each_with_index do |trainer_type,gender|
      $Trainer.trainer_type = trainer_type
      raise 'Wrong trainer gender fixture' unless $Trainer.female? == (gender == 1)
      bag = PokemonBag.new
      raise 'Expected eight bag pockets' unless PokemonBag.numPockets == 8
      groups = Hash.new { |h,k| h[k] = [] }
      GameData::Item.each { |item| groups[item.pocket] << item.id if item.pocket.between?(1,8) }
      (1..8).each { |pocket| groups[pocket].first(10).each { |id| raise "Cannot add #{id}" unless bag.pbStoreItem(id,3) } }
      bag.lastpocket = 1
      $PokemonBag = bag
      scene = PokemonBag_Scene.new
      scene.pbStartScene(bag)
      sprites = scene.instance_variable_get(:@sprites)
      arrows = sprites.values_at('leftarrow','rightarrow')
      arrows.each do |arrow|
        raise 'Arrow grid changed' unless [arrow.framecount,arrow.framewidth,arrow.frameheight] == [8,40,28]
        arrow.frame = 0
        arrow.play
      end
      cycle = arrows[0].instance_variable_get(:@frameskip) * 8
      raise 'Arrow periods disagree' unless arrows.map { |a| a.instance_variable_get(:@frameskip) }.uniq.length == 1
      $texture_bag_cycle_frames = cycle + 1
      $texture_bag_queue = Array.new(cycle+2)
      [Input::RIGHT,Input::LEFT].each { |key| 8.times { $texture_bag_queue.concat([key,nil,nil]) } }
      [Input::ACTION,Input::DOWN,Input::BACK].each { |key| $texture_bag_queue.concat([key,nil,nil]) }
      9.times { $texture_bag_queue.concat([Input::DOWN,nil,nil]) }
      9.times { $texture_bag_queue.concat([Input::UP,nil,nil]) }
      $texture_bag_queue.concat([nil,nil,Input::BACK])
      $texture_bag_trace = []
      $texture_bag_case = "bag-#{language}-#{gender}"
      $texture_bag_driver = true
      scene.pbChooseItem
      $texture_bag_driver = false
      trace = $texture_bag_trace
      pockets = trace.map { |row| row['pocket'] }.chunk { |p| p }.map { |p,_| p }
      raise "Pocket transitions wrong #{pockets.inspect}" unless pockets == [1,2,3,4,5,6,7,8,1,8,7,6,5,4,3,2,1]
      raise 'List did not scroll' unless trace.any? { |row| row['top_item'] > 0 }
      raise 'Swap cursor not exercised' unless trace.any? { |row| row['sorting'] }
      %w[left right].each do |side|
        frames = trace.first(cycle+1).map { |row| row[side][0] }
        raise 'Incomplete arrow cycle' unless frames.uniq.sort == (0...8).to_a && frames[0] == frames[-1]
        frames.each_cons(2) { |a,b| raise 'Arrow order changed' unless a == b || (a+1)%8 == b }
      end
      results << {'language'=>language,'gender'=>gender,'arrow_cycle_updates'=>cycle,'frame_rate'=>Graphics.frame_rate,'pocket_order'=>pockets,'trace'=>trace}
      scene.pbEndScene
      File.open(logfile,'a') { |f| f.puts("BAG_CASE_PASS language=#{language} gender=#{gender} updates=#{trace.length} arrow_cycle=#{cycle}") }
    end
  end
  scripts = ['Data/Scripts/016_UI/007_UI_Bag.rb','Data/Scripts/007_Objects and windows/007_SpriteWrapper.rb','Data/Scripts/001_Technical/004_Language.rb']
  File.write(File.join(directory,"bag-#{phase}-traces.json"),KIFMultiplayer::WireJSON.dump({'cases'=>results,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] }}))
  File.open(logfile,'a') { |f| f.puts("BAG_PASS phase=#{phase} images=#{rows.length} cases=#{results.length} pocket_states=32") }
  passed = true
rescue Exception => error
  File.open(logfile,'a') { |file| file.puts("BAG_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
ensure
  $texture_bag_driver = false
  exit!(passed ? 0 : 1)
end

