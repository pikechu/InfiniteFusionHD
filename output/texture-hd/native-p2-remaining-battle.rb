directory=File.expand_path('output/texture-hd/p2-evidence/remaining');log=File.join(directory,'battle-result.txt');passed=false
begin
 File.write(log,"BATTLE_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1;srand(116)
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-remaining-work/scope.json'))['entries'].select { |r| (116..151).include?(r['batch'][6..-1].to_i) }
 inputs={};sizes={}
 rows.each do |r|
  inputs[r['source']]=Digest::SHA256.hexdigest(File.binread(r['source']));b=Bitmap.new(r['source'])
  raise "Wrong size #{r['source']}" unless [b.width,b.height]==r['size'];sizes[r['source']]=[b.width,b.height];b.dispose
 end
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 species=rows.select { |r| r['source'].include?('/BaseSprites/') || r['source'].include?('/Battlers/') }.map { |r| File.basename(r['source'],'.png').to_i }.uniq.sort
 states=[];battlers=[];shinies=[]
 atlas=nil;page=0
 species.each_with_index do |id,index|
  if index%12==0
   atlas.to_file(File.join(directory,"battle-front-#{page}.png")) if atlas
   atlas.dispose if atlas;page+=1;atlas=Bitmap.new(1280,1008)
  end
  pokemon=Pokemon.new(id,30,$Trainer);pokemon.shiny=false;pokemon.hat=nil
  [false,true].each do |back|
   sprite=PokemonBattlerSprite.new(viewport,1,back ? 0 : 1,[])
   sprite.setPokemonBitmap(pokemon,back);sprite.visible=true
   actual=GameData::Species.sprite_filename(id,nil,nil)
   battlers << {'id'=>id,'back'=>back,'path'=>actual,'size'=>[sprite.bitmap.width,sprite.bitmap.height],
                 'anchor'=>[sprite.x,sprite.y,sprite.ox,sprite.oy],'mirror'=>sprite.mirror}
   unless back
    x=index%4*320;y=(index%12)/4*336
    atlas.blt(x+(320-sprite.bitmap.width)/2,y+320-sprite.bitmap.height,sprite.bitmap,sprite.bitmap.rect)
    atlas.draw_text(x,y,320,26,id.to_s)
   end
   [1,2].each do |mode|
    sprite.selected=mode
    25.times do |tick|
     sprite.update(tick%24)
     states << [id,back,mode,tick,sprite.x,sprite.y,sprite.instance_variable_get(:@spriteYExtra),sprite.visible,sprite.mirror]
    end
   end
   if [1,4,7,25,150,470].include?(id)
    sprite.selected=0;sprite.update(0);Graphics.update
    image=Graphics.snap_to_bitmap;image.to_file(File.join(directory,"battle-#{id}-#{back ? 'back' : 'front'}.png"));image.dispose
   end
   sprite.dispose
  end
  Graphics.update if index%12==0
 end
 atlas.to_file(File.join(directory,"battle-front-#{page}.png"));atlas.dispose
 # Existing shiny transformation path, normal/front and mirrored back rendering.
 [1,4,7,25,150,470].each do |id|
  [false,true].each do |back|
   sprite=PokemonSprite.new(viewport);sprite.setPokemonBitmapFromId(id,back,true,true,true,120)
   label="shiny-#{id}-#{back ? 1 : 0}";sprite.bitmap.to_file(File.join(directory,label+'.png'))
   shinies << [id,back,sprite.bitmap.width,sprite.bitmap.height];sprite.dispose
  end
 end
 trainer_rows=rows.select { |r| r['source'].include?('/Trainers/') };trainer_renders=[];throws=[]
 trainer_rows.each_with_index do |row,index|
  bmp=Bitmap.new(row['source']);label="trainer-#{File.basename(row['source'],'.png')}"
  if bmp.width==bmp.height*5
   sprite=IconSprite.new(180,340,viewport);sprite.setBitmap(row['source']);sprite.src_rect.set(0,0,bmp.height,bmp.height);sprite.ox=bmp.height/2;sprite.oy=bmp.height
   trainer=PictureEx.new(10);trainer.x=sprite.x;trainer.y=sprite.y;ball=PictureEx.new(9)
   driver=Object.new;driver.extend(PokeBattle_BallAnimationMixin);driver.instance_variable_set(:@trainer,$Trainer)
   driver.trainerThrowingFrames(ball,trainer,sprite)
   trace=[]
   100.times do |tick|
    trainer.update;setPictureIconSprite(sprite,trainer)
    trace << [tick,sprite.src_rect.x,sprite.x,sprite.y]
    Graphics.update
    break if !trainer.running?
   end
   frames=trace.map { |r| r[1]/bmp.height }.uniq
   raise "Incomplete throw frames #{row['source']} #{frames}" unless frames.sort==[0,1,2,3,4]
   throws << {'source'=>row['source'],'trace'=>trace,'frame_order'=>frames,'animation'=>'Actual PokeBattle_BallAnimationMixin trainerThrowingFrames/PictureEx; compatibility strip, not the current layered player portrait.'}
   sprite.dispose
  end
  bmp.to_file(File.join(directory,label+'.png'));trainer_renders << {'source'=>row['source'],'label'=>label,'size'=>row['size']};bmp.dispose
 end
 scene=PokeBattle_Scene.allocate;scene.instance_variable_set(:@viewport,viewport);scene.instance_variable_set(:@sprites,{})
 $Trainer.instance_variable_set(:@skin_tone,1);$Trainer.instance_variable_set(:@clothes,'red');$Trainer.instance_variable_set(:@hair,'2_red');$Trainer.instance_variable_set(:@hat,'red')
 current=scene.pbCreateTrainerBackSprite(0,:POKEMONTRAINER_Red,1)
 Graphics.update;picture=Graphics.snap_to_bitmap;picture.to_file(File.join(directory,'current-layered-player-battle.png'));picture.dispose
 current_player={'bitmap_size'=>[current.bitmap.width,current.bitmap.height],'anchor'=>[current.x,current.y,current.ox,current.oy],
                 'zoom'=>[current.zoom_x,current.zoom_y],'mirror'=>current.mirror,'legacy_five_frame_strip'=>false}
 pbDisposeSpriteHash(scene.instance_variable_get(:@sprites));viewport.dispose
 scripts=['Data/Scripts/011_Battle/005_Battle scene/004_PokeBattle_SceneElements.rb','Data/Scripts/011_Battle/005_Battle scene/007_Scene_Initialize.rb',
  'Data/Scripts/011_Battle/005_Battle scene/001_PokeBattle_Animation.rb','Data/Scripts/052_AddOns/FusionSprites.rb',
  'Data/Scripts/010_Data/002_PBS data/009_Species_Files.rb','Data/Scripts/010_Data/002_PBS data/012_TrainerType.rb']
 data={'status'=>'passed','inputs'=>inputs,'decoded_sizes'=>sizes,'species_count'=>species.length,'battlers'=>battlers,'states'=>states,
  'shiny_cases'=>shinies,'trainer_renders'=>trainer_renders,'trainer_throws'=>throws,'current_player_battle'=>current_player,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 917 default Pokemon source files and 130 trainer files unchanged. Actual PokemonBattlerSprite front/back metrics, mirror, complete 24-update selection bob/target blink cycles; representative existing shiny conversion. Native trainer sheet decodes and full legacy throwing PictureEx sequence; current player uses a layered front portrait. Not a complete battle/move-effect playthrough or all shiny settings.'}
 encoded=KIFMultiplayer::WireJSON.encode(data,0);raise 'Diagnostic exceeds cap' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'battle-review.json'),encoded);File.open(log,'a'){ |f| f.puts("BATTLE_PASS inputs=#{inputs.length} species=#{species.length} states=#{states.length} trainer_strips=#{throws.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("BATTLE_FAIL #{error.class}: #{error.message.to_s[0,1400]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
