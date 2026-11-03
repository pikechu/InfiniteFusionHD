directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'animated-result.txt');passed=false
begin
 File.write(log,"P4_ANIMATED_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['stage']=='animated' || r['source']=='Graphics/Pokemon/Eggs/000_cracks.png' }
 inputs={};decoded=[];gifs=[];pngs=[];hatches=[]
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Dimensions #{source}" unless [bitmap.width,bitmap.height]==row['size']
  decoded << [source,bitmap.width,bitmap.height,bitmap.animated?,bitmap.frame_count]
  if row['encoded_frames']>1
   raise 'GIF frame count' unless bitmap.animated? && bitmap.frame_count==row['encoded_frames']
   frames=[]
   bitmap.frame_count.times do |frame|
    bitmap.goto_and_stop(frame);raise 'GIF seek order' unless bitmap.current_frame==frame
    name="#{index}-#{frame}.png";bitmap.to_file(File.join('temp/texture-p4-gif-check/frames',name));frames << name
   end
   gifs << {'source'=>source,'bitmap'=>bitmap,'index'=>index,'native_frames'=>bitmap.frame_count,'native_frame_rate'=>bitmap.frame_rate,
    'native_frames_exported'=>frames,'trace'=>[],'wraps'=>0,'last'=>nil}
  else
   owner=AnimatedBitmap.new(source)
   pngs << {'source'=>source,'size'=>row['size'],'generic_loader_frames'=>owner.length,
    'binding'=>source.end_with?('000_cracks.png') ? 'Five-cell hatch mask' : 'Unbound donor strip'}
   owner.dispose;bitmap.dispose
  end
 end
 # Native GIF playback runs concurrently so every full cycle is observed at the real frame rate.
 clock=lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
 start=clock.call
 gifs.each { |g| g['bitmap'].looping=true;g['bitmap'].goto_and_play(0) }
 loop do
  Graphics.update
  gifs.each do |g|
   next if g['wraps']>=2
   frame=g['bitmap'].current_frame
   if frame!=g['last']
    g['wraps']+=1 if g['last'] && frame<g['last']
    g['trace'] << [frame,((clock.call-start)*1000).round];g['last']=frame
    g['bitmap'].goto_and_stop(0) if g['wraps']>=2
   end
  end
  break if gifs.all? { |g| g['wraps']>=2 }
  raise 'GIF playback timeout' if clock.call-start>45
 end
 gifs.each do |g|
  frames=g['trace'].map(&:first);expected=(0...g['native_frames']).to_a*2+[0]
  raise "Native GIF skipped/reordered cells #{g['source']}: #{frames}" unless frames==expected
  g.delete('bitmap').dispose;g.delete('last');g.delete('index')
 end
 module P4HatchClock
  def updateScene(frames=1)
   frames.times do
    raise 'Hatch anchor split' unless @sprites['pokemon'].x==@sprites['hatch'].x
    @p4_trace << [@sprites['pokemon'].x,@sprites['hatch'].src_rect.x]
    pbUpdateSpriteHash(@sprites)
   end
  end
 end
 rows.select { |r| r['source'].end_with?('000_cracks.png') }.each do |row|
  scene=PokemonEggHatch_Scene.allocate;scene.extend(P4HatchClock)
  egg=SpriteWrapper.new;egg.x=256;egg.y=200
  crack=SpriteWrapper.new;crack.x=256;crack.y=200;crack.bitmap=Bitmap.new(row['source']);crack.src_rect.set(0,0,crack.bitmap.width/5,crack.bitmap.height)
  scene.instance_variable_set(:@sprites,{'pokemon'=>egg,'hatch'=>crack});trace=[];scene.instance_variable_set(:@p4_trace,trace)
  positions=[]
  [[4,1],[4,1],[8,2],[16,4]].each_with_index do |(speed,swings),frame|
   scene.pbPositionHatchMask(frame);positions << crack.src_rect.x;scene.swingEgg(speed,swings)
   raise 'Hatch did not return to anchor' unless egg.x==256 && crack.x==256
  end
  scene.pbPositionHatchMask(4);positions << crack.src_rect.x
  raise 'Hatch mask order' unless positions==(0...5).map { |i| i*160 }
  hatches << {'source'=>row['source'],'mask_positions'=>positions,'swing_updates'=>trace.length,'swing_trace'=>trace}
  crack.bitmap.dispose;egg.dispose;crack.dispose
 end
 scripts=['Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb','Data/Scripts/007_Objects and windows/001_RPG_Cache.rb',
  'Data/Scripts/016_UI/001_Non-interactive UI/003_UI_EggHatching.rb']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'gifs'=>gifs,'png_loaders'=>pngs,'hatch_masks'=>hatches,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All P4 animated sources directly decoded at original dimensions. Eight native GIFs seek every frame and play two complete real-time cycles, preserving order and observed timing; exported native frames require external pixel verification before checkpointing. Both five-cell hatch-mask copies use actual mask positioning/swing methods with deterministic scene updates. Unbracketed long PNG donor strips remain one frame in the current generic loader; no active directory consumer found. Their cells/pixels are preserved, not falsely certified as current animated battlers or assigned an invented playback duration. No full hatch dialogue/gameplay.'}
 File.write(File.join(directory,'animated-review.json'),KIFMultiplayer::WireJSON.encode(doc,0));File.open(log,'a'){ |f| f.puts("P4_ANIMATED_PASS inputs=#{inputs.length} gifs=#{gifs.length} hatch=#{hatches.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_ANIMATED_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
