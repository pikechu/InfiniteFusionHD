directory=File.expand_path('output/texture-hd/p2-evidence/remaining');log=File.join(directory,'ui-result.txt');passed=false
begin
 File.write(log,"UI_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-remaining-work/scope.json'))['entries'].select { |r| (104..107).include?(r['batch'][6..-1].to_i) }
 inputs={};renders=[];periods=[]
 [0,2].each do |language|
  GameLanguage.load(language);viewport=Viewport.new(0,0,512,384);viewport.z=99999
  rows.each do |row|
   source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source))
   bitmap=Bitmap.new(source);raise "Wrong size #{source}" unless [bitmap.width,bitmap.height]==row['size']
   sprite=Sprite.new(viewport);sprite.bitmap=bitmap
   Graphics.update;label="ui-#{language}-#{source.tr('/','_').sub(/\.[^.]+\z/,'')}"
   picture=Graphics.snap_to_bitmap;picture.to_file(File.join(directory,label+'.png'));picture.dispose
   renders << {'label'=>label,'source'=>source,'language'=>language,'size'=>row['size']};sprite.dispose;bitmap.dispose
  end
  rows.select { |r| r['batch'][6..-1].to_i>=106 }.each do |row|
   source=row['source'];plane=AnimatedPlane.new(viewport);plane.setPanorama(File.basename(source));plane.update
   w,h=row['size'];checks=[]
   [[0,0],[w,0],[0,h],[w,h],[w-1,h-1],[w+1,h+1]].each do |x,y|
    plane.ox=x;plane.oy=y;plane.update
    target=File.join(directory,'panorama-transient.png')
    begin
     plane.instance_variable_get(:@__sprite).bitmap.to_file(target)
     checks << [x,y,Digest::SHA256.hexdigest(File.binread(target))]
    ensure
     File.delete(target) if File.file?(target)
    end
   end
   raise "Plane period mismatch #{source}" unless checks[0][2]==checks[1][2] && checks[0][2]==checks[2][2] && checks[0][2]==checks[3][2]
   periods << {'source'=>source,'language'=>language,'checks'=>checks};plane.dispose
  end
  viewport.dispose
 end
 # Resource references from all current maps, tilesets and common/map events.
 tile=load_data('Data/Tilesets.rxdata');refs=[];event_strings={};map_hashes={}
 paths=Dir['Data/Map[0-9][0-9][0-9].rxdata']+['Data/CommonEvents.rxdata']
 walk=lambda do |value,path|
  case value
  when String
   event_strings[value] ||= [];event_strings[value] << path unless event_strings[value].include?(path)
  when Array;value.each { |v| walk.call(v,path) }
  when RPG::EventCommand;walk.call(value.parameters,path)
  end
 end
 paths.each do |path|
  data=load_data(path);map_hashes[path]=Digest::SHA256.hexdigest(File.binread(path))
  if data.is_a?(RPG::Map)
   tileset=tile[data.tileset_id];refs << [path,data.tileset_id,tileset.panorama_name,tileset.panorama_hue]
   data.events.each_value { |event| event.pages.each { |page| walk.call(page.list,path) } }
  else
   data.compact.each { |event| walk.call(event.list,path) }
  end
 end
 scripts=['Data/Scripts/005_Sprites/007_Spriteset_Map.rb','Data/Scripts/007_Objects and windows/009_Planes.rb',
  'Data/Scripts/052_AddOns/IntroScreen.rb','Data/Scripts/999_Main/999_Main.rb','Data/localization/zh-CN-images.json']
 doc={'status'=>'passed','inputs'=>inputs,'renders'=>renders,'panorama_periods'=>periods,'map_panorama_refs'=>refs,
  'event_resource_strings'=>event_strings,'map_sha256'=>map_hashes,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'46 unchanged files decoded/rendered in English and Chinese; 17 panorama layers through actual AnimatedPlane loader at six offsets including full width/height repeat seams. Existing batch-103 title interactive evidence covers current logo/selector consumers; compatibility splash/logo/form assets remain unchanged. No full startup or event playthrough claim.'}
 encoded=KIFMultiplayer::WireJSON.encode(doc,0);raise 'Diagnostic exceeds cap' if encoded.bytesize>49*1024*1024
 File.write(File.join(directory,'ui-review.json'),encoded);File.open(log,'a'){ |f| f.puts("UI_PASS images=#{inputs.length} renders=#{renders.length} plane_cases=#{periods.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("UI_FAIL #{error.class}: #{error.message.to_s[0,1200]}\n#{error.backtrace.first(7).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
