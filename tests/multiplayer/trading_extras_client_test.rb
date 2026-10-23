# Extension validation and menu cancellation; real HTTP/native proof is separate.
previous=ENV['KIF_TRADE_FIXTURES_ONLY'];ENV['KIF_TRADE_FIXTURES_ONLY']='1'
load File.expand_path('trade_test.rb',__dir__)
ENV['KIF_TRADE_FIXTURES_ONLY']=previous
load 'Data/Scripts/054_Multiplayer/010_Collections.rb'
load 'Data/Scripts/054_Multiplayer/021_TradingClient.rb'
load 'Data/Scripts/054_Multiplayer/022_TradingUI.rb'
load 'Data/Scripts/054_Multiplayer/017_OnlineClient.rb'
load 'Data/Scripts/054_Multiplayer/018_World.rb'
load 'Data/Scripts/054_Multiplayer/029_TradingExtras.rb'
GameData::Item.define_singleton_method(:exists?) { |id| id.to_s=='POTION' || GameData::TradeRegistry.exists?(id) }

class ExtrasFixtureClient
  attr_accessor :value
  attr_reader :reads,:writes
  def initialize;@reads=[];@writes=[];end
  def player_id;'p_reader';end
  def server;'http://127.0.0.1:18812';end
  def token;'fixture';end
  def compatibility;{'protocol'=>2};end
  def request(method,path,body=nil);@writes<<[method,path,body];@value;end
  def raw_request(method,path,body);@reads<<[method,path,body];@value;end
end
checks=0
check=lambda do |value,name|
  raise name unless value
  checks+=1;puts "PASS #{name}"
end
reject=lambda do |name,&block|
  begin;block.call;raise 'Expected rejection';rescue KIFMultiplayer::Error;end
  checks+=1;puts "PASS #{name}"
end
client=ExtrasFixtureClient.new;sdk=KIFMultiplayer::TradingExtrasClient.new(client)
contract={'id'=>'ctr_fixture','owner_id'=>'p_seller','kind'=>'auction','status'=>'open','revision'=>1,'terms'=>{'start_price'=>100,'increment'=>1},'compatibility'=>client.compatibility,'created_at'=>1000,'expires_at'=>2000,'server_time'=>1500,'bid'=>0}
check.call(sdk.validate_contract(contract)==contract,'contract validates installed kind status revision and timestamps')
reject.call('unsupported contract kind rejected') { sdk.validate_contract(contract.merge('kind'=>'upload_attributes')) }
reject.call('nonfinite contract clock rejected') { sdk.validate_contract(contract.merge('expires_at'=>Float::INFINITY)) }
reject.call('negative contract revision rejected') { sdk.validate_contract(contract.merge('revision'=>-1)) }
client.value={'ok'=>true,'contracts'=>[contract],'next_cursor'=>nil}
check.call(sdk.contracts('auction')['contracts'].length==1 && client.writes.empty?,'contract search uses readonly transport without economic write')
client.value={'ok'=>true,'contract'=>contract.merge('revision'=>2,'bid'=>200)}
sdk.contract_action(contract,'bid',{'amount'=>200})
payload=client.writes.last
check.call(payload[1].end_with?('/ctr_fixture/bid') && payload[2]['revision']==1 && payload[2]['amount']==200,'bid submits inspected revision and exact amount')
client.value={'ok'=>true,'contract'=>contract.merge('id'=>'ctr_other')}
reject.call('contract detail cannot substitute another contract') { sdk.contract('ctr_fixture') }
client.value={'ok'=>true,'history'=>[{'day'=>100,'open'=>10,'close'=>10,'low'=>10,'high'=>10,'quantity'=>3,'total'=>30,'trades'=>1,'weighted_average'=>10}],'trades'=>1,'sufficient_sample'=>false,'truncated'=>false}
check.call(sdk.history('item','POTION')['history'][0]['total']==30,'history validates executed volume and integer weighted average')
client.value['history'][0]['weighted_average']=999
reject.call('misleading history average rejected') { sdk.history('item','POTION') }
mail={'id'=>'mail_fixture','sender_id'=>'p_sender','recipient_id'=>client.player_id,'status'=>'pending','subject'=>'测试','text'=>'正文','bundle'=>{'asset_ids'=>[],'items'=>{'POTION'=>2},'coins'=>200}}
client.value={'ok'=>true,'mail'=>[mail]}
check.call(sdk.mail.length==1,'mail validates personal ownership and conserved attachment quantities')
mail['recipient_id']='p_other'
reject.call('mail belonging to other participants rejected') { sdk.mail }
mail['recipient_id']=client.player_id;mail['bundle']['coins']=-1
reject.call('negative mail coin attachment rejected') { sdk.mail }

item={'id'=>'lst_partial','seller_id'=>'p_seller','asset_id'=>'itm_POTION','kind'=>'item','item_id'=>'POTION','item'=>{'id'=>'POTION','name'=>'Potion'},'quantity'=>10,'unit_price'=>100,'price'=>1000,'fee'=>100,'currency'=>'LINK','revision'=>1,'status'=>'active','compatibility'=>client.compatibility}
client.value={'ok'=>true,'order'=>{'id'=>'ord_partial','listing_id'=>item['id'],'asset_id'=>item['asset_id'],'buyer_id'=>client.player_id,'price'=>300,'quantity'=>3}}
KIFMultiplayer::TradingClient.new(client).buy(item,3)
check.call(client.writes.last[2]['price']==300 && client.writes.last[2]['quantity']==3,'partial purchase signs the chosen quantity and its total')
reject.call('partial purchase above remaining stock rejected') { KIFMultiplayer::TradingClient.new(client).buy(item,11) }
world=KIFMultiplayer::WorldSession.new(client,client.compatibility)
base={'players'=>[],'messages'=>[],'map_key'=>nil,'cursor'=>0,'market_unread'=>5}
check.call(world.validate_world(base)['market_unread']==5,'world accepts bounded unread market notification badge')
reject.call('negative unread badge rejected') { world.validate_world(base.merge('market_unread'=>-1)) }

module KIFMultiplayer
  class UI
    def initialize(*args);end
    def enter(*args);'';end
    def perform;yield;end
  end
end
ui=KIFMultiplayer::TradingExtrasUI.new(client)
ui.define_singleton_method(:choose) { |_title,choices| choices.length }
ui.main
client.value={'ok'=>true,'contracts'=>[],'next_cursor'=>nil};ui.contract_market('auction')
check.call(true,'extension home and contract list honor cancel sentinels')
puts "TRADING_EXTRAS_CLIENT_TEST_PASS checks=#{checks}"
