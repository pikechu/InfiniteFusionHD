# Native, isolated reproduction of Pewter Mart's clothing/hat stock and preview.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  module ShopLoadingProbe
    class << self; attr_accessor :active, :requests, :samples; end
    self.requests, self.samples = [], []
    def self.now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
    def self.measure(name)
      self.active = {"phase"=>name,"bitmap_resolves"=>0,"json_reads"=>0,"catalog_calls"=>0,"catalog_ms"=>0.0,"scroll_ms"=>0.0,"frames"=>0}
      started = now
      yield
      active["elapsed_ms"] = ((now-started)*1000).round(3)
      samples << active
      active
    ensure
      self.active = nil
    end
  end
  module ShopLoadingReads
    def read(path, *args, **kwargs, &block)
      if ShopLoadingProbe.active && path.to_s.match?(%r{Data/outfits/(?:hats_data|hairstyles_data|clothes_data)\.json\z})
        ShopLoadingProbe.active["json_reads"] += 1
      end
      super
    end
  end
  File.singleton_class.prepend(ShopLoadingReads)
  module ShopLoadingMethods
    def pbResolveBitmap(path)
      ShopLoadingProbe.active["bitmap_resolves"] += 1 if ShopLoadingProbe.active
      super
    end
    def update_global_outfit_lists
      started = ShopLoadingProbe.now
      super
    ensure
      if ShopLoadingProbe.active
        ShopLoadingProbe.active["catalog_calls"] += 1
        ShopLoadingProbe.active["catalog_ms"] += (ShopLoadingProbe.now-started)*1000
      end
    end
    def pbScrollMap(*args)
      started = ShopLoadingProbe.now
      super
    ensure
      ShopLoadingProbe.active["scroll_ms"] += (ShopLoadingProbe.now-started)*1000 if ShopLoadingProbe.active
    end
  end
  Object.prepend(ShopLoadingMethods)
  module ShopLoadingFrames
    def update(*args)
      ShopLoadingProbe.active["frames"] += 1 if ShopLoadingProbe.active
      super
    end
  end
  Graphics.singleton_class.prepend(ShopLoadingFrames)
  module ShopLoadingNetwork
    def http_get(*args)
      ShopLoadingProbe.requests << ["GET",args[0]]
      raise "Shop tried to download resources"
    end
    def http_post_body(*args)
      ShopLoadingProbe.requests << ["POST",args[0]]
      raise "Shop tried to contact the server"
    end
  end
  KIF::Platform.singleton_class.prepend(ShopLoadingNetwork)
  KIF::OfflineResources.define_singleton_method(:fetch) do |*args|
    ShopLoadingProbe.requests << ["fetch",args[0]]
    raise "Shop tried to download an offline asset"
  end
  $GameSpeed = 1
  KIFMultiplayer::OnlineMode.instance_variable_set(:@mode, :offline)
  {:@clothes=>STARTING_OUTFIT,:@hat=>nil,:@hair=>"3_"+DEFAULT_OUTFIT_MALE,
   :@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
  GameLanguage.load(2)
  $scene = Scene_Map.new
  $MapFactory.setup(382)
  $game_player.moveto(5,7)
  $game_player.turn_up
  $MapFactory.maps.each { |map| map.events.each_value { |event| event.erase if [3,4].include?(event.trigger) } }
  $scene.createSpritesets
  2.times { Graphics.update; Input.update; $scene.update }
  result = {"map"=>382,"runtime"=>RUBY_VERSION,"android"=>KIF::Platform.android?,"map_size"=>[$game_map.width,$game_map.height]}
  2.times do |iteration|
    [:CLOTHES,:HAT].each do |kind|
      stock = nil
      record = ShopLoadingProbe.measure("#{kind} stock #{iteration+1}") do
        selector = OutfitSelector.new
        ids = kind == :CLOTHES ? selector.generate_clothes_choice(true,[],["pewter"],[]) : selector.generate_hats_choice(true,[],["pewter"],[])
        stock = ids.filter_map { |id| kind == :CLOTHES ? get_clothes_by_id(id) : get_hat_by_id(id) }
      end
      record["stock_items"] = stock.length
      raise "No Pewter stock" if stock.empty?
      adapter = kind == :CLOTHES ? ClothesMartAdapter.new(stock,true) : HatsMartAdapter.new(stock,true)
      view = ClothesShopView.new
      ShopLoadingProbe.measure("#{kind} open #{iteration+1}") do
        view.pbStartBuyScene(stock,adapter)
        view.displayNewItem(view.instance_variable_get(:@sprites)["itemwindow"])
        Graphics.update
      end
      view.pbEndBuyScene
    end
  end
  raise "Network request from local shop" unless ShopLoadingProbe.requests.empty?
  result["samples"], result["network_requests"] = ShopLoadingProbe.samples, ShopLoadingProbe.requests
  name = ENV.fetch("KIF_SHOP_PROBE_LABEL", "shop-loading")
  output = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), name+".json")
  File.binwrite(output, KIFMultiplayer::WireJSON.dump(result))
  KIFMultiplayerFeatureTest.log("SHOP_LOADING_PASS #{output}")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("SHOP_LOADING_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
