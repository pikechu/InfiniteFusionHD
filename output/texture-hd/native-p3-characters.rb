directory=File.expand_path('output/texture-hd/p3-evidence/remaining');log=File.join(directory,'characters-result.txt');passed=false
begin
 File.write(log,"P3_CHARACTERS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 all=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/remaining-native-index.json'),49*1024*1024,3000000)
 rows=all['npc']+all['follower'];inputs={};poses=[];decoded=[];throws=[];switches=[]
 class P3RemainingActor < Game_Event
  def initialize(map)
   event=RPG::Event.new($game_player.x,$game_player.y);event.id=999998;event.name='HD fixture.shadowless';super(map.map_id,event,map)
  end
  def should_update?;true;end
 end
 module P3RemainingNeutral
  def applyDayNightTone;self.tone.set(0,0,0,0);end
 end
 Sprite_Character.prepend(P3RemainingNeutral)
 viewport=Viewport.new(0,0,512,384);viewport.z=99999;actor=P3RemainingActor.new($game_map);sprite=nil;last_group=nil
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));b=Bitmap.new(source)
  raise "Wrong source dimensions #{source}" unless [b.width,b.height]==row['size'];decoded << [source,b.width,b.height];b.dispose
  if row['kind']=='charset'
   name='../'+source.sub('Graphics/','')
   actor.character_name=name.sub(/\.png\z/,'');actor.pattern=0;actor.direction=2
   sprite ||= Sprite_Character.new(viewport,actor);sprite.update
   cw,ch=row['cell_size'];sheet=Bitmap.new([cw*4,1].max,[ch*4,1].max)
   [2,4,6,8].each_with_index do |direction,y|
    4.times do |frame|
     actor.direction=direction;actor.pattern=frame;sprite.update;r=sprite.src_rect
     raise "Wrong charset rectangle #{source}" unless [r.x,r.y,r.width,r.height]==[frame*cw,y*ch,cw,ch]
     expected_oy=actor.character_name.match?(/fish|dive|surf/i) ? ch-16 : ch
     raise "Wrong charset origin #{source}" unless sprite.ox==cw/2 && sprite.oy==expected_oy
     sheet.blt(frame*cw,y*ch,sprite.bitmap,r)
     poses << [source,direction,frame,sprite.ox,sprite.oy,r.x,r.y,r.width,r.height]
    end
   end
   if index%24==0 || row['grid_remainder']!=[0,0];sheet.to_file(File.join(directory,"characters-sample-#{index}.png"));end
   sheet.dispose
   # Retain every per-file starting origin; no assumption that differently sized
   # legacy costumes share the current player's 80x80 clothing coordinate system.
   actor.direction=2;actor.pattern=0;sprite.update
   switches << [source,sprite.ox,sprite.oy,sprite.src_rect.width,sprite.src_rect.height]
  elsif row['kind']=='trainer_throw'
   trainer_sprite=IconSprite.new(180,340,viewport);trainer_sprite.setBitmap(source);cw,ch=row['cell_size'];trainer_sprite.src_rect.set(0,0,cw,ch);trainer_sprite.ox=cw/2;trainer_sprite.oy=ch
   driver=Object.new;driver.extend(PokeBattle_BallAnimationMixin);driver.instance_variable_set(:@trainer,$Trainer)
   trainer=PictureEx.new(10);trainer.x=trainer_sprite.x;trainer.y=trainer_sprite.y;ball=PictureEx.new(9)
   driver.trainerThrowingFrames(ball,trainer,trainer_sprite);trace=[]
   100.times do |tick|
    trainer.update;setPictureIconSprite(trainer_sprite,trainer);trace << [tick,trainer_sprite.src_rect.x/cw,trainer_sprite.x,trainer_sprite.y]
    Graphics.update;break if !trainer.running?
   end
   raise "Incomplete trainer strip #{source}" unless trace.map { |r| r[1] }.uniq==[1,2,3,4,0]
   throws << {'source'=>source,'trace'=>trace};trainer_sprite.dispose
  end
  if index%200==0;File.open(log,'a'){ |f| f.puts("P3_CHARACTERS_PROGRESS #{index}/#{rows.length}") };Graphics.update;end
 end
 sprite.dispose if sprite;viewport.dispose
 timings=[]
 [3,4,5,6].each do |speed|
  a=Game_Character.new;a.move_speed=speed;a.instance_variable_set(:@step_anime,true);sequence=[]
  161.times { a.update_stop;a.update_pattern;sequence << a.pattern };raise 'Incomplete native timing cycle' unless sequence.uniq.sort==[0,1,2,3]
  timings << [speed,sequence]
 end
 scripts=['Data/Scripts/005_Sprites/003_Sprite_Character.rb','Data/Scripts/004_Game classes/007_Game_Character.rb',
  'Data/Scripts/004_Game classes/008_Game_Event.rb','Data/Scripts/052_AddOns/OverworldShadows.rb','Data/Scripts/011_Battle/005_Battle scene/001_PokeBattle_Animation.rb']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'poses'=>poses,'resource_switches'=>switches,'trainer_throws'=>throws,'timings'=>timings,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'Unchanged NPC/legacy/follower sources. Native Sprite_Character default four-direction/four-column crop, original origins, resource switches, timing at four speeds, and actual PictureEx throwing for five-cell legacy strips. Fixed shadowless neutral fixtures are compatibility rendering; not proof of every map-event/follower AI or roof/water interaction.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'characters-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P3_CHARACTERS_PASS inputs=#{inputs.length} poses=#{poses.length} throws=#{throws.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P3_CHARACTERS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(9).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
