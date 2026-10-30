directory=File.expand_path('output/texture-hd/p3-evidence/batch-152');log=File.join(directory,'native-result.txt');passed=false
begin
 File.write(log,"P3_152_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/batch-152-scope.json'))['entries']
 inputs=rows.to_h { |r| [r['source'],Digest::SHA256.hexdigest(File.binread(r['source']))] }
 module P3NeutralActor
  def applyDayNightTone;self.tone.set(0,0,0,0);end
 end
 Sprite_Character.prepend(P3NeutralActor)
 class P3Actor < Game_Event
  def initialize(map)
   event=RPG::Event.new($game_player.x,$game_player.y);event.id=999999;event.name='HD fixture.shadowless'
   super(map.map_id,event,map)
  end
  def should_update?;true;end
 end
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 actor=P3Actor.new($game_map);actor.moveto($game_player.x,$game_player.y)
 charsets=rows.select { |r| r['kind']=='charset' };states=[];timings=[];switches=[];statics=[];throws=[]
 charsets.each_with_index do |row,index|
  actor.character_name='../Alternate Trainers/'+row['source'].sub('Graphics/Alternate Trainers/','')
  actor.character_name=actor.character_name.sub(/\.png\z/,'');actor.pattern=0;actor.direction=2
  sprite=Sprite_Character.new(viewport,actor)
  cw,ch=row['cell_size'];sheet=Bitmap.new(640,640)
  [2,4,6,8].each_with_index do |direction,y|
   4.times do |frame|
    actor.direction=direction;actor.pattern=frame;sprite.update
    r=sprite.src_rect
    raise 'Wrong classic character crop' unless [r.x,r.y,r.width,r.height]==[frame*cw,y*ch,cw,ch]
    expected_oy=row['source'].match?(/fish|dive|surf/i) ? ch-16 : ch
    raise 'Wrong classic anchor' unless sprite.ox==cw/2 && sprite.oy==expected_oy
    sheet.blt(frame*160+80-sprite.ox,y*160+140-sprite.oy,sprite.bitmap,r)
    states << [row['source'],direction,frame,sprite.x,sprite.y,sprite.ox,sprite.oy,r.x,r.y,r.width,r.height]
   end
  end
  sheet.to_file(File.join(directory,"charset-#{index}.png"));sheet.dispose;sprite.dispose
 end
 # Actual animation counter, including a closed loop, at four movement speeds.
 [3,4,5,6].each do |speed|
  actor=Game_Character.new;actor.move_speed=speed;actor.instance_variable_set(:@step_anime,true);sequence=[]
  161.times { actor.update_stop;actor.update_pattern;sequence << actor.pattern }
  raise 'Not all four animation cells played' unless sequence.uniq.sort==[0,1,2,3]
  timings << {'speed'=>speed,'patterns'=>sequence,'frame_rate'=>Graphics.frame_rate}
 end
 # Reuse the same real sprite across actions of the two complete costumes.
 %w[base Chase].each do |costume|
  list=charsets.select { |r| r['source'].include?("/#{costume}/") }
  list=list+[list.first]
  actor=P3Actor.new($game_map);actor.moveto($game_player.x,$game_player.y);actor.character_name=''
  sprite=nil
  list.each do |row|
   actor.character_name='../Alternate Trainers/'+row['source'].sub('Graphics/Alternate Trainers/','').sub(/\.png\z/,'')
   actor.direction=2;actor.pattern=0
   sprite ||= Sprite_Character.new(viewport,actor);sprite.update
   switches << [costume,row['source'],sprite.ox,sprite.oy,sprite.src_rect.width,sprite.src_rect.height]
  end
  sprite.dispose
 end
 rows.select { |r| r['kind']=='static' }.each_with_index do |row,index|
  bitmap=Bitmap.new(row['source']);raise 'Wrong static size' unless [bitmap.width,bitmap.height]==row['size']
  sprite=Sprite.new(viewport);sprite.bitmap=bitmap;sprite.x=256;sprite.y=320;sprite.ox=bitmap.width/2;sprite.oy=bitmap.height
  Graphics.update;picture=Graphics.snap_to_bitmap;picture.to_file(File.join(directory,"static-#{index}.png"));picture.dispose
  statics << [row['source'],sprite.x,sprite.y,sprite.ox,sprite.oy];sprite.dispose;bitmap.dispose
 end
 rows.select { |r| r['kind']=='trainer_throw' }.each do |row|
  sprite=IconSprite.new(180,340,viewport);sprite.setBitmap(row['source']);width=row['cell_size'][0]
  sprite.src_rect.set(0,0,width,row['cell_size'][1]);sprite.ox=width/2;sprite.oy=row['cell_size'][1]
  driver=Object.new;driver.extend(PokeBattle_BallAnimationMixin);driver.instance_variable_set(:@trainer,$Trainer)
  trainer=PictureEx.new(10);trainer.x=sprite.x;trainer.y=sprite.y;ball=PictureEx.new(9)
  driver.trainerThrowingFrames(ball,trainer,sprite);trace=[]
  100.times do |tick|
   trainer.update;setPictureIconSprite(sprite,trainer);trace << [tick,sprite.src_rect.x/width,sprite.x,sprite.y]
   Graphics.update
   break if !trainer.running?
  end
  raise 'Incomplete trainer throw sequence' unless trace.map { |r| r[1] }.uniq==[1,2,3,4,0]
  throws << {'source'=>row['source'],'trace'=>trace};sprite.dispose
 end
 viewport.dispose
 # Scan the serialized resources too; literal-code search alone cannot establish usage.
 strings={};graphics=[];hashes={}
 walk=lambda do |value,path|
  case value
  when String;strings[value] ||= [];strings[value] << path unless strings[value].include?(path)
  when Array;value.each { |v| walk.call(v,path) }
  when RPG::EventCommand;walk.call(value.parameters,path)
  end
 end
 (Dir['Data/Map[0-9][0-9][0-9].rxdata']+['Data/CommonEvents.rxdata']).each do |path|
  data=load_data(path);hashes[path]=Digest::SHA256.hexdigest(File.binread(path))
  if data.is_a?(RPG::Map)
   data.events.each_value do |event|
    event.pages.each { |page| graphics << [path,event.id,page.graphic.character_name];walk.call(page.list,path) }
   end
  else
   data.compact.each { |event| walk.call(event.list,path) }
  end
 end
 metadata=GameData::Metadata.get;players={}
 %w[A B C D E F G H].each do |key|
  value=metadata.send("player_#{key}");players[key]=value&.map { |v| v.is_a?(Symbol) ? v.to_s : v };walk.call(value,'Data/metadata.dat')
 end
 named=[];GameData::TrainerType.each { |data| named << [data.id.to_s,GameData::TrainerType.front_sprite_filename(data.id),GameData::TrainerType.back_sprite_filename(data.id)] }
 matches=rows.to_h do |row|
  needle=row['source'].sub('Graphics/','').sub(/\.png\z/,'').downcase
  found=[]
  strings.each { |text,paths| found.concat(paths) if text.tr('\\','/').downcase.include?(needle) }
  graphics.each { |path,id,name| found << [path,id] if name.tr('\\','/').downcase.include?(needle) }
  named.each { |value| found << value if value.compact.any? { |v| v.to_s.tr('\\','/').downcase.include?(needle) } }
  [row['source'],found.uniq]
 end
 scripts=['Data/Scripts/005_Sprites/003_Sprite_Character.rb','Data/Scripts/004_Game classes/007_Game_Character.rb',
  'Data/Scripts/004_Game classes/008_Game_Event.rb','Data/Scripts/052_AddOns/OverworldShadows.rb',
  'Data/Scripts/010_Data/002_PBS data/014_Metadata.rb','Data/Scripts/011_Battle/005_Battle scene/001_PokeBattle_Animation.rb']
 doc={'status'=>'passed','inputs'=>inputs,'charset_states'=>states,'timings'=>timings,'action_switches'=>switches,'static_renders'=>statics,
  'trainer_throws'=>throws,'resource_references'=>matches,'player_metadata'=>players,'map_sha256'=>hashes,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'20 legacy fully clothed assets, 14 classic 4x4 charsets (64x64 or 96x80 cells), five static pictures and one five-cell throw strip. Actual Sprite_Character crop/origins, action switching, Game_Character animation and PictureEx sequence. Serialized map/common-event/metadata/trainer-path reference scan. Compatibility fixtures do not prove those alternate folders are active player selections. These flat classic sprites do not use the current 80x80 clothing overlay system.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Diagnostic exceeds cap' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'native-review.json'),encoded)
 File.open(log,'a'){ |f| f.puts("P3_152_PASS images=#{inputs.length} charset_states=#{states.length} switches=#{switches.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P3_152_FAIL #{error.class}: #{error.message.to_s[0,1400]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
