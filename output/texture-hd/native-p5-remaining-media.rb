directory=File.expand_path('output/texture-hd/p5-evidence/remaining');log=File.join(directory,'media-native-result.txt');passed=false
begin
 File.write(log,"P5_MEDIA_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1;$PokemonSystem.kurayindividcustomsprite=0
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p5-work/remaining-native-index.json'),49*1024*1024,3000000)
 inputs={};decoded=[];exports=[];compositions=[];battlers=[];compatibility=[];generic=[];charsets=[];editor=[];state_checks=0
 period=(PokemonBattlerSprite::QUARTER_ANIM_PERIOD*4).to_i.lcm((PokemonBattlerSprite::SIXTH_ANIM_PERIOD*6).to_i)
 raise 'Unexpected selection period' unless period>0 && period<=120
 viewport=Viewport.new(0,0,512,384)
 class P5ArchiveActor < Game_Event
  def initialize(map)
   event=RPG::Event.new($game_player.x,$game_player.y);event.id=999996;event.name='HD fixture.shadowless';super(map.map_id,event,map)
  end
  def should_update?;true;end
 end
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Source dimensions #{source}" unless [bitmap.width,bitmap.height]==row['size']
  decoded << [source,bitmap.width,bitmap.height,bitmap.animated?,bitmap.frame_count]
  raise "Unexpected encoded animation #{source}" if bitmap.animated? && bitmap.frame_count>1
  bitmap.dispose
  if row['stage']=='source96' && [[96,96],[288,288]].include?(row['size'])
   resolved=pbResolveBitmap(source);case_fallback=resolved.nil?
   if case_fallback
    compatibility << {'source'=>source,'issue'=>'Current custom-file resolver rejects this literal filename (including uppercase extension cases) and falls back to species 1. Explicit-case Bitmap/AnimatedBitmap loading is distinct from a successful custom species binding.'}
   end
   owner=GameData::Species.front_sprite_bitmap(1,nil,nil,false,false,false,0,0,1,2,[0,0,0,0,0,0,0,0,0,0],{},source)
   raise 'Recognized source dimensions' unless [owner.width,owner.height]==[288,288]
   if row['size']==[96,96]
    filename="#{index}.png";owner.bitmap.to_file(File.join('temp/texture-p5-scale-check/frames',filename))
    record={'source'=>source,'native_export'=>filename,'native_size'=>[owner.width,owner.height],'factory_resolved'=>resolved,'factory_fallback'=>case_fallback}
    if case_fallback
     direct=AnimatedBitmap.new(source).recognizeDims();direct_name="#{index}-direct.png"
     raise 'Explicit-case scaling dimensions' unless [direct.width,direct.height]==[288,288]
     direct.bitmap.to_file(File.join('temp/texture-p5-scale-check/frames',direct_name));direct.dispose;record['direct_export']=direct_name
    end
    exports << record
   end
   owner.dispose
   pokemon=Pokemon.new(1,30,$Trainer);pokemon.shiny=false;pokemon.hat=nil;pokemon.kuraycustomfile=source
   [false,true].each do |back|
    sprite=PokemonBattlerSprite.new(viewport,1,back ? 0 : 1,[]);sprite.setPokemonBitmap(pokemon,back);sprite.visible=true
    raise 'Battle origin' unless sprite.ox==sprite.bitmap.width/2 && sprite.oy==sprite.bitmap.height
    raise 'Battle mirroring' unless sprite.mirror==back
    traces=[]
    [1,2].each do |selected|
     sprite.selected=selected;states=[]
     (period+1).times do |tick|
      sprite.update(tick%period);states << [sprite.instance_variable_get(:@spriteYExtra),sprite.visible];state_checks+=1
     end
     raise 'Selection/target cycle did not repeat' unless states.first==states.last
     traces << {'selected'=>selected,'trace_sha256'=>Digest::SHA256.hexdigest(Marshal.dump(states))}
    end
    battlers << {'source'=>source,'back'=>back,'custom_source_bound'=>!case_fallback,'size'=>[sprite.bitmap.width,sprite.bitmap.height],'origin'=>[sprite.ox,sprite.oy],'selection_period'=>period,'traces'=>traces}
    sprite.dispose
   end
  elsif source.start_with?('Graphics/Battlebacks/')
   is_old_player=source.include?('/playerbase_orig/');is_player=is_old_player || source.end_with?('_base0.png');is_enemy=source.end_with?('_base1.png')
   is_background=source.end_with?('_bg.png') || source.include?('/battlebg/backup/')
   scene=PokeBattle_Scene.allocate;scene.instance_variable_set(:@sprites,{});scene.instance_variable_set(:@viewport,viewport)
   scene.apply_backdrop_graphics(is_background ? source : 'Graphics/Battlebacks/battlebg/field',
    is_player ? source : 'Graphics/Battlebacks/playerbase/field',is_enemy ? source : 'Graphics/Battlebacks/enemybase/field','Graphics/Battlebacks/default_message')
   if is_player || is_enemy
    base=scene.instance_variable_get(:@sprites)[is_player ? 'base_0' : 'base_1']
    raise 'Archived base origin' unless base.ox==base.bitmap.width/2 && base.oy==(is_player ? base.bitmap.height : base.bitmap.height/2)
   end
   Graphics.update
   compositions << {'source'=>source,'role'=>is_player ? 'player_base' : is_enemy ? 'enemy_base' : 'background'}
   if index%24==0;Graphics.update;snap=Graphics.snap_to_bitmap;snap.to_file(File.join(directory,"archive-composition-#{index}.png"));snap.dispose;end
   pbDisposeSpriteHash(scene.instance_variable_get(:@sprites))
  elsif source.start_with?('Graphics/Characters/')
   actor=P5ArchiveActor.new($game_map);actor.character_name=File.basename(source,'.png');actor.pattern=0;actor.direction=2
   sprite=Sprite_Character.new(viewport,actor);cw=row['size'][0]/4;ch=row['size'][1]/4;poses=[]
   [2,4,6,8].each_with_index do |direction,y|
    4.times do |frame|
     actor.direction=direction;actor.pattern=frame;sprite.update;r=sprite.src_rect
     raise 'Archived walking crop' unless [r.x,r.y,r.width,r.height]==[frame*cw,y*ch,cw,ch]
     raise 'Archived walking origin' unless sprite.ox==cw/2 && sprite.oy==ch
     poses << [direction,frame,r.x,r.y,sprite.ox,sprite.oy]
    end
   end
   charsets << {'source'=>source,'poses'=>poses};sprite.dispose
  else
   owner=AnimatedBitmap.new(source);raise 'Compatibility loader dimensions' unless [owner.width,owner.height]==row['size']
   generic << {'source'=>source,'size'=>row['size'],'generic_frames'=>owner.length,'scope'=>'Explicit compatibility bitmap, not automatic selection or declared animation timing'}
   owner.dispose
  end
  if index%100==0;Graphics.update;File.open(log,'a'){ |f| f.puts("P5_MEDIA_PROGRESS #{index}/#{rows.length} exports=#{exports.length}") };end
 end
 viewport.dispose
 # Actual editor construction/selection, without auto-positioning, metric edits or saving.
 [0,2].each do |language|
  GameLanguage.load(language);before=Digest::SHA256.hexdigest(Marshal.dump(GameData::Species.get(:BULBASAUR)))
  scene=SpritePositioner.new;scene.pbOpen;scene.pbChangeSpecies(:BULBASAUR);scene.refresh;scene.update
  sprites=scene.instance_variable_get(:@sprites);message=sprites['messageBox']
  raise 'Editor message geometry' unless [message.bitmap.width,message.bitmap.height,message.x,message.y]==[512,96,0,288]
  Graphics.update;shot=Graphics.snap_to_bitmap;shot.to_file(File.join(directory,"editor-language-#{language}.png"));shot.dispose
  editor << {'language'=>language,'message_source'=>'Graphics/Pictures/Battle/debug_message.png','message_position'=>[message.x,message.y],'size'=>[message.bitmap.width,message.bitmap.height]}
  pbDisposeSpriteHash(sprites);scene.instance_variable_get(:@viewport).dispose
  raise 'Editor fixture changed species metadata' unless before==Digest::SHA256.hexdigest(Marshal.dump(GameData::Species.get(:BULBASAUR)))
 end
 GameLanguage.load(0)
 scripts=['Data/Scripts/052_AddOns/FusionSprites.rb','Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb',
  'Data/Scripts/011_Battle/005_Battle scene/004_PokeBattle_SceneElements.rb','Data/Scripts/011_Battle/005_Battle scene/007_Scene_Initialize.rb',
  'Data/Scripts/005_Sprites/003_Sprite_Character.rb','Data/Scripts/004_Game classes/008_Game_Event.rb',
  'Data/Scripts/020_Debug/001_Editor screens/004_EditorScreens_SpritePositioning.rb']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'source96_exports'=>exports,'battler_cases'=>battlers,
  'archive_compositions'=>compositions,'archive_frames_rendered'=>compositions.length,'charsets'=>charsets,'generic_compatibility'=>generic,'editor_cases'=>editor,'state_checks'=>state_checks,
  'compatibility_issues'=>compatibility,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 1754 sources directly decode at original dimensions. Recognized 96/288 square artist sources exercise actual custom-file front/back battler factories, bottom-center origins, mirroring and a complete selection/target period. Resolver fallbacks are explicitly marked as unbound source cases, with separate explicit-case loads. Native 96-to-288 exports require external alpha/visible-RGB verification. Old backdrop/base overrides retain exact canvas/margins and applicable anchors. Both old walking sheets cover all direction/cell crops. Actual SpritePositioner builds in English/Chinese and selects Bulbasaur without metric edits or saves. Other atlases, PNG strips, large tiles and miscellaneous art are explicit compatibility loads; no automatic species binding, unspecified animation duration, map seam, ordinary archive selection or complete gameplay is certified.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Media report cap' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'media-native-review.json'),encoded)
 File.open(log,'a'){ |f| f.puts("P5_MEDIA_PASS inputs=#{inputs.length} exports=#{exports.length} battlers=#{battlers.length} states=#{state_checks} compositions=#{compositions.length} chars=#{charsets.length} editor=#{editor.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P5_MEDIA_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
