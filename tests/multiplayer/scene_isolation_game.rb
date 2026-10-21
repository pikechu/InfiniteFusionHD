# Actual Scene_Map + native message-window regression. No HTTP or combat result
# is fabricated: this fixture exercises the UI and lifetime boundary only.
passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test, directory = KIFMultiplayerFeatureTest, ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")
  $Trainer.party = [test.pokemon(:PIKACHU, [:TACKLE, :PROTECT])]
  $Trainer.save_slot = "Scene isolation regression"
  writer = KIFMultiplayer::TradeSave.new
  test.check(writer.persist, "isolated test save persisted")
  disk_path = File.expand_path(writer.path)
  test.check(disk_path.start_with?(File.expand_path(directory) + "/"), "save belongs to independent test profile")
  disk_sha = Digest::SHA256.hexdigest(File.binread(disk_path))
  map_scene = Scene_Map.new
  $scene = map_scene
  map_scene.createSpritesets
  original_globals, digest = test.globals, test.digest
  original_world = [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction]
  calls = {"miniupdate" => 0, "map.update" => 0, "player.update" => 0, "transfer_player" => 0}
  [[map_scene, :miniupdate, "miniupdate"], [$game_map, :update, "map.update"],
   [$game_player, :update, "player.update"], [map_scene, :transfer_player, "transfer_player"]].each do |object, method, label|
    original = object.method(method)
    object.define_singleton_method(method) do |*args|
      if $game_temp.in_battle
        calls[label] += 1
        raise "ORIGINAL_WORLD_UPDATED_DURING_BATTLE #{label}"
      end
      original.call(*args)
    end
  end
  original_trigger = Input.method(:trigger?)
  next_use = KIFMultiplayer.monotonic
  Input.define_singleton_method(:trigger?) do |button|
    if button == Input::USE && KIFMultiplayer.monotonic >= next_use
      next_use = KIFMultiplayer.monotonic + 0.18
      true
    else
      original_trigger.call(button)
    end
  end
  forbidden_transport = Object.new
  def forbidden_transport.call(*); raise "UI isolation fixture forbids HTTP"; end
  client = KIFMultiplayer::Client.new(nil, forbidden_transport)
  client.profile.account["identity"] = {"id" => "p_" + "a" * 24}
  document = {"id" => "b_" + "a" * 32, "host_id" => client.player_id, "players" => [client.player_id, "p_" + "b" * 24],
              "turn" => 1, "phase" => "commands", "mode" => "friendly_singles", "status" => "active"}
  stages = []
  check_restored = lambda do |name|
    test.check($scene.equal?(map_scene) && !$game_temp.in_battle, "#{name}: scene and battle flag restored")
    test.check(calls.values.all? { |count| count == 0 }, "#{name}: zero overworld callbacks")
    test.check(original_world == [$game_map.map_id, $game_player.x, $game_player.y, $game_player.direction], "#{name}: world position unchanged")
    test.check(digest == test.digest(original_globals) && original_globals.each_with_index.all? { |value, i| value.equal?(test.globals[i]) }, "#{name}: original six save globals unchanged")
    test.check(Digest::SHA256.hexdigest(File.binread(disk_path)) == disk_sha, "#{name}: original disk save SHA unchanged")
    stages << name
  end
  KIFMultiplayer::BattleIsolation.with do
    KIFMultiplayer::BattlePresentation.with(pbNewBattleScene) do
      session = KIFMultiplayer::BattleSession.new(client, document)
      def session.state
        {"kind" => "command", "phase_owner_ids" => [player_id], "actions" => {player_id => {"moves" => [], "switches" => [], "forced" => false}}}
      end
      def session.fetch; battle; end
      def session.heartbeat(*); end
      choice = KIFMultiplayer::BattleInput.choose(session)
      test.check(choice["action"] == "surrender", "actual host surrender confirmation completed")
    end
  end
  check_restored.call("host_surrender")
  KIFMultiplayer::BattleIsolation.with do
    KIFMultiplayer::BattlePresentation.with(pbNewBattleScene) do
      gym = KIFMultiplayerAIBattle.allocate
      test.check(gym.pbRunMenu(0), "actual Gym abandonment confirmation completed")
    end
  end
  check_restored.call("gym_confirm")
  session = KIFMultiplayer::BattleSession.new(client, document)
  def session.heartbeat(*); end
  old_update = proc { raise "OLD_WAIT_CALLBACK_EXECUTED" }
  client.wait_update = old_update
  begin
    KIFMultiplayer::GuestBattlePresenter.with(session) do
      session.message("Independent guest wait-message lifetime check.")
      raise "intentional guest UI interruption"
    end
  rescue RuntimeError => error
    raise unless error.message == "intentional guest UI interruption"
  end
  test.check(client.wait_update.equal?(old_update) && session.presenter.nil?, "guest callback/presenter restored")
  client.wait_update = nil
  check_restored.call("guest_message_exception")
  confirmation_windows = []
  [Window_AdvancedTextPokemon, Window_CommandPokemonEx].each do |klass|
    klass.prepend(Module.new do
      define_method(:initialize) do |*args|
        super(*args)
        confirmation_windows << self if $capture_confirmation_windows
      end
    end)
  end
  begin
    KIFMultiplayer::BattleIsolation.with do
      KIFMultiplayer::BattlePresentation.with(pbNewBattleScene) do
        terminal_confirmation = KIFMultiplayer::BattleSession.new(client, document)
        def terminal_confirmation.heartbeat(*); raise KIFMultiplayer::ServerTerminal; end
        $capture_confirmation_windows = true
        KIFMultiplayer.battle_confirm("Terminal heartbeat during confirmation.", terminal_confirmation)
      end
    end
  rescue KIFMultiplayer::ServerTerminal
    test.check(confirmation_windows.length == 2 && confirmation_windows.all?(&:disposed?), "terminal confirmation disposes both actual native windows")
  ensure
    $capture_confirmation_windows = false
  end
  check_restored.call("confirmation_terminal")
  begin
    KIFMultiplayer::BattleIsolation.with do
      KIFMultiplayer::BattlePresentation.with(pbNewBattleScene) { raise KIFMultiplayer::ServerTerminal }
    end
  rescue KIFMultiplayer::ServerTerminal
    stages << "terminal_propagated"
  end
  check_restored.call("server_terminal")
  File.write(File.join(directory, "scene-isolation-evidence.json"), KIFMultiplayer::WireJSON.dump({"pid" => Process.pid,
    "finished" => true, "actual_scene" => "Scene_Map", "stages" => stages, "world_callbacks" => calls,
    "save_path" => disk_path, "save_sha256" => disk_sha, "globals_unchanged" => true}))
  test.log("SCENE_ISOLATION_NATIVE_PASS stages=#{stages.length} overworld_calls=0")
  passed = true
rescue Exception => error
  $kif_test_log.call("SCENE_ISOLATION_NATIVE_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
