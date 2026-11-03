directory=File.expand_path('output/texture-hd/p2-evidence/remaining');log=File.join(directory,'trainers-result.txt');passed=false
begin
 File.write(log,"TRAINERS_BEGIN\n");load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);$GameSpeed=1
 rows=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-remaining-work/scope.json'))['entries'].select { |r| r['source'].include?('/Trainers/') && r['size'][0]<r['size'][1]*2 }
 viewport=Viewport.new(0,0,512,384);viewport.z=99999
 scene=PokeBattle_Scene.allocate;scene.instance_variable_set(:@viewport,viewport);scene.instance_variable_set(:@sprites,{})
 captures=[];inputs={}
 rows.each do |row|
  source=row['source'];inputs[source]=Digest::SHA256.hexdigest(File.binread(source))
  scene.pbCreateTrainerFrontSprite(0,:POKEMONTRAINER_Red,1,source)
  trainer=scene.instance_variable_get(:@sprites)['trainer_1'];raise 'No trainer bitmap' unless trainer && trainer.bitmap
  raise 'Wrong trainer frame dimensions' unless [trainer.bitmap.width,trainer.bitmap.height]==row['size']
  Graphics.update;label="trainer-scene-#{File.basename(source,'.png')}"
  picture=Graphics.snap_to_bitmap;picture.to_file(File.join(directory,label+'.png'));picture.dispose
  captures << {'source'=>source,'label'=>label,'anchor'=>[trainer.x,trainer.y,trainer.ox,trainer.oy],'rect'=>[trainer.src_rect.x,trainer.src_rect.y,trainer.src_rect.width,trainer.src_rect.height]}
  pbDisposeSpriteHash(scene.instance_variable_get(:@sprites))
 end
 viewport.dispose
 scripts=['Data/Scripts/011_Battle/005_Battle scene/007_Scene_Initialize.rb','Data/Scripts/011_Battle/005_Battle scene/003_PokeBattle_SceneConstants.rb']
 doc={'status'=>'passed','inputs'=>inputs,'captures'=>captures,'script_sha256'=>scripts.to_h { |p| [p,Digest::SHA256.hexdigest(File.binread(p))] },
  'scope'=>'Every static trainer source through the actual pbCreateTrainerFrontSprite explicit sprite_override API at opponent battle coordinates; legacy sources are compatibility previews, not evidence of all event references. Existing player-back construction begins offscreen and is not a full battle entrance test.'}
 File.write(File.join(directory,'trainers-review.json'),KIFMultiplayer::WireJSON.dump(doc));File.open(log,'a'){ |f| f.puts("TRAINERS_PASS captures=#{captures.length}") };passed=true
rescue Exception => error
 File.open(log,'a'){ |f| f.puts("TRAINERS_FAIL #{error.class}: #{error.message.to_s[0,1400]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end
