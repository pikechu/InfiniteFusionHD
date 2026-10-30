directory=File.expand_path('output/texture-hd/p2-evidence/remaining');log=File.join(directory,'player-result.txt');passed=false
begin
 File.write(log,"PLAYER_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-remaining-work/scope.json'))['entries'].select { |r| (108..115).include?(r['batch'][6..-1].to_i) }
 inputs=rows.to_h { |r| [r['source'],Digest::SHA256.hexdigest(File.binread(r['source']))] }
 rows.each { |r| b=Bitmap.new(r['source']);raise "Wrong size #{r['source']}" unless [b.width,b.height]==r['size'];b.dispose }
 # Neutral lighting isolates the clothing/geometry checks from host clock tint.
 module RemainingPlayerNeutral
  def applyDayNightTone;self.tone.set(0,0,0,0);end
 end
 Sprite_Player.prepend(RemainingPlayerNeutral)
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 cases=[];anchors=[];fallbacks=[];timings=[];portraits=[]
 outfits=%w[red leaf pikajamas];styles=[]
 [0,1,2,3,4,5,6,'default'].each { |skin| outfits.each { |clothes| %w[red leaf].each { |hair| styles << [skin,clothes,2,hair,nil] } } }
 outfits.each { |clothes| %w[red leaf].each { |hair| (1..4).each { |version| [nil,'red','leaf','ash'].each { |hat| styles << [1,clothes,version,hair,hat] } } } }
 styles.uniq!
 styles.each_with_index do |(skin,clothes,version,hair,hat),case_id|
  {skin_tone:skin,clothes:clothes,hair:getFullHairId(hair,version),hat:hat,hair_color:0,clothes_color:0,hat_color:0}.each { |key,value| $Trainer.instance_variable_set("@#{key}",value) }
  $game_player.character_name='walk';$game_player.pattern=0;$game_player.direction=2
  sprite=Sprite_Player.new(viewport,$game_player)
  %w[walk run bike fish surf dive walk].each_with_index do |action,action_id|
   $game_player.character_name=action
   base=getBaseOverworldSpriteFilename(action,skin);fallbacks << [case_id,action,base] if !base.include?("/#{skin}/")
   sheet=Bitmap.new(640,160)
   [2,4,6,8].each_with_index do |direction,row|
    4.times do |frame|
     $game_player.direction=direction;$game_player.pattern=frame;$game_player.pattern_surf=frame
     sprite.update
     hair_sprite=sprite.instance_variable_get(:@hair).sprite;hat_sprite=sprite.instance_variable_get(:@hat).sprite
     layers=[sprite,hair_sprite,hat_sprite].select { |s| s.bitmap && s.visible }
     coords=layers.map { |s| [s.x-sprite.x,s.y-sprite.y,s.ox,s.oy,s.z,s.src_rect.x,s.src_rect.y,s.src_rect.width,s.src_rect.height] }
     raise 'Clothing frame must be 80x80' unless [sprite.src_rect.width,sprite.src_rect.height]==[80,80]
     layers.each do |layer|
      dx=frame*160+80+(layer.x-sprite.x)-layer.ox;dy=140+(layer.y-sprite.y)-layer.oy
      sheet.blt(dx,dy,layer.bitmap,layer.src_rect)
     end
     anchors << [case_id,action_id,direction,frame,coords]
    end
    # Four frames in each row; native composition uses production body/hair/hat
    # crop/offsets. Store all four directions in separate lossless strips.
    label="player-#{case_id}-#{action_id}-#{direction}"
    if case_id<6 || (skin==1 && action=='walk' && hat)
     sheet.to_file(File.join(directory,label+'.png'));cases << {'label'=>label,'appearance'=>[skin,clothes,version,hair,hat],'action'=>action,'direction'=>direction}
    end
    sheet.clear
   end
   sheet.dispose
  end
  sprite.dispose
  # Actual production front portrait compositor for the same appearance.
  portrait=generate_front_trainer_sprite_bitmap(false)
  portrait=portrait.bitmap if portrait.respond_to?(:bitmap)
  label="portrait-#{case_id}";portrait.to_file(File.join(directory,label+'.png'))
  portraits << {'label'=>label,'appearance'=>[skin,clothes,version,hair,hat],'size'=>[portrait.width,portrait.height]}
  portrait.dispose
  Graphics.update if case_id%8==0
 end
 # All surf/dive shapes use the actual Sprite_SurfBase loader and placement.
 surf_cases=[]
 surf_rows=rows.select { |r| r['source'].include?('/surf_base/') }
 shape_class=Struct.new(:shape)
 surf_rows.each do |row|
  name=File.basename(row['source'],'.png');action,shape=name.split('_',2)
  $Trainer.instance_variable_set(:@surfing_pokemon,shape=='board' ? nil : shape_class.new(shape.to_sym))
  $PokemonGlobal.surfing=action=='surfmon';$PokemonGlobal.diving=action=='divemon'
  $game_player.character_name=$PokemonGlobal.surfing ? 'surf' : 'dive'
  sprite=Sprite_Player.new(viewport,$game_player);base=sprite.instance_variable_get(:@surfbase)
  strip=Bitmap.new(640,640)
  [2,4,6,8].each_with_index do |direction,y|
   4.times do |frame|
    $game_player.direction=direction;$game_player.pattern=frame;$game_player.pattern_surf=frame;sprite.update
    layer=base.instance_variable_get(:@sprite);raise 'Missing surf base layer' unless layer && layer.bitmap
    strip.blt(frame*160+80-layer.ox,y*160+140-layer.oy,layer.bitmap,layer.src_rect)
    surf_cases << [row['source'],direction,frame,layer.x-sprite.x,layer.y-sprite.y,layer.ox,layer.oy,layer.z-sprite.z,layer.src_rect.x,layer.src_rect.y]
   end
  end
  strip.to_file(File.join(directory,"#{name}-native.png"));strip.dispose;sprite.dispose
 end
 $PokemonGlobal.surfing=false;$PokemonGlobal.diving=false;$Trainer.instance_variable_set(:@surfing_pokemon,nil)
 [3,4,5,6].each do |speed|
  actor=Game_Character.new;actor.move_speed=speed;actor.instance_variable_set(:@step_anime,true)
  sequence=[]
  193.times do |tick|
   actor.update_stop;actor.update_pattern;sequence << actor.pattern
  end
  raise 'Incomplete four-pattern timing loop' unless sequence.uniq.sort==[0,1,2,3]
  timings << {'move_speed'=>speed,'frames'=>sequence,'frame_rate'=>Graphics.frame_rate}
 end
 viewport.dispose
 scripts=['Data/Scripts/005_Sprites/003_Sprite_Character.rb','Data/Scripts/005_Sprites/005_Sprite_SurfBase.rb',
  'Data/Scripts/005_Sprites/013_Sprite_Wearable.rb','Data/Scripts/005_Sprites/016_Sprite_Player.rb',
  'Data/Scripts/004_Game classes/007_Game_Character.rb','Data/Scripts/050_Outfits/utils/OutfitFilenameUtils.rb',
  'Data/Scripts/050_Outfits/001_OutfitsMain/LayeredClothes.rb']
 data={'status'=>'passed','inputs'=>inputs,'appearance_cases'=>styles.length,'actions'=>%w[walk run bike fish surf dive walk],
  'anchors'=>anchors,'strips'=>cases,'portraits'=>portraits,'fallbacks'=>fallbacks,'surf_cases'=>surf_cases,'timings'=>timings,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'Original retained sheets only. Actual Sprite_Player clothing/hair/hat crop and offsets across every direction/frame and action switch, all starting hair/hat variations and skin-tone/outfit combinations; all surf base shapes through Sprite_SurfBase. Timing uses actual Game_Character update_pattern at four speeds. Neutral tint, fixed pose driver; not all gameplay movement/roof/water event flows.'}
 encoded=KIFMultiplayer::WireJSON.encode(data,0);raise 'Diagnostic exceeds cap' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'player-review.json'),encoded);File.open(log,'a'){ |f| f.puts("PLAYER_PASS inputs=#{inputs.length} appearances=#{styles.length} pose_states=#{anchors.length} surf_states=#{surf_cases.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("PLAYER_FAIL #{error.class}: #{error.message.to_s[0,1200]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
