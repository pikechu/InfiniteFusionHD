directory=File.expand_path('output/texture-hd/p4-evidence');log=File.join(directory,'balls-result.txt');passed=false
begin
 File.write(log,"P4_BALLS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb';Graphics.frame_rate=40;$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['source'].start_with?('Graphics/Battle animations/ball_') }
 viewport=Viewport.new(0,0,512,384);inputs={};cases=[];compatibility=[]
 rows.each { |r| inputs[r['source']]=Digest::SHA256.hexdigest(File.binread(r['source'])) }
 rows.reject { |r| r['source'].include?('_open') }.each do |row|
  id=File.basename(row['source'],'.png').delete_prefix('ball_');open_path="Graphics/Battle animations/ball_#{id}_open.png"
  unless File.file?(open_path)
   compatibility << {'source'=>row['source'],'issue'=>'Alternate/credited sheet without a matching named open sheet; directly decoded and retained without claiming an item binding.'};next
  end
  owner=PokeBattle_Animation.new({},viewport);owner.extend(PokeBattle_BallAnimationMixin)
  ball=owner.addBallSprite(40,240,id.to_sym)
  owner.createBallTrajectory(ball,0,16,40,240,256,40,400,160)
  owner.ballOpenUp(ball,20,id.to_sym,true,false);owner.ballSetClosed(ball,35,id.to_sym)
  sprite=owner.instance_variable_get(:@ballSprite);trace=[];closed_cells=[];opened=false;ticks=0
  until owner.animDone?
   owner.update;ticks+=1;raise 'Ball animation timeout' if ticks>200
   r=sprite.src_rect;b=sprite.bitmap
   raise 'Ball crop outside bitmap' unless r.x>=0 && r.y>=0 && r.x+r.width<=b.width && r.y+r.height<=b.height
   raise 'Ball crop size' unless r.width==row['size'][1]/2 && r.height==row['size'][1]
   if b.width==row['size'][0] && b.width>=b.height
    closed_cells << r.x/r.width
   else
    opened=true
   end
   trace << [r.x,r.y,r.width,r.height,sprite.x,sprite.y,sprite.angle,sprite.zoom_x,sprite.zoom_y,b.width,b.height]
  end
  expected=(0...(2*row['size'][0]/row['size'][1])).to_a
  raise "Incomplete ball tumble #{id}" unless closed_cells.uniq.sort==expected
  raise "Ball did not open #{id}" unless opened
  raise 'Ball did not close/reset' unless sprite.bitmap.width==row['size'][0] && sprite.src_rect.x==0 && sprite.angle==0
  cases << {'source'=>row['source'],'open_source'=>open_path,'closed_cells'=>closed_cells.uniq,'updates'=>ticks,'trace_sha256'=>Digest::SHA256.hexdigest(Marshal.dump(trace))}
  owner.dispose
 end
 viewport.dispose
 scripts=['Data/Scripts/011_Battle/005_Battle scene/001_PokeBattle_Animation.rb','Data/Scripts/005_Sprites/011_PictureEx.rb']
 doc={'status'=>'passed','inputs'=>inputs,'cases'=>cases,'compatibility_issues'=>compatibility,
  'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'Actual addBallSprite, createBallTrajectory/Tumbling, ballOpenUp and ballSetClosed run via PokeBattle_Animation/PictureEx at 40fps. Each paired named sheet covers every tumble cell, open and closed transitions, crop bounds and reset. Alternate credited/variant sheets remain directly decoded compatibility sources. No capture probability, complete battler absorption, sound, battle outcome or Ballburst effect is certified.'}
 File.write(File.join(directory,'balls-review.json'),KIFMultiplayer::WireJSON.encode(doc,0));File.open(log,'a'){ |f| f.puts("P4_BALLS_PASS inputs=#{inputs.length} pairs=#{cases.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("P4_BALLS_FAIL #{error.class}: #{error.message.to_s[0,1600]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
