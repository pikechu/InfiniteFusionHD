directory=File.expand_path('output/texture-hd/p3-evidence/remaining');log=File.join(directory,'battle-art-result.txt');passed=false
begin
 File.write(log,"P3_BATTLE_ART_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1;srand(379)
 all=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p3-work/remaining-native-index.json'),49*1024*1024,3000000)
 rows=all['pokemon_alt']+all['special'];inputs={};cases=[];states=[];hues=[];issues=[]
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Wrong battle source size #{source}" unless [bitmap.width,bitmap.height]==row['size'];bitmap.dispose
  id=File.basename(source)[/^\d+/].to_i;id=1 if id<1 || id>Settings::NB_POKEMON
  pokemon=Pokemon.new(id,30,$Trainer);pokemon.shiny=false;pokemon.hat=nil;pokemon.kuraycustomfile=source
  $PokemonSystem.kurayindividcustomsprite=0
  [false,true].each do |back|
   sprite=PokemonBattlerSprite.new(viewport,1,back ? 0 : 1,[]);sprite.setPokemonBitmap(pokemon,back);sprite.visible=true
   scale=back ? Settings::BACKRPSPRITE_SCALE : Settings::FRONTSPRITE_SCALE
   recognized=row['size']==[96,96] ? [288,288] : row['size']
   cases << [source,id,back,sprite.bitmap.width,sprite.bitmap.height,sprite.x,sprite.y,sprite.ox,sprite.oy,sprite.mirror]
   [1,2].each do |selected|
    sprite.selected=selected
    25.times do |tick|
     sprite.update(tick%24);states << [index,back,selected,tick,sprite.instance_variable_get(:@spriteYExtra),sprite.visible]
    end
   end
   if !back && index%48==0;sprite.bitmap.to_file(File.join(directory,"battle-art-sample-#{index}.png"));end
   sprite.dispose
  end
  if index%128==0
   owner=GameData::Species.front_sprite_bitmap(id,nil,nil,true,true,true,120,0,1,2,[0,0,0,0,0,0,0,0,0,0],{},source)
   hues << [source,owner.width,owner.height];owner.dispose
  end
  if index%200==0;Graphics.update;File.open(log,'a'){ |f| f.puts("P3_BATTLE_ART_PROGRESS #{index}/#{rows.length}") };end
 end
 viewport.dispose
 scripts=['Data/Scripts/011_Battle/005_Battle scene/004_PokeBattle_SceneElements.rb','Data/Scripts/052_AddOns/FusionSprites.rb',
  'Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb','Data/Scripts/014_Pokemon/001_Pokemon.rb']
 doc={'status'=>'passed','inputs'=>inputs,'cases'=>cases,'selection_states'=>states,'representative_hues'=>hues,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All alternate/special/egg/joke/triple sources retained unchanged. Actual PokemonBattlerSprite custom-file override path, front/back scaling/mirroring, bottom-center origin and complete 24-update selection/target cycles. Species metadata from leading base number where valid, otherwise fixed species-1 compatibility fixture. This does not assert every triple/egg is mapped to that species or replace actual egg/hatching gameplay; source identity preserved byte-for-byte.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'battle-art-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P3_BATTLE_ART_PASS inputs=#{inputs.length} cases=#{cases.length} states=#{states.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P3_BATTLE_ART_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(9).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
