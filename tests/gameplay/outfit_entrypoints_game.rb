# Exercise every extracted stock profile and shared-city route without buying or saving.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  report = KIFMultiplayer::WireJSON.parse(File.binread(ENV.fetch("KIF_OUTFIT_AUDIT_REPORT")))
  uncovered = report["dynamic_profiles"].reject { |entry| entry["map"] == 565 && entry["event"] == 15 }
  raise "New dynamic outfit entries require an explicit regression case" unless uncovered.empty?
  module OutfitEntryProbe
    class << self; attr_accessor :record,:samples,:requests,:captures; end
    self.samples,self.requests,self.captures = [],[],[]
    def self.measure(name)
      self.record = {"name"=>name,"bitmap_resolves"=>0,"json_reads"=>0}
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = yield
      record["ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC)-started)*1000).round(3)
      samples << record
      value
    ensure
      self.record = nil
    end
  end
  module OutfitEntryReadProbe
    def read(path,*args,**kwargs,&block)
      OutfitEntryProbe.record["json_reads"] += 1 if OutfitEntryProbe.record && path.to_s.match?(%r{Data/outfits/[^/]+\.json\z})
      super
    end
  end
  File.singleton_class.prepend(OutfitEntryReadProbe)
  module OutfitEntryMethods
    def pbResolveBitmap(path)
      OutfitEntryProbe.record["bitmap_resolves"] += 1 if OutfitEntryProbe.record
      super
    end
    def genericOutfitsShopMenu(stock=[],type=nil,*args)
      OutfitEntryProbe.captures << {"type"=>type.to_s,"items"=>stock.map { |item| item.is_a?(Symbol) ? item.to_s : item.id }}
    end
    def openSelectOutfitMenu(stock=[],type)
      genericOutfitsShopMenu(stock,type)
    end
  end
  Object.prepend(OutfitEntryMethods)
  module OutfitEntryNetwork
    def http_get(*args); OutfitEntryProbe.requests << args[0]; raise "Unexpected outfit HTTP"; end
    def http_post_body(*args); OutfitEntryProbe.requests << args[0]; raise "Unexpected outfit HTTP"; end
  end
  KIF::Platform.singleton_class.prepend(OutfitEntryNetwork)
  KIF::OfflineResources.define_singleton_method(:fetch) { |*args| OutfitEntryProbe.requests << args[0]; raise "Unexpected outfit download" }
  {:@clothes=>STARTING_OUTFIT,:@hat=>nil,:@hair=>"3_"+DEFAULT_OUTFIT_MALE,
   :@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
  GameLanguage.load(2)
  resolve = lambda do |value|
    if value.is_a?(Hash) && value.keys == ["constant"]
      Object.const_get(value["constant"])
    elsif value.is_a?(Array)
      value.map { |child| resolve.call(child) }
    else value
    end
  end
  report["generator_profiles"].each_with_index do |profile,index|
    OutfitEntryProbe.measure("map:#{profile['map']} #{profile['kind']} profile:#{index}") do
      ids = OutfitSelector.new.send("generate_#{profile['kind']}_choice", *resolve.call(profile["args"]))
      getter = {"clothes"=>:get_clothes_by_id,"hats"=>:get_hat_by_id,"hairstyle"=>:get_hair_by_id}.fetch(profile["kind"])
      ids.each { |id| send(getter,id) }
    end
  end
  report["shared_mart_cities"].each do |city|
    [true,false].each do |defaults|
      $game_variables[VAR_CURRENT_MART] = city.to_sym
      OutfitEntryProbe.measure("shared clothes #{city} defaults:#{defaults}") { pokemart_clothes_shop(city.to_sym,defaults) }
      OutfitEntryProbe.measure("shared hats #{city} defaults:#{defaults}") { pokemart_hat_shop(defaults) }
    end
  end
  # Kin Hotel has dynamic leader switches and uses named-argument syntax.
  [[],[HAIR_CHUCK],[HAIR_JASMINE],[HAIR_CHUCK,HAIR_JASMINE]].each_with_index do |leaders,index|
    OutfitEntryProbe.measure("Kin Hotel dynamic profile:#{index}") do
      ids = OutfitSelector.new.generate_hairstyle_choice(baseOptions:true,additionalIds:leaders,additionalTags:["kin"],filterOutTags:[])
      ids.each { |id| get_hair_by_id(id) }
    end
  end
  $Trainer.unlocked_clothes = $PokemonGlobal.clothes_data.keys.first(8)
  $Trainer.unlocked_hats = $PokemonGlobal.hats_data.keys.first(8)
  OutfitEntryProbe.measure("wardrobe clothes") { changeClothesMenu }
  OutfitEntryProbe.measure("wardrobe hats") { changeHatMenu }
  OutfitEntryProbe.measure("direct clothes shop") { clothesShop($Trainer.unlocked_clothes) }
  OutfitEntryProbe.measure("direct hat shop") { hatShop($Trainer.unlocked_hats) }
  OutfitEntryProbe.measure("direct hair shop") { hairShop($PokemonGlobal.hairstyles_data.keys.first(8)) }
  record = OutfitEntryProbe.measure("silent outfit grants") do
    $PokemonGlobal.clothes_data.keys.first(3).each { |id| $Trainer.unlock_clothes(id,true) }
    $PokemonGlobal.hats_data.keys.first(3).each { |id| $Trainer.unlock_hat(id,true) }
    $PokemonGlobal.hairstyles_data.keys.first(3).each { |id| $Trainer.unlock_hair(id,true) }
  end
  raise "Grant route reparses warmed catalogs" unless OutfitEntryProbe.samples.last["json_reads"] == 0
  raise "Unrelated hair-version scans remain" unless OutfitEntryProbe.samples.all? { |sample| sample["bitmap_resolves"] == 0 }
  selector = OutfitSelector.new
  OutfitEntryProbe.measure("explicit clothes list") { selector.clothes_list }
  OutfitEntryProbe.measure("explicit hat list") { selector.hats_list }
  styles = OutfitEntryProbe.measure("explicit hairstyle list") { selector.hairstyles_list }
  reused = OutfitEntryProbe.measure("reuse explicit hairstyle list") { selector.hairstyles_list }
  raise "Hairstyle selection no longer reuses its discovered versions" unless reused.equal?(styles) && OutfitEntryProbe.samples.last["bitmap_resolves"] == 0
  raise "Outfit route entered HTTP" unless OutfitEntryProbe.requests.empty?
  result = {"runtime"=>RUBY_VERSION,"android"=>KIF::Platform.android?,"samples"=>OutfitEntryProbe.samples,"captures"=>OutfitEntryProbe.captures,"network_requests"=>OutfitEntryProbe.requests}
  path = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"),"outfit-entrypoints.json")
  File.binwrite(path,KIFMultiplayer::WireJSON.dump(result))
  KIFMultiplayerFeatureTest.log("OUTFIT_ENTRYPOINTS_NATIVE_PASS routes=#{OutfitEntryProbe.samples.length} network=0 output=#{path}")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("OUTFIT_ENTRYPOINTS_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
