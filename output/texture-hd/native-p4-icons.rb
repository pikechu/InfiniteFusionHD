directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'icons-result.txt');passed=false
begin
 File.write(log,"P4_ICONS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000)
 rows=rows.select { |r| %w[icons footprint].include?(r['stage']) }
 module P4IconPaths
  def icon_filename_from_pokemon(*args);return $p4_pokemon_icon if $p4_pokemon_icon;super;end
  def shadow_bitmap_from_pokemon(*args);return AnimatedBitmap.new($p4_shadow) if $p4_shadow;super;end
 end
 GameData::Species.singleton_class.prepend(P4IconPaths)
 module P4ItemPaths
  def icon_filename(*args);return $p4_item_icon if $p4_item_icon;super;end
 end
 GameData::Item.singleton_class.prepend(P4ItemPaths)
 $PokemonSystem.kuraybigicons=0;$PokemonSystem.shiny_icons_kuray=0
 pokemon=Pokemon.new(1,30,$Trainer);pokemon.shiny=false
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 inputs={};cycles=[];items=[];static=[];shadows=[];exceptions=[]
 preview=Bitmap.new(1024,768);preview.fill_rect(0,0,1024,768,Color.new(53,60,70))
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Dimensions #{source}" unless [bitmap.width,bitmap.height]==row['size']
  w,h=row['size'];bitmap.dispose
  if row['stage']=='icons' && source !~ %r{/Eggs/} && (w>h || source =~ %r{/Pokemon/Icons/})
   $p4_pokemon_icon=source;pokemon.hp=pokemon.totalhp
   sprite=PokemonIconSprite.new(pokemon,viewport);sprite.x=120;sprite.y=160;sprite.setOffset(PictureOrigin::Center)
   count=[w/h,1].max
   raise "Icon crop #{source}" unless [sprite.src_rect.width,sprite.src_rect.height]==[h,h]
   exceptions << {'source'=>source,'issue'=>'Current square-cell loader ignores the remaining right-side pixels','remainder'=>w%h} if w%h!=0
   [pokemon.totalhp,[pokemon.totalhp/2,1].max,[pokemon.totalhp/4,1].max,0].each do |hp|
    pokemon.hp=hp
    [false,true].each do |selected|
     sprite.selected=selected;sprite.instance_variable_set(:@counter,0);sprite.instance_variable_set(:@currentFrame,0)
     limit=sprite.counterLimit;period=limit==0 ? 1 : limit*count;trace=[]
     period.times do
      sprite.update;frame=sprite.instance_variable_get(:@currentFrame);inner=sprite.instance_variable_get(:@sprite)
      raise 'Icon anchor' unless inner.x==120+(selected ? 4 : 0) && inner.y==160+(selected ? (frame>=count/2 ? -2 : 6) : 0)
      raise 'Icon frame crop' unless sprite.src_rect.x==frame*h
      trace << frame
     end
     raise 'Icon did not return to first cell' unless trace.last==0
     raise 'Icon skipped a cell' unless trace.uniq.sort==(hp==0 ? [0] : (0...count).to_a)
     cycles << [source,hp,selected,count,limit,period,trace.uniq]
    end
   end
   if index<64
    preview.blt((index%16)*64,(index/16)*80,sprite.bitmap,Rect.new(0,0,h,h))
   end
   sprite.dispose;$p4_pokemon_icon=nil
  elsif row['stage']=='icons' && h==48
   $p4_item_icon=source;sprite=ItemIconSprite.new(120,160,:POTION,viewport)
   sprite.setOffset(PictureOrigin::Center);sprite.update
   raise 'Item origin/crop' unless sprite.src_rect.width==48 && sprite.src_rect.height==48 && sprite.ox==24 && sprite.oy==24
   items << [source,sprite.width,sprite.height,sprite.src_rect.x,sprite.src_rect.y];sprite.dispose;$p4_item_icon=nil
  elsif source.include?('/Shadow/')
   $p4_shadow=source;sprite=PokemonBattlerShadowSprite.new(viewport,1,1);sprite.setPokemonBitmap(pokemon);sprite.update
   raise 'Shadow origin' unless [sprite.ox,sprite.oy]==[w/2,h/2]
   shadows << [source,sprite.x,sprite.y,sprite.ox,sprite.oy];sprite.dispose;$p4_shadow=nil
  else
   static << [source,w,h]
  end
  if index%250==0;Graphics.update;File.open(log,'a'){ |f| f.puts("P4_ICONS_PROGRESS #{index}/#{rows.length}") };end
 end
 preview.to_file(File.join(directory,'icons-native-preview.png'));preview.dispose;viewport.dispose
 scripts=['Data/Scripts/013_Items/007_Item_Sprites.rb','Data/Scripts/014_Pokemon/001_Pokemon-related/003_Pokemon_Sprites.rb',
  'Data/Scripts/010_Data/002_PBS data/006_Item.rb','Data/Scripts/010_Data/002_PBS data/009_Species_Files.rb',
  'Data/Scripts/011_Battle/005_Battle scene/004_PokeBattle_SceneElements.rb','Data/Scripts/007_Objects and windows/008_AnimatedBitmap.rb']
 doc={'status'=>'passed','inputs'=>inputs,'icon_cycles'=>cycles,'item_cases'=>items,'static_sources'=>static,'shadow_cases'=>shadows,
  'compatibility_issues'=>exceptions,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All P4 icon/footprint/shadow images decode at original dimensions. Actual PokemonIconSprite crop/HP timing/selection anchor/full cell cycles and ItemIconSprite center-origin paths use explicit source overrides on one baseline species/item; this is not proof of every species or item binding. Five current shadow assets use the real shadow compositor. Legacy numeric footprints and non-icon egg/bag assets are unchanged static compatibility sources, not claimed as animated or mapped to current named resolver paths. Egg crack sequencing is deferred to the animation audit.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Report exceeds 49MiB' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'icons-review.json'),encoded);File.open(log,'a'){ |f| f.puts("P4_ICONS_PASS sources=#{inputs.length} cycles=#{cycles.length} items=#{items.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_ICONS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 $p4_item_icon=$p4_pokemon_icon=$p4_shadow=nil
 exit!(passed ? 0 : 1)
end
