directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'inspect-result.txt');passed=false
begin
 File.write(log,"P4_INSPECT_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 animations=pbLoadBattleAnimations
 records=[]
 animations.each_with_index do |a,i|
  next unless a
  patterns=[]
  a.length.times do |frame|
   a[frame].each { |cel| patterns << cel[AnimFrame::PATTERN] if cel && cel[AnimFrame::PATTERN] && cel[AnimFrame::PATTERN]>=0 }
  end
  records << {'id'=>i,'name'=>a.name,'graphic'=>a.graphic,'hue'=>a.hue,'frames'=>a.length,
   'patterns'=>patterns.uniq.sort,'timings'=>a.timing.map { |t| {'frame'=>t.frame,'type'=>t.timingType,'name'=>t.name} }}
 end
 weathers=[];GameData::Weather.each { |w| weathers << {'id'=>w.id.to_s,'graphics'=>w.graphics} }
 gif=Bitmap.new('Graphics/Animated Sprites/gifs/137.94.gif')
 gif_info={'methods'=>gif.methods.grep(/frame|play|loop|goto/).map(&:to_s).sort,'size'=>[gif.width,gif.height],
  'animated'=>gif.animated?,'frame_count'=>gif.frame_count,'frame_rate'=>gif.frame_rate,'current_frame'=>gif.current_frame}
 gif.dispose
 data_paths=%w[Data/PkmnAnimations.rxdata Data/move2anim.dat Data/Animations.rxdata]
 doc={'status'=>'passed','animations'=>records,'weathers'=>weathers,'gif_api'=>gif_info,
  'data_sha256'=>data_paths.select { |p| File.file?(p) }.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'serialized_animated_directory_mentions'=>Dir['Data/*.{dat,rxdata}'].select { |p| File.binread(p).include?('Animated Sprites') }}
 File.write(File.join(directory,'native-inspection.json'),KIFMultiplayer::WireJSON.encode(doc,0))
 File.open(log,'a'){ |f| f.puts("P4_INSPECT_PASS animations=#{records.length} weather=#{weathers.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_INSPECT_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(7).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
