passed=false
begin
  load 'scripts/multiplayer/test-bootstrap.rb'
  test=KIFMultiplayerFeatureTest
  config=KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch('KIF_MULTIPLAYER_SCENARIO')))
  client=KIFMultiplayer::Client.new
  client.authenticate('login',config.fetch('username'),'NativeMainlineFixture123')
  cloud=KIFMultiplayer::CloudSession.new(client);cloud.open
  mode=KIFMultiplayer::OnlineMode
  mode.instance_variable_set(:@cloud,cloud);mode.instance_variable_set(:@mode,:online)
  mode.world=KIFMultiplayer::WorldSession.new(client,cloud.compatibility,cloud.session_id)
  test.check(cloud.available?('File A') && cloud.available?('File B'),'fresh device downloads both original and managed role slots')
  old=SaveData.read_from_file(SaveData.get_full_path('File B'))
  SaveData.mark_values_as_unloaded;Game.load(old)
  test.check(KIFMultiplayer::Mainline.active? && $Trainer.party.empty?,'fresh device refreshes current ownership before using downloaded party')
  test.check($Trainer.money==1900,'fresh device receives current wallet without replaying starter funds')
  test.check(SaveData.read_from_file(SaveData.get_full_path('File A'))[:player].name=='保留的休闲角色','fresh device retains original casual role independently')
  sdk=KIFMultiplayer::MainlineClient.new(client)
  second=sdk.create('另一个角色',0,'SQUIRTLE')
  test.check(second['party'].empty? && second['wallet']['balance']==1900,'new role on a fresh device cannot receive starter or funds again')
  cloud.close
  checks=File.readlines(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'feature-smoke.log')).grep(/PASS /).map { |line| line.split('PASS ',2)[1].strip }
  test.marker(File.join(config.fetch('directory'),'mainline-restore-pass.json'),{'passed'=>true,'pid'=>Process.pid,'checks'=>checks})
  passed=true
rescue Exception=>error
  File.write(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'mainline-error.log'),"#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
ensure
  exit!(passed ? 0 : 1)
end
