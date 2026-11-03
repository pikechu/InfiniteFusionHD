directory=File.expand_path('output/texture-hd/p5-evidence/remaining');log=File.join(directory,'reference-native-result.txt');passed=false
begin
 File.write(log,"P5_REFERENCE_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p5-work/remaining-native-index.json'),49*1024*1024,3000000)
 tokens=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p5-work/remaining-reference-tokens.json'),49*1024*1024,3000000)
 token_targets=tokens.to_h { |r| [r['pattern'].b,r['targets']] }
 regex=Regexp.new(File.binread('output/texture-hd/p5-work/remaining-reference-regex.txt'))
 normalize=lambda { |s| s.to_s.tr('\\','/').sub(/\.(png|gif|jpg|jpeg)\z/i,'').downcase }
 by_path=rows.to_h { |r| [normalize.call(r['source']),r['source']] }
 inputs=rows.to_h { |r| [r['source'],Digest::SHA256.hexdigest(File.binread(r['source']))] }
 hits=Hash.new { |h,k| h[k]=[] };counts=Hash.new(0);data_sha={};loaded=[];skipped=[];specialized=[];map_usage=Hash.new(0)
 Dir['Data/*.{dat,rxdata}'].sort.each do |path|
  bytes=File.binread(path);data_sha[path]=Digest::SHA256.hexdigest(bytes)
  if path=='Data/PkmnAnimations.rxdata' || File.basename(path).start_with?('messages')
   specialized << {'path'=>path,'method'=>path.include?('PkmnAnimations') ? 'Actual animation graphic/timing API' : 'Complete raw-byte scan of localized text catalog'};next
  end
  unless bytes.start_with?("\x04\x08".b)
   skipped << {'path'=>path,'reason'=>'Not a Marshal stream; raw-byte scan applies'};next
  end
  begin;object=load_data(path);loaded << path
  rescue Exception => error;skipped << {'path'=>path,'reason'=>"#{error.class}: #{error.message.to_s[0,160]}"};next
  end
  map_usage[object.tileset_id]+=1 if File.basename(path).match?(/\AMap\d+\.rxdata\z/) && object.respond_to?(:tileset_id)
  stack=[[object,'root']];seen={};nodes=0
  until stack.empty?
   value,trail=stack.pop;next if value.nil? || value.is_a?(Numeric) || value.equal?(true) || value.equal?(false)
   next if seen[value.object_id];seen[value.object_id]=true;nodes+=1;raise "Audit node cap #{path}" if nodes>3000000
   if value.is_a?(String) || value.is_a?(Symbol)
    text=value.to_s.b.downcase.tr('\\','/')
    text.scan(regex).uniq.each do |token|
     (token_targets[token] || []).each do |target|
      source=target['source'];counts[source]+=1
      if hits[source].length<12
       hits[source] << {'data'=>path,'location'=>trail,'role'=>target['role'],'token'=>token.force_encoding('UTF-8'),'value'=>value.to_s.encode('UTF-8',invalid: :replace,undef: :replace)[0,350]}
      end
     end
    end
   elsif value.is_a?(Array)
    value.each_with_index { |v,i| stack << [v,"#{trail}[#{i}]"] }
   elsif value.is_a?(Hash)
    value.each { |k,v| stack << [k,"#{trail}{key}"];stack << [v,"#{trail}{#{k.to_s[0,40]}}"] }
   else
    value.instance_variables.each { |iv| stack << [value.instance_variable_get(iv),"#{trail}.#{iv}"] }
   end
  end
 end
 declarations=[]
 load_data('Data/Tilesets.rxdata').each_with_index do |ts,id|
  next unless ts
  names=[['tileset','Graphics/Tilesets/'+ts.tileset_name.to_s]]+ts.autotile_names.map { |n| ['autotile','Graphics/Autotiles/'+n.to_s] }
  names.each do |kind,name|
   source=by_path[normalize.call(name)];next unless source
   declarations << {'source'=>source,'kind'=>kind,'tileset_id'=>id,'tileset_name'=>ts.name,'maps_using_tileset'=>map_usage[id]}
  end
 end
 animations=[]
 pbLoadBattleAnimations.each_with_index do |a,id|
  next unless a
  refs=[['atlas',a.graphic]]+a.timing.select { |t| [1,3].include?(t.timingType) }.map { |t| [t.timingType==1 ? 'background' : 'foreground',t.name] }
  refs.each do |role,name|
   source=by_path[normalize.call('Graphics/Animations/'+name.to_s)];next unless source
   patterns=[];a.length.times { |f| a[f].each { |c| patterns << c[AnimFrame::PATTERN] if c && c[AnimFrame::PATTERN] && c[AnimFrame::PATTERN]>=0 } }
   animations << {'source'=>source,'id'=>id,'name'=>a.name,'role'=>role,'frames'=>a.length,'nonnegative_patterns'=>patterns.uniq.sort}
  end
 end
 defaults=[]
 [1,4,7,25,94,133,150].each do |id|
  next unless File.file?("Graphics/BaseSprites/#{id}.png")
  filename=GameData::Species.sprite_filename(id)
  defaults << {'species'=>id,'resolved'=>filename,'source_collection_selected'=>filename.to_s.include?('96x96 sprites + assets')}
 end
 raise 'Unexpected default source collection routing' if defaults.any? { |r| r['source_collection_selected'] }
 scripts=['Data/Scripts/052_AddOns/FusionSprites.rb','Data/Scripts/052_AddOns/SpriteSheets.rb','Data/Scripts/001_Settings.rb',
  'Data/Scripts/011_Battle/005_Battle scene/007_Scene_Initialize.rb','Data/Scripts/006_Map renderer/001_TilemapRenderer.rb',
  'Data/Scripts/020_Debug/001_Editor screens/004_EditorScreens_SpritePositioning.rb']
 doc={'status'=>'passed','inputs'=>inputs,'source_reference_counts'=>counts,'serialized_reference_hits'=>hits,
  'serialized_files_inspected'=>loaded,'serialized_files_skipped'=>skipped,'specialized_data'=>specialized,
  'tileset_declarations'=>declarations,'battle_animation_declarations'=>animations,'default_sprite_paths'=>defaults,
  'data_sha256'=>data_sha,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'One relevant serialized-object traversal, exact qualified paths and separately labeled name hints, actual tileset/autotile declarations with map-use counts and actual animation atlas/background/foreground declarations. Ordinary base-sprite filename samples do not select the 96x96 artist-source folder. Raw-byte audit covers localized catalogs and unreadable legacy streams. Arbitrary external scripts, explicit custom-file overrides and pre-existing player save substitutions are not excluded; no map event command or save write was executed.'}
 File.write(File.join(directory,'reference-native-review.json'),KIFMultiplayer::WireJSON.encode(doc,0))
 File.open(log,'a'){ |f| f.puts("P5_REFERENCE_PASS files=#{inputs.length} serialized=#{loaded.length} referenced_sources=#{counts.length} tileset_declarations=#{declarations.length} animation_declarations=#{animations.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P5_REFERENCE_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
