directory=File.expand_path('output/texture-hd/p3-evidence/remaining');path=File.join(directory,'encoding-native-result.txt');passed=false
begin
 File.write(path,"ENCODING_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 source='Graphics/Pictures/Constellations/295.130a.png';bitmap=Bitmap.new(source)
 raise 'Wrong restored dimensions' unless [bitmap.width,bitmap.height]==[288,288]
 bitmap.to_file(File.join(directory,'encoding-native-pixels.png'));bitmap.dispose
 File.write(File.join(directory,'encoding-native-review.json'),KIFMultiplayer::WireJSON.dump({'status'=>'passed','source'=>source,
  'sha256'=>Digest::SHA256.hexdigest(File.binread(source)),'size'=>[288,288],'route_override'=>false}))
 File.open(path,'a'){ |f| f.puts('ENCODING_PASS actual_source_decodes_without_route_override') };passed=true
rescue Exception => error
 File.open(path,'a'){ |f| f.puts("ENCODING_FAIL #{error.class}: #{error.message.to_s[0,1500]}") }
ensure
 exit!(passed ? 0 : 1)
end
