directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'window-probe-result.txt');passed=false
begin
 File.write(log,"WINDOW_PROBE_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 source='Graphics/Windowskins/Windowskin.PNG';result={'source'=>source,'exists'=>File.file?(source),'resolve_full'=>pbResolveBitmap(source),'resolve_stem'=>pbResolveBitmap(source.sub(/\.[^.]+\z/,'')),'cases'=>[]}
 [source,File.expand_path(source),source.sub(/\.[^.]+\z/,'')].each do |path|
  entry={'path'=>path}
  begin
   bitmap=Bitmap.new(path);entry['direct_size']=[bitmap.width,bitmap.height];bitmap.dispose
  rescue Exception => e
   entry['direct_error']="#{e.class}: #{e.message}"
  end
  begin
   bitmap=AnimatedBitmap.new(path);entry['animated_size']=[bitmap.width,bitmap.height];bitmap.dispose
  rescue Exception => e
   entry['animated_error']="#{e.class}: #{e.message}"
  end
  result['cases'] << entry
 end
 File.write(File.join(directory,'window-probe.json'),KIFMultiplayer::WireJSON.dump(result));passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("FAIL #{error.class}: #{error.message.to_s[0,1500]}") }
ensure
 exit!(passed ? 0 : 1)
end
