ENV['KIF_TRADE_FIXTURES_ONLY']='1'
load File.expand_path('trade_test.rb',__dir__)
load 'Data/Scripts/054_Multiplayer/010_Collections.rb'
load 'Data/Scripts/054_Multiplayer/021_TradingClient.rb'
load 'Data/Scripts/054_Multiplayer/024_MainlineClient.rb'
class MainlineFixtureTransport
  attr_accessor :response,:lose
  attr_reader :writes
  def initialize;@writes=0;end
  def call(method,url,body,token,timeout)
    value=if url.include?('/operations/')
      {'ok'=>true,'status'=>'completed','http_status'=>202,'response'=>@committed}
    elsif method=='POST'
      @writes+=1;@committed=@response
      if @lose;@lose=false;raise IOError,'native response lost after commit';end
      @response
    elsif url.include?('/jobs/')
      {'ok'=>true,'job'=>@response['job'].merge('status'=>'completed','result'=>{'asset_ids'=>['pkm_native']})}
    else;@response
    end
    {status:200,body:KIFMultiplayer::WireJSON.dump(value)}
  end
end
checks=0
assert=lambda { |value,name| raise "MAINLINE_CLIENT_FAIL #{name}" unless value;checks+=1;puts "PASS #{name}" }
reject=lambda do |name,&block|
  begin;block.call;rescue KIFMultiplayer::Error;assert.call(true,name);else;raise "MAINLINE_CLIENT_FAIL accepted #{name}";end
end
profile=KIFMultiplayer::Profile.new(File.join(TRADE_TEST_DIR,'mainline-profile.json'))
profile.account.merge!('identity'=>{'id'=>'p_native','nickname'=>'Native'},'token'=>'test-only','connected'=>true)
profile.save
transport=MainlineFixtureTransport.new;client=KIFMultiplayer::Client.new(profile,transport)
sdk=KIFMultiplayer::MainlineClient.new(client)
wallet={'owner_id'=>client.player_id,'currency'=>'LINK','balance'=>1000,'available'=>1000,'reserved'=>0,'version'=>1}
asset={'id'=>'pkm_native','owner_id'=>client.player_id,'source'=>'server_managed','catalog_version'=>1,'version'=>1,'snapshot'=>trade_test_snapshot(100)['pokemon'],'full'=>trade_test_snapshot(100)}
role={'id'=>'chr_native','owner_id'=>client.player_id,'name'=>'Online','revision'=>1,'party'=>[asset],'wallet'=>wallet}
assert.call(sdk.validate_character(role)==role,'role validates complete authoritative party and wallet')
reject.call('other account role rejected') { sdk.validate_character(role.merge('owner_id'=>'p_other')) }
reject.call('duplicate party identity rejected') { sdk.validate_character(role.merge('party'=>[asset,asset])) }
reject.call('party without complete data rejected') { sdk.validate_character(role.merge('party'=>[asset.reject { |key,_| key=='full' }])) }
reject.call('negative asset version rejected') { sdk.validate_asset(asset.merge('version'=>-1)) }
job={'id'=>'job_native','character_id'=>'chr_native','operation'=>'train','status'=>'queued'}
transport.response={'ok'=>true,'job'=>job};transport.lose=true
reject.call('uncertain native submission retains original intent') { sdk.submit('/v1/mainline/characters/chr_native/jobs',{'operation'=>'train'}) }
saved=KIFMultiplayer::Profile.new(profile.path)
assert.call(saved.account['mainline_intent'] && saved.account['pending'],'both intent and network journal are durable')
restored=KIFMultiplayer::Client.new(saved,transport)
result=KIFMultiplayer::MainlineClient.new(restored).recover
assert.call(result['status']=='completed' && transport.writes==1,'new client recovers original job without submitting it twice')
assert.call(!saved.account['mainline_intent'] && !saved.account['pending'],'completed recovery clears both journals')
puts "MAINLINE_CLIENT_TEST_PASS checks=#{checks}"
