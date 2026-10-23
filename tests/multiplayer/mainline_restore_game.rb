passed=false
begin
  load 'scripts/multiplayer/test-bootstrap.rb'
  test=KIFMultiplayerFeatureTest
  module PBDebug
    def self.logonerr;yield;end
  end
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
  test.check($game_variables[88]==12345,'Windows restores managed story progress written by Android') if config['roundtrip']
  if $scene.is_a?(Scene_Map)
    $scene.createSpritesets unless $scene.map_renderer
    8.times { Graphics.update;Input.update;$scene.updateSpritesets }
    bitmap=Graphics.snap_to_bitmap;bitmap.to_file(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'managed-restore.png'));bitmap.dispose
    test.check(!!$scene.map_renderer,'restored managed role renders the actual game map')
  end
  test.check(SaveData.read_from_file(SaveData.get_full_path('File A'))[:player].name=='保留的休闲角色','fresh device retains original casual role independently')
  sdk=KIFMultiplayer::MainlineClient.new(client)
  unless config['roundtrip']
    second=sdk.create('另一个角色',0,'SQUIRTLE')
    test.check(second['party'].empty? && second['wallet']['balance']==1900,'new role on a fresh device cannot receive starter or funds again')
  end
  if config['cross_device']
    $game_variables[88]=12345
    KIFMultiplayer::TradeSave.new.persist
    cloud.queue_save($Trainer.save_slot,SaveData.compile_save_hash)
    test.check(cloud.flush,'Android uploads the managed role to its own cloud slot')
  end
  cloud.close
  checks=File.readlines(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'feature-smoke.log')).grep(/PASS /).map { |line| line.split('PASS ',2)[1].strip }
  test.marker(File.join(config.fetch('directory'),'mainline-restore-pass.json'),{'passed'=>true,'pid'=>Process.pid,'checks'=>checks})
  passed=true
rescue Exception=>error
  File.write(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'mainline-error.log'),"#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
ensure
  exit!(passed ? 0 : 1)
end
