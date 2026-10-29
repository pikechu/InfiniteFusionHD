phase=OUTFIT_PHASE
directory=File.expand_path('output/texture-hd/p2-evidence/region')
logfile=File.join(directory,"outfit-#{phase}-result.txt");passed=false
begin
 File.write(logfile,"OUTFIT_BEGIN phase=#{phase}\n")
 load 'scripts/multiplayer/test-bootstrap.rb'
 Graphics.resize_screen(512,384);$GameSpeed=1;srand(12345)
 $outfit_paths=KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p2-region-work/native-paths.json'))[phase]
 module OutfitBitmapRoute
  def initialize(*args)
   if args[0].is_a?(String)
    resolved=GameLanguage.bitmap_path(args[0]);key=File.expand_path(resolved).tr('\\','/').downcase.sub(/\.png\z/,'')
    args[0]=$outfit_paths.fetch(key,args[0])
   end
   super(*args)
  end
 end
 Bitmap.prepend(OutfitBitmapRoute)
 captures=[];layer_hashes={};anchors=[]
 [0,2].each do |language|
  GameLanguage.load(language);$Trainer.name=language==2 ? '测试训练师' : 'Texture';$Trainer.id=123456;$Trainer.money=12345
  $Trainer.badges=Array.new(16,true);$PokemonGlobal.startTime=Time.local(2026,10,29)
  [0,1].each do |gender|
   $Trainer.trainer_type=gender==0 ? :POKEMONTRAINER_Red : :POKEMONTRAINER_Leaf;$Trainer.character_ID=gender
   [gender==0 ? DEFAULT_OUTFIT_MALE : DEFAULT_OUTFIT_FEMALE,STARTING_OUTFIT].each do |outfit|
    # Initialize portrait fixture data without requiring a map spriteset callback.
    appearance={skin_tone:1,clothes:outfit,hair:getFullHairId(gender==0 ? 'red' : 'leaf',2),hat:nil,hair_color:0,clothes_color:0,hat_color:0}
    appearance.each { |key,value| $Trainer.instance_variable_set("@#{key}",value) }
    [getBaseTrainerSpriteFilename($Trainer.skin_tone),getTrainerSpriteOutfitFilename(outfit),getTrainerSpriteHairFilename($Trainer.hair)].each do |path|
     actual=pbResolveBitmap(path);raise "Missing real appearance layer #{path}" unless actual
     raise 'Temporary clothing fallback in fixture' if actual.include?('temp')
     layer_hashes[actual]=Digest::SHA256.hexdigest(File.binread(actual))
    end
    [false,true].each do |postgame|
     $game_switches[SWITCH_BEAT_THE_LEAGUE]=postgame
     scene=PokemonTrainerCard_Scene.new;Graphics.frame_count=0;scene.pbStartScene
     %w[GOLD BRONZE SILVER].each do |name|
      $Trainer.card_background=name;old=scene.instance_variable_get(:@sprites)['card'];scene.setCardBackground;old.dispose
      Graphics.frame_count=0;scene.pbDrawTrainerCardFront;scene.pbUpdate;Graphics.update
      label="outfit-#{language}-#{gender}-#{outfit}-#{postgame ? 1 : 0}-#{name}"
      image=Graphics.snap_to_bitmap;image.to_file(File.join(directory,"#{label}-#{phase}.png"));image.dispose
      captures << {'label'=>label,'kind'=>'card','source'=>"Graphics/Pictures/Trainer Card/backgrounds/#{name}.png"}
     end
     trainer=scene.instance_variable_get(:@sprites)['trainer']
     anchors << [language,gender,outfit,postgame,trainer.x,trainer.y,trainer.ox,trainer.oy,trainer.bitmap.width,trainer.bitmap.height]
     trainer.bitmap.to_file(File.join(directory,"outfit-avatar-#{language}-#{gender}-#{outfit}-#{postgame ? 1 : 0}-#{phase}.png"))
     scene.pbEndScene
    end
   end
  end
 end
 data={'captures'=>captures,'layer_sha256'=>layer_hashes,'anchors'=>anchors,'scope'=>'Real Red/Leaf and starting pajamas, body+clothes+hair layering in trainer-card portraits; no full overworld animation claim.'}
 File.write(File.join(directory,"outfit-#{phase}-review.json"),KIFMultiplayer::WireJSON.dump(data))
 File.open(logfile,'a') { |f| f.puts("OUTFIT_PASS phase=#{phase} captures=#{captures.length} layered_cases=#{anchors.length}") };passed=true
rescue Exception => error
 File.open(logfile,'a') { |f| f.puts("OUTFIT_FAIL #{error.class}: #{error.message.to_s[0,1500]}\n#{error.backtrace.first(8).join("\n")}") }
ensure
 exit!(passed ? 0 : 1)
end


