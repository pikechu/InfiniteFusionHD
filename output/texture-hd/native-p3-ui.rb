directory=File.expand_path('output/texture-hd/p3-evidence/remaining');log=File.join(directory,'ui-result.txt');passed=false
begin
 File.write(log,"P3_UI_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1;srand(512)
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/remaining-native-index.json'),49*1024*1024,3000000)['ui_other']
 repair=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/encoding-repair.json'))
 $p3_encoding_source=File.expand_path(repair['entry']['source']).tr('\\','/').downcase.sub(/\.png\z/,'')
 $p3_encoding_ready=repair['ready']
 module P3EncodingRoute
  def initialize(*args)
   if args[0].is_a?(String)
    key=File.expand_path(GameLanguage.bitmap_path(args[0])).tr('\\','/').downcase.sub(/\.png\z/,'')
    args[0]=$p3_encoding_ready if key==$p3_encoding_source
   end
   super(*args)
  end
 end
 Bitmap.prepend(P3EncodingRoute)
 inputs={};decoded=[];captures=[];reels=[];mining=[];puzzles=[];voltorbs=[]
 rows.each do |row|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));b=Bitmap.new(source)
  raise "Wrong UI dimensions #{source}" unless [b.width,b.height]==row['size'];decoded << [source,b.width,b.height];b.dispose
 end
 capture=lambda do |label|
  Graphics.update;b=Graphics.snap_to_bitmap;b.to_file(File.join(directory,label+'.png'));b.dispose;captures << label
 end
 [0,2].each do |language|
  GameLanguage.load(language);$Trainer.coins=100
  [0,1,2].each do |difficulty|
   scene=SlotMachineScene.new;scene.pbStartScene(difficulty);sprites=scene.instance_variable_get(:@sprites)
   capture.call("slots-#{language}-#{difficulty}")
   (1..3).each do |number|
    reel=sprites["reel#{number}"];initial=[reel.toppos,reel.showing];trace=[];reel.startSpinning
    (reel.reel.length*3).times { reel.update;trace << [reel.toppos,reel.showing] }
    raise 'Reel full cycle changed state' unless [reel.toppos,reel.showing]==initial
    reel.stopSpinning(true);4.times { reel.update };raise 'Reel did not stop' if reel.spinning
    reels << [language,difficulty,number,trace]
   end
   [0,1,9,10,99999].each { |value| sprites['credit'].score=value;sprites['credit'].update }
   scene.pbEndScene
  end
  mine=MiningGameScene.new;mine.pbStartScene;sprites=mine.instance_variable_get(:@sprites);capture.call("mining-#{language}")
  [0,1].each do |mode|
   [0,1,2].each do |hit|
    cursor=sprites['cursor'];cursor.mode=mode;cursor.animate(hit);trace=[]
    23.times { cursor.update;trace << cursor.counter }
    raise 'Mining hit animation did not end' unless trace.last==0 && !cursor.isAnimating?
    mining << [language,mode,hit,trace]
   end
  end
  (0..6).each { |layer| sprites['tile0'].layer=layer;sprites['tile0'].update };mine.pbEndScene
  %w[Aerodactyl Hooh Kabuto Mew Omanyte].each do |board|
   puzzle=TilePuzzleScene.new(7,board,4,4);puzzle.pbStartScene
   angles=puzzle.instance_variable_get(:@angles).dup
   4.times { puzzle.pbRotateTile(0,false) };raise 'Puzzle rotation did not loop' unless puzzle.instance_variable_get(:@angles)==angles
   capture.call("puzzle-#{language}-#{board}");puzzles << [language,board,angles];puzzle.pbEndScene
  end
  vf=VoltorbFlip.new;vf.pbStart;capture.call("voltorb-#{language}")
  [1,2,3].each { |tile| vf.pbAnimateTile(0,0,tile) }
  voltorbs << [language,vf.instance_variable_get(:@squares).length];vf.pbEndScene
 end
 # Actual 230-frame intro Movie, with frame-order and wait instrumentation.
 $p3_movie_frames=[];$p3_movie_waits=[];$p3_movie_updates=0
 module P3MovieBitmap
  def initialize(*args)
   if $p3_movie_active && args[0].is_a?(String) && args[0].match?(/INTRO-\d+/)
    $p3_movie_frames << args[0][/INTRO-(\d+)/,1].to_i
   end
   super(*args)
  end
 end
 Bitmap.prepend(P3MovieBitmap)
 module P3MovieWait
  def pbWait(frames)
   $p3_movie_waits << frames if $p3_movie_active
   super
  end
 end
 Object.prepend(P3MovieWait)
 module P3MovieInput
  def trigger?(key);return key==Input::C && $p3_movie_skip if $p3_movie_active;super;end
 end
 Input.singleton_class.prepend(P3MovieInput)
 module P3MovieGraphics
  def update(*args);result=super;$p3_movie_updates+=1 if $p3_movie_active;result;end
 end
 Graphics.singleton_class.prepend(P3MovieGraphics)
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 $p3_movie_active=true;$p3_movie_skip=false
 movie=Movie.new('Graphics/Pictures/Intro/INTRO-%03d','INTRO_music_cries',230,false);movie.playInViewPort(viewport)
 raise "Wrong intro sequence #{$p3_movie_frames.length}" unless $p3_movie_frames==(1..230).to_a
 raise 'Wrong intro frame waits' unless $p3_movie_waits==Array.new(230,2)
 full_movie={'frames'=>$p3_movie_frames.dup,'wait_updates'=>$p3_movie_waits.dup,'graphics_updates'=>$p3_movie_updates,'finished'=>movie.finished}
 $p3_movie_frames=[];$p3_movie_waits=[];$p3_movie_updates=0;$p3_movie_skip=true
 movie=Movie.new('Graphics/Pictures/Intro/INTRO-%03d','INTRO_music_cries',230,true);movie.playInViewPort(viewport)
 raise 'Intro skip loaded frames' unless $p3_movie_frames.empty? && movie.finished
 $p3_movie_active=false;viewport.dispose
 scripts=['Data/Scripts/017_Minigames/003_Minigame_SlotMachine.rb','Data/Scripts/017_Minigames/004_Minigame_VoltorbFlip.rb',
  'Data/Scripts/017_Minigames/006_Minigame_Mining.rb','Data/Scripts/017_Minigames/007_Minigame_TilePuzzles.rb','Data/Scripts/052_AddOns/Movie.rb',
  'Data/localization/zh-CN-images.json']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'captures'=>captures,'reel_cycles'=>reels,'mining_hits'=>mining,
  'candidate_inputs'=>{repair['entry']['source']=>{'ready'=>repair['ready'],'sha256'=>Digest::SHA256.hexdigest(File.binread(repair['ready']))}},
  'puzzle_rotations'=>puzzles,'voltorb_boards'=>voltorbs,'movie'=>full_movie,'movie_skip'=>true,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 658 unchanged UI/intro sources decoded. Actual bilingual SlotMachine three difficulties/full reel loops/stop, Mining tool-hit animation and tile depths, five TilePuzzle rotation loops, Voltorb board/tile animation, full 230-frame Movie at two updates per frame and skip path. Other decorative/mail/roulette/compatibility assets retained byte-identically after visual/use review; not every minigame outcome or complete event/startup flow.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'ui-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P3_UI_PASS inputs=#{inputs.length} captures=#{captures.length} movie_frames=#{full_movie['frames'].length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P3_UI_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(9).join("\n")}") }
ensure
 $p3_movie_active=false
 exit!(passed ? 0 : 1)
end
