directory=File.expand_path('output/texture-hd/p5-evidence/batch-817');log=File.join(directory,'native-result.txt');passed=false
begin
 File.write(log,"P5_817_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb';Graphics.resize_screen(512,384)
 scope=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p5-work/batch-817-scope.json'),49*1024*1024,3000000)
 rows=scope['entries'];inputs={};decoded=[];hits=[];ambiguous=[];data_sha={};loaded=[];skipped=[];specialized=[]
 tokens=rows.to_h do |r|
  source=r['source'];stem=source.sub(/\.png$/i,'').downcase
  values=[stem,stem.delete_prefix('graphics/')]
  values << File.basename(stem) unless source.include?('/backup/')
  [source,values]
 end
 # Recursively inspect serialized strings without executing map event commands.
 Dir['Data/*.{dat,rxdata}'].sort.each do |path|
  bytes=File.binread(path);data_sha[path]=Digest::SHA256.hexdigest(bytes)
  if path=='Data/PkmnAnimations.rxdata'
   specialized << {'path'=>path,'method'=>'Actual animation graphic/timing name API below; numeric cell arrays do not contain resource paths'};next
  end
  if File.basename(path).start_with?('messages')
   specialized << {'path'=>path,'method'=>'Localized text catalog covered by complete raw-byte token scan; not traversed as map event commands or animation resource declarations'};next
  end
  unless bytes.start_with?("\x04\x08".b)
   skipped << {'path'=>path,'reason'=>'Not a Ruby Marshal stream; separately covered by raw-byte token scan'};next
  end
  begin
   object=load_data(path);loaded << path
  rescue Exception => error
   skipped << {'path'=>path,'reason'=>"#{error.class}: #{error.message.to_s[0,160]}"};next
  end
  seen={};stack=[[object,'root']];nodes=0
  until stack.empty?
   value,trail=stack.pop;next if value.nil? || value.is_a?(Numeric) || value.equal?(true) || value.equal?(false) || value.is_a?(Symbol)
   next if seen[value.object_id];seen[value.object_id]=true;nodes+=1;raise "Serialized audit node cap #{path}" if nodes>3000000
   if value.is_a?(String)
    text=value.b.downcase.tr('\\','/')
    tokens.each do |source,patterns|
     next unless patterns.any? { |p| text.include?(p.b) }
     hits << {'source'=>source,'data'=>path,'location'=>trail,'value'=>value.encode('UTF-8',invalid: :replace,undef: :replace)[0,350]} if hits.length<1000
    end
    if text.include?('backup/') || text.include?('/backup')
     ambiguous << {'data'=>path,'location'=>trail,'value'=>value.encode('UTF-8',invalid: :replace,undef: :replace)[0,350]} if ambiguous.length<100
    end
   elsif value.is_a?(Array)
    value.each_with_index { |item,i| stack << [item,"#{trail}[#{i}]"] }
   elsif value.is_a?(Hash)
    value.each { |key,item| stack << [key,"#{trail}{key}"];stack << [item,"#{trail}{#{key.to_s[0,50]}}"] }
   else
    value.instance_variables.each { |iv| stack << [value.instance_variable_get(iv),"#{trail}.#{iv}"] }
   end
  end
 end
 animations=[];pbLoadBattleAnimations.each_with_index do |a,id|
  next unless a
  names=[a.graphic]+a.timing.map(&:name)
  rows.each do |row|
   next unless row['source'].start_with?('Graphics/Animations/')
   stem=File.basename(row['source'],'.png').downcase
   animations << {'source'=>row['source'],'id'=>id,'name'=>a.name,'frames'=>a.length} if names.compact.any? { |n| File.basename(n,'.png').downcase==stem }
  end
 end
 autotiles=[];tilesets=load_data('Data/Tilesets.rxdata')
 tilesets.each_with_index do |ts,id|
  next unless ts
  ts.autotile_names.each_with_index do |name,slot|
   autotiles << {'tileset'=>id,'slot'=>slot,'name'=>name} if name.to_s.downcase=='ocean-shore - copie'
  end
 end
 viewport=Viewport.new(0,0,512,384);rendered=[]
 rows.each_with_index do |row,index|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source));bitmap=Bitmap.new(source)
  raise "Dimensions #{source}" unless [bitmap.width,bitmap.height]==row['size']
  decoded << [source,bitmap.width,bitmap.height];bitmap.dispose
  next unless source.include?('/battlebg/backup/')
  scene=PokeBattle_Scene.allocate;scene.instance_variable_set(:@sprites,{});scene.instance_variable_set(:@viewport,viewport)
  scene.apply_backdrop_graphics(source,'Graphics/Battlebacks/playerbase/field','Graphics/Battlebacks/enemybase/field','Graphics/Battlebacks/default_message')
  Graphics.update
  if index%6==1
   shot=Graphics.snap_to_bitmap;shot.to_file(File.join(directory,"compatibility-background-#{index}.png"));shot.dispose
  end
  rendered << {'source'=>source,'fixture'=>'Actual backdrop composition with explicit archived image, field bases and default message; not evidence of ordinary map selection'}
  pbDisposeSpriteHash(scene.instance_variable_get(:@sprites))
 end
 viewport.dispose
 scripts=['Data/Scripts/011_Battle/005_Battle scene/007_Scene_Initialize.rb','Data/Scripts/007_Objects and windows/001_RPG_Cache.rb',
  'Data/Scripts/006_Map renderer/001_TilemapRenderer.rb']
 doc={'status'=>'passed','inputs'=>inputs,'decoded'=>decoded,'serialized_files_inspected'=>loaded,'serialized_files_skipped'=>skipped,
  'serialized_string_hits'=>hits,'serialized_files_specialized'=>specialized,'backup_path_mentions'=>ambiguous,'battle_animation_references'=>animations,'autotile_declarations'=>autotiles,
  'compatibility_backgrounds'=>rendered,'data_sha256'=>data_sha,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'All 48 images decode at fixed dimensions; archived backgrounds render through actual backdrop compositor using explicit overrides. Serialized data strings, actual animation graph names and autotile declarations are audited; no map event command is executed. Static/raw-byte code scan and decoded-pixel duplicate audit are separate evidence. Explicit archive rendering is not ordinary map selection, complete gameplay, move playback or autotile-seam certification.'}
 File.write(File.join(directory,'native-review.json'),KIFMultiplayer::WireJSON.encode(doc,0));File.open(log,'a'){ |f| f.puts("P5_817_PASS images=#{decoded.length} serialized=#{loaded.length} hits=#{hits.length} animation_refs=#{animations.length} autotile_refs=#{autotiles.length} backgrounds=#{rendered.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P5_817_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
