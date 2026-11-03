directory=File.expand_path('output/texture-hd/p3-evidence/remaining');log=File.join(directory,'outfits-result.txt');passed=false
begin
 File.write(log,"P3_OUTFITS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/remaining-native-index.json'),49*1024*1024,3000000)['outfit']
 module P3OutfitNeutral
  def applyDayNightTone;self.tone.set(0,0,0,0);end
 end
 Sprite_Player.prepend(P3OutfitNeutral)
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 inputs={};poses=[];portraits=[];compatibility=[];families={};snapshots=[]
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));b=Bitmap.new(source)
  raise "Wrong outfit dimensions #{source}" unless [b.width,b.height]==row['size'];b.dispose
  parts=source.split('/');family=parts[-2];name=File.basename(source,'.png')
  appearance={skin_tone:1,clothes:'red',hair:'2_red',hat:nil,hair_color:0,clothes_color:0,hat_color:0}
  field=nil;identifier=nil;actions=%w[walk run bike fish surf dive walk]
  if source.include?('/clothes/')
   field=:clothes;identifier=family;appearance[field]=identifier
   action=name.sub(/^clothes_/,'').sub(/_#{Regexp.escape(family)}\z/,'')
   actions=[action] if row['kind']=='clothing'
  elsif source.include?('/hair/')
   field=:hair;version=name.sub(/^hair_(trainer_)?/,'').split('_').first
   identifier="#{version}_#{family}";appearance[field]=identifier
  elsif source.include?('/hat/')
   field=:hat;identifier=family;appearance[field]=identifier
  end
  appearance.each { |key,value| $Trainer.instance_variable_set("@#{key}",value) }
  families["#{field}:#{identifier}"] ||= [];families["#{field}:#{identifier}"] << source
  if row['kind']=='ball_overlay'
   ball=source.split('/balls/',2)[1].sub(/\.png\z/,'')
   target=getTrainerSpriteBallFilename(ball);raise 'Ball path mismatch' unless File.expand_path(pbResolveBitmap(target))==File.expand_path(source)
   owner=generate_front_trainer_sprite_bitmap(false,ball);bitmap=owner.bitmap
   bitmap.to_file(File.join(directory,"outfit-portrait-#{index}.png")) if index%8==0
   portraits << [source,bitmap.width,bitmap.height,44,42];owner.dispose
  elsif row['kind']=='portrait_layer'
   expected=field==:clothes ? getTrainerSpriteOutfitFilename(identifier) : field==:hair ? getTrainerSpriteHairFilename(identifier) : getTrainerSpriteHatFilename(identifier)
   actual=pbResolveBitmap(expected)
   if !actual || File.expand_path(actual).downcase!=File.expand_path(source).downcase
    compatibility << {'source'=>source,'issue'=>'Existing portrait filename does not match the current loader route','expected'=>expected};next
   end
   owner=generate_front_trainer_sprite_bitmap(false);bitmap=owner.bitmap
   bitmap.to_file(File.join(directory,"outfit-portrait-#{index}.png")) if index%16==0
   portraits << [source,bitmap.width,bitmap.height,0,0];owner.dispose
  else
   $game_player.character_name='walk';$game_player.pattern=0;$game_player.direction=2
   sprite=Sprite_Player.new(viewport,$game_player)
   expected=field==:clothes ? getOverworldOutfitFilename(identifier,actions.first) : field==:hair ? getOverworldHairFilename(identifier) : getOverworldHatFilename(identifier)
   actual=pbResolveBitmap(expected)
   if !actual || File.expand_path(actual).downcase!=File.expand_path(source).downcase
    compatibility << {'source'=>source,'issue'=>'Existing overworld filename does not match the current loader route','expected'=>expected};sprite.dispose;next
   end
   compatibility << {'source'=>source,'issue'=>'Source is not a modern 320x320 clothing sheet; kept unchanged, no claim that its inherited overlay geometry is correct.'} if row['kind']=='clothing' && row['size']!=[320,320]
   sheet=Bitmap.new(640,640)
   actions.each_with_index do |action,action_index|
    $game_player.character_name=action
    [2,4,6,8].each_with_index do |direction,y|
     4.times do |frame|
      $game_player.direction=direction;$game_player.pattern=frame;sprite.update
      hair=sprite.instance_variable_get(:@hair).sprite;hat=sprite.instance_variable_get(:@hat).sprite
      layers=[sprite,hair,hat].select { |layer| layer.bitmap && layer.visible }
      coords=layers.map { |layer| [layer.x-sprite.x,layer.y-sprite.y,layer.ox,layer.oy,layer.z-sprite.z,layer.src_rect.x,layer.src_rect.y,layer.src_rect.width,layer.src_rect.height] }
      poses << [source,action_index,action,direction,frame,coords]
      if action_index==0 && index%12==0
       layers.each { |layer| sheet.blt(frame*160+80+(layer.x-sprite.x)-layer.ox,y*160+140+(layer.y-sprite.y)-layer.oy,layer.bitmap,layer.src_rect) }
      end
     end
    end
   end
   if index%12==0;sheet.to_file(File.join(directory,"outfit-sheet-#{index}.png"));snapshots << [source,index];end
   sheet.dispose;sprite.dispose
  end
  if index%100==0;Graphics.update;File.open(log,'a'){ |f| f.puts("P3_OUTFITS_PROGRESS #{index}/#{rows.length}") };end
 end
 viewport.dispose
 scripts=['Data/Scripts/005_Sprites/016_Sprite_Player.rb','Data/Scripts/005_Sprites/013_Sprite_Wearable.rb',
  'Data/Scripts/050_Outfits/001_OutfitsMain/LayeredClothes.rb','Data/Scripts/050_Outfits/utils/OutfitFilenameUtils.rb']
 doc={'status'=>'passed','inputs'=>inputs,'poses'=>poses,'portraits'=>portraits,'families'=>families,'compatibility_issues'=>compatibility,'snapshots'=>snapshots,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All remaining clothing/hair/hat/held-ball sources decoded. Sources matching current filename routes exercised through actual Sprite_Player/Sprite_Wearable or portrait compositor, four directions/motion cells; hair/hats through seven action/return states, clothing in its own action. Fixed baseline appearance, not all Cartesian combinations or map events. Existing route mismatches and nonstandard sheets listed separately and retained unchanged.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'outfits-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P3_OUTFITS_PASS inputs=#{inputs.length} poses=#{poses.length} portraits=#{portraits.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P3_OUTFITS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(9).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
