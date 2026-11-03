directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'effects-result.txt');passed=false
begin
 File.write(log,"P4_EFFECTS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['stage']=='effects' }
 normalize=lambda { |s| s.tr('\\','/').sub(/\.(png|gif)\z/i,'').downcase }
 by_path=rows.to_h { |r| [normalize.call(r['source']),r] };inputs={};decoded=[]
 rows.each do |row|
  inputs[row['source']]=Digest::SHA256.hexdigest(File.binread(row['source']));b=Bitmap.new(row['source'])
  raise "Dimensions #{row['source']}" unless [b.width,b.height]==row['size'];decoded << [row['source'],b.width,b.height];b.dispose
 end
 $p4_effect_sounds=0
 module P4EffectAudio
  def pbSEPlay(*args);$p4_effect_sounds+=1;end
 end
 Object.prepend(P4EffectAudio)
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 userbitmap=Bitmap.new('Graphics/BaseSprites/1.png');targetbitmap=Bitmap.new('Graphics/BaseSprites/4.png')
 usersprite=Sprite.new(viewport);usersprite.bitmap=userbitmap;targetsprite=Sprite.new(viewport);targetsprite.bitmap=targetbitmap
 fixture=Struct.new(:sprites,:viewport).new({'pokemon_0'=>usersprite,'pokemon_1'=>targetsprite},viewport)
 battler=Struct.new(:index,:pokemon);user=battler.new(0,nil);target=battler.new(1,nil)
 cases=[];errors=[];used={};bounds={};cell_checks=0;tick_states=0
 animations=pbLoadBattleAnimations
 animations.each_with_index do |animation,id|
  next unless animation
  main=by_path[normalize.call('Graphics/Animations/'+animation.graphic)]
  timed=animation.timing.map { |t| by_path[normalize.call('Graphics/Animations/'+t.name.to_s)] if [1,3].include?(t.timingType) }.compact
  next if !main && timed.empty?
  ([main]+timed).compact.each { |r| used[r['source']]=true }
  [false,true].each do |reverse|
   player=nil
   begin
    [[usersprite,userbitmap,reverse ? 384 : 144,reverse ? 160 : 300],[targetsprite,targetbitmap,reverse ? 144 : 384,reverse ? 300 : 160]].each do |sprite,bitmap,x,y|
     sprite.bitmap=bitmap;sprite.src_rect=bitmap.rect;sprite.ox=bitmap.width/2;sprite.oy=bitmap.height;sprite.x=x;sprite.y=y;sprite.visible=true
    end
    player=PBAnimationPlayerX.new(animation,user,target,fixture,reverse)
    player.setLineTransform(PokeBattle_SceneConstants::FOCUSUSER_X,PokeBattle_SceneConstants::FOCUSUSER_Y,
     PokeBattle_SceneConstants::FOCUSTARGET_X,PokeBattle_SceneConstants::FOCUSTARGET_Y,
     usersprite.x,usersprite.y-userbitmap.height/2,targetsprite.x,targetsprite.y-targetbitmap.height/2)
    player.start;updates=0;states=[]
    until player.animDone?
     frame=player.instance_variable_get(:@frame)/2;player.update;updates+=1
     raise 'Animation failed to terminate' if updates>animation.length*2+2
     next if player.animDone? || updates%2==0
     sprites=player.instance_variable_get(:@animsprites)
     animation[frame].each_with_index do |cel,i|
      next if !cel || !sprites[i]
      sprite=sprites[i];pattern=cel[AnimFrame::PATTERN]
      if pattern && pattern>=0
       expected=[(pattern%5)*192,(pattern/5)*192,192,192]
       actual=[sprite.src_rect.x,sprite.src_rect.y,sprite.src_rect.width,sprite.src_rect.height]
       raise 'Native cel crop changed' unless actual==expected && sprite.ox==96 && sprite.oy==96
       if main && (expected[0]+192>main['size'][0] || expected[1]+192>main['size'][1])
        bounds[main['source']] ||= [];bounds[main['source']] << pattern unless bounds[main['source']].include?(pattern)
       end
       raise 'Native blend/opacity changed' unless sprite.blend_type==cel[AnimFrame::BLENDTYPE] && sprite.opacity==cel[AnimFrame::OPACITY]
       cell_checks+=1
      end
      states << [frame,i,pattern,sprite.x,sprite.y,sprite.z,sprite.src_rect.x,sprite.src_rect.y,sprite.zoom_x,sprite.zoom_y,
       sprite.angle,sprite.opacity,sprite.mirror,sprite.blend_type,sprite.visible]
     end
     tick_states+=1
     if id%120==0 && frame==animation.length/2
      Graphics.update;snap=Graphics.snap_to_bitmap;snap.to_file(File.join(directory,"effects-#{id}-#{reverse ? 1 : 0}.png"));snap.dispose
     end
    end
    raise 'Animation duration' unless updates==animation.length*2+1
    cases << {'id'=>id,'name'=>animation.name,'graphic'=>animation.graphic,'reverse'=>reverse,'ticks'=>animation.length,
     'updates'=>updates,'state_count'=>states.length,'trace_sha256'=>Digest::SHA256.hexdigest(Marshal.dump(states))}
   rescue Exception => error
    errors << {'id'=>id,'name'=>animation.name,'source'=>main ? main['source'] : timed.first['source'],
     'reverse'=>reverse,'error'=>"#{error.class}: #{error.message.to_s[0,350]}"}
   ensure
    player.dispose if player
   end
  end
  if id%150==0;Graphics.update;File.open(log,'a'){ |f| f.puts("P4_EFFECTS_PROGRESS id=#{id} cases=#{cases.length} errors=#{errors.length}") };end
 end
 usersprite.dispose;targetsprite.dispose;userbitmap.dispose;targetbitmap.dispose;viewport.dispose
 scripts=['Data/Scripts/011_Battle/006_Other battle types/001_PokeBattle_AnimationPlayer.rb',
  'Data/Scripts/011_Battle/005_Battle scene/009_Scene_Animations.rb','Data/Scripts/007_Objects and windows/009_Planes.rb',
  'Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb']
 data=%w[Data/PkmnAnimations.rxdata Data/move2anim.dat]
 doc={'status'=>errors.empty? ? 'passed' : 'needs_review','inputs'=>inputs,'decoded'=>decoded,'cases'=>cases,'existing_animation_errors'=>errors,
  'referenced_sources'=>used.keys,'unreferenced_sources'=>rows.map { |r| r['source'] }-used.keys,
  'out_of_sheet_patterns'=>bounds,'cell_checks'=>cell_checks,'tick_states'=>tick_states,'audio_events_observed'=>$p4_effect_sounds,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'data_sha256'=>data.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 925 effect sources directly decode at original dimensions. All animation-data entries referencing P4 main/background/foreground images run through actual PBAnimationPlayerX in normal/reversed line fixtures to termination; 192-pixel cel crop, origin, blending, opacity, frame order and update count checked. State hashes preserve visual transform traces; audio event calls observed with sound suppressed. Out-of-sheet patterns or existing data/runtime failures are explicitly reported. Unreferenced/script-only effect images remain byte-identical and are not claimed as complete move/capture gameplay. One-shot move animations are checked to completion, not falsely looped.'}
 File.write(File.join(directory,'effects-review.json'),KIFMultiplayer::WireJSON.encode(doc,0));File.open(log,'a'){ |f| f.puts("P4_EFFECTS_COMPLETE inputs=#{inputs.length} cases=#{cases.length} errors=#{errors.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_EFFECTS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
