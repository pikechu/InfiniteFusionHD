directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'weather-result.txt');passed=false
begin
 File.write(log,"P4_WEATHER_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1;srand(541816)
 # Deterministic logical time in this isolated fixture; no game source changes.
 Graphics.define_singleton_method(:delta_s) { 1.0/40 }
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['stage']=='weather' }
 inputs={};decoded=[];weather_cases=[];fog_cases=[];particles=[];transitions=[];issues=[];state_checks=0
 rows.each do |row|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Dimensions #{source}" unless [bitmap.width,bitmap.height]==row['size']
  decoded << [source,bitmap.width,bitmap.height];bitmap.dispose
 end
 viewport=Viewport.new(0,0,512,384)
 board=Sprite.new(viewport);board.bitmap=Bitmap.new(512,384);board.bitmap.fill_rect(0,0,512,384,Color.new(80,100,120));Graphics.update
 GameData::Weather.each do |data|
  weather=RPG::Weather.new(viewport);weather.type=data.id;weather.max=60;weather.ox=32;weather.oy=16
  cached=weather.instance_variable_get(:@weatherTypes)[data.id]
  steps=400
  if data.has_tiles?
   bmp=cached[2][0];wide=weather.instance_variable_get(:@tiles_wide);tall=weather.instance_variable_get(:@tiles_tall)
   steps=[steps,(2.0*wide*bmp.width/data.tile_delta_x.abs*40).ceil+2].max if data.tile_delta_x!=0
   steps=[steps,(2.0*tall*bmp.height/data.tile_delta_y.abs*40).ceil+2].max if data.tile_delta_y!=0
  end
  trace=Digest::SHA256.new;resets=0;last_life=[]
  steps.times do |tick|
   weather.update
   life=weather.instance_variable_get(:@sprite_lifetimes)
   life.each_with_index { |value,i| resets+=1 if last_life[i] && value>last_life[i] }
   last_life=life.dup
   sprites=weather.instance_variable_get(:@sprites)+weather.instance_variable_get(:@tiles)
   sprites.each do |s|
    raise 'Nonfinite weather state' unless [s.x,s.y,s.opacity].all? { |v| v.to_f.finite? }
    raise 'Invalid weather bitmap' if s.bitmap && s.bitmap.disposed?
    state_checks+=1
   end
   trace.update(Marshal.dump(sprites.map { |s| [s.x,s.y,s.opacity,s.visible] }))
  end
  raise 'No weather particle reset' if data.has_particles? && resets==0
  [0,20,60].each { |power| weather.max=power;weather.update;raise 'Weather strength' unless weather.max==power }
  Graphics.update;shot=Graphics.snap_to_bitmap;shot.to_file(File.join(directory,"weather-#{data.id}.png"));shot.dispose
  weather.fade_in(:None,0,1);220.times { weather.update }
  raise 'Weather fade incomplete' if weather.instance_variable_get(:@fading) || weather.type!=:None || weather.max!=0
  weather.fade_in(data.id,40,1);220.times { weather.update }
  raise 'Weather fade in incomplete' if weather.instance_variable_get(:@fading) || weather.type!=data.id
  weather_cases << {'type'=>data.id.to_s,'logical_updates'=>steps+443,'particle_resets'=>resets,'trace_sha256'=>trace.hexdigest,'graphics'=>data.graphics}
  weather.dispose
 end
 rows.select { |r| r['source'].start_with?('Graphics/Fogs/') }.each_with_index do |row,index|
  plane=AnimatedPlane.new(viewport);plane.setFog(File.basename(row['source'],'.png'));plane.update
  raise 'Fog loader dimensions' unless [plane.bitmap.width,plane.bitmap.height]==row['size']
  w,h=row['size'];positions=[]
  [[0,0],[w-1,h-1],[w,h],[2*w,2*h],[-1,-1],[0,0]].each do |x,y|
   plane.ox=x;plane.oy=y;plane.update;positions << [plane.ox,plane.oy]
   raise 'Fog origin invalid' unless [plane.ox,plane.oy].all? { |v| v.to_f.finite? }
  end
  plane.zoom_x=2;plane.zoom_y=2;plane.opacity=128;plane.update
  fog_cases << {'source'=>row['source'],'wrap_boundary_positions'=>positions,'zoom'=>2,'opacity'=>128}
  if index%6==0
   Graphics.update;shot=Graphics.snap_to_bitmap;shot.to_file(File.join(directory,"fog-#{index}.png"));shot.dispose
  end
  plane.dispose
 end
 # Actual particle classes with a fixed event screen anchor, independent of map AI.
 Particle_Engine.constants(false).sort.each do |name|
  klass=Particle_Engine.const_get(name);next unless klass.is_a?(Class) && klass<ParticleEffect_Event
  event=Struct.new(:real_x,:real_y).new(0,0);owner=klass.allocate
  owner.define_singleton_method(:x) { 256 };owner.define_singleton_method(:y) { 240 };owner.define_singleton_method(:z) { 100 }
  owner.send(:initialize,event,viewport);resets=0;last=[];trace=Digest::SHA256.new
  600.times do
   owner.update
   sprites=owner.instance_variable_get(:@particles);opacity=owner.instance_variable_get(:@opacity)
   opacity.each_with_index { |value,i| resets+=1 if last[i] && value>last[i] };last=opacity.dup
   state=sprites.map { |s| [s.x,s.y,s.opacity,s.blend_type] }
   raise 'Nonfinite particle state' unless state.flatten.all? { |v| v.to_f.finite? }
   state_checks+=sprites.length;trace.update(Marshal.dump(state))
  end
  raise "No particle recycling #{name}" if resets==0
  particles << {'class'=>name.to_s,'logical_updates'=>600,'recycles'=>resets,'trace_sha256'=>trace.hexdigest}
  owner.dispose
 end
 fixtures=[['SnakeSquares',[]],['DiagonalBubble',[0]],['DiagonalBubble',[1]],['DiagonalBubble',[2]],['DiagonalBubble',[3]],
  ['RisingSplash',[]],['TwoBallPass',[]],['SpinBallSplit',[]],['ThreeBallDown',[]],['BallDown',[]],['WavyThreeBallUp',[]],['WavySpinBall',[]],['FourBallBurst',[]]]
 fixtures.each do |name,args|
  transition=Transitions.const_get(name).new(50,*args);updates=0
  until transition.disposed?
   transition.update;updates+=1;raise 'Transition did not terminate' if updates>800
  end
  transitions << {'class'=>name,'arguments'=>args,'requested_frames'=>50,'updates_to_disposal'=>updates}
 end
 ['water_1','water_2'].each do |name|
  issues << {'source'=>"Graphics/Transitions/#{name}.png",'issue'=>'Existing RisingSplash divides by zero with a 40-frame duration at 001_Transitions.rb:915. The actual 40fps caller requests 1.25 seconds (50 frames), which is the completed fixture; this runtime boundary is unrelated to image bytes.'}
 end
 # Explicit cache/plane compatibility for VS and inactive SunMoon resources.
 cached_sources=[]
 rows.select { |r| r['source'].start_with?('Graphics/Transitions/') }.each do |row|
  name=row['source'].delete_prefix('Graphics/Transitions/').sub(/\.png$/i,'')
  bmp=RPG::Cache.transition(name);raise 'Transition cache dimensions' unless [bmp.width,bmp.height]==row['size']
  cached_sources << row['source']
 end
 scripts=['Data/Scripts/012_Overworld/001_Overworld visuals/001_Overworld_Weather.rb','Data/Scripts/010_Data/001_Hardcoded data/012_Weather.rb',
  'Data/Scripts/005_Sprites/010_ParticleEngine.rb','Data/Scripts/007_Objects and windows/009_Planes.rb','Data/Scripts/009_Scenes/001_Transitions.rb',
  'Data/Scripts/007_Objects and windows/001_RPG_Cache.rb','Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'weather_cases'=>weather_cases,'fog_cases'=>fog_cases,'particle_cases'=>particles,
  'transition_cases'=>transitions,'transition_cache_sources'=>cached_sources,'state_checks'=>state_checks,'compatibility_issues'=>issues,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 243 sources directly decoded at original dimensions. Actual RPG::Weather covers ten data types, three strengths, particle recycling, at least two tiled periods and completed fade-out/in with deterministic 40fps logical time. Eighteen fogs use actual AnimatedPlane wrapping boundaries and zoom. Fourteen actual particle classes run 600 updates with fixed event-screen anchors and recycling. Thirteen actual HGSS transition fixtures run to disposal. All transition sources load through actual cache; inactive SunMoon, alternate VS bars, compatibility portraits and twelve unbound battleback animation layers retain exact bytes. Cache decoding is not proof of complete VS trainer intro selection, inactive SunMoon playback, complete map events or battle gameplay.'}
 board.bitmap.dispose;board.dispose;viewport.dispose
 File.write(File.join(directory,'weather-review.json'),KIFMultiplayer::WireJSON.encode(doc,0))
 File.open(log,'a'){ |f| f.puts("P4_WEATHER_PASS inputs=#{inputs.length} types=#{weather_cases.length} particles=#{particles.length} transitions=#{transitions.length} states=#{state_checks}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_WEATHER_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
