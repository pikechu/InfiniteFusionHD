begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  baseline = test.digest
  client = KIFMultiplayer::Client.new
  client.authenticate("login", "original_game", "OriginalNativeFixture123")
  controlled = KIFMultiplayer::ControlledClient.new(client).refresh
  character = controlled.characters.find { |entry| entry["rules_mode"] == "original" }
  test.check(!!character, "ORIGINAL_GAME_ROLE_DISCOVERED")
  model = KIFMultiplayer::OriginalClient.new(client).refresh(character["id"])
  ui = KIFMultiplayer::OriginalUI.new(client)
  ui.current_model = model
  input_singleton = class << Input; self; end
  input_singleton.alias_method(:original_fixture_trigger, :trigger?)
  input_singleton.define_method(:trigger?) { |key| key == Input::USE || original_fixture_trigger(key) }
  KIFMultiplayer::OriginalPresentation.with do
    renderer = KIFMultiplayer::OriginalWorldRenderer.new
    begin
      renderer.adopt(model.original["view"], model.character)
      8.times { renderer.update; Graphics.update }
      image = Graphics.snap_to_bitmap
      image.to_file(File.join($kif_test_directory, "original-map.png"))
      image.dispose
      test.check(model.original["view"]["world"]["map_id"] == 77, "ORIGINAL_GAME_NATIVE_MAP_DRAWN")
      fixture_dir = ENV.fetch("KIF_ORIGINAL_FIXTURE_DIRECTORY")
      fixture = KIFMultiplayer::WireJSON.parse(File.read(File.join(fixture_dir, "natural.json")))
      fixture["rival_approach"].each do |direction|
        break if model.original["prompt"]
        until_time = KIFMultiplayer.monotonic + 0.3
        client.pump while KIFMultiplayer.monotonic < until_time
        result = model.act("move", {"direction" => direction})
        renderer.adopt(model.original["view"], model.character)
        break if model.original["prompt"]
      end
      test.check(!!model.original["view"]["battle"], "ORIGINAL_GAME_NATIVE_BATTLE_REACHED")
      renderer.visible = false
      $PokemonSystem.battlescene = 0
      session = KIFMultiplayer::OriginalVisualSession.new(model)
      KIFMultiplayer::OriginalBattlePresenter.with(session) do |presenter|
        presenter.accept_original({})
        count = 0
        while model.original["view"]["battle"] && model.original["prompt"]
          prompt = model.original["prompt"]
          value = presenter.prompt_value(prompt, ui)
          result = model.choose(value)
          presenter.accept_original(result)
          count += 1
          if count == 2
            image = Graphics.snap_to_bitmap
            image.to_file(File.join($kif_test_directory, "original-battle.png"))
            image.dispose
          end
          raise "Original battle input limit" if count > 100
        end
        test.check(session.result_decision == 1, "ORIGINAL_GAME_NATIVE_BATTLE_WON")
        test.check(presenter.active?, "ORIGINAL_GAME_ORIGINAL_ANIMATIONS_USED")
      end
    ensure
      renderer.dispose
    end
  end
  input_singleton.alias_method(:trigger?, :original_fixture_trigger)
  input_singleton.remove_method(:original_fixture_trigger)
  test.check(test.digest == baseline, "ORIGINAL_GAME_LEGACY_ASSETS_UNCHANGED")
  test.check(model.character["wallet"]["balance"] > 1000, "ORIGINAL_GAME_SERVER_GOLD_REWARD")
  test.log("ORIGINAL_GAME_PASS gold=#{model.character['wallet']['balance']}")
  exit!(0)
rescue Exception => error
  $kif_test_log.call("ORIGINAL_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
  exit!(1)
end
