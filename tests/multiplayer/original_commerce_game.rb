begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  baseline = test.digest
  client = KIFMultiplayer::Client.new
  client.authenticate("login","original_game","OriginalNativeFixture123")
  role = KIFMultiplayer::ControlledClient.new(client).refresh.characters.find { |row| row["rules_mode"] == "original" }
  model = KIFMultiplayer::OriginalClient.new(client).refresh(role["id"])
  monster = model.original["view"]["monsters"].find { |row| row["species"] == "PIDGEY" }
  test.check(!!monster,"ORIGINAL_TRADE_OWNED_CAPTURE_FOUND")
  ui = KIFMultiplayer::OriginalCommerceUI.new(client)
  ui.instance_variable_set(:@model,model)
  decisions = [ui.selectable.index(monster)]
  ui.define_singleton_method(:choose) do |title,choices|
    target=decisions.shift
    raise "Unexpected trade menu #{title}" unless target && target.between?(0,choices.length-1)
    pbMessage(title,choices,choices.length,nil,target)
  end
  ui.define_singleton_method(:number) { |*| 300 }
  trigger=Input.method(:trigger?)
  Input.singleton_class.define_method(:trigger?) { |key| key==Input::USE || trigger.call(key) }
  KIFMultiplayer.with_ui_fonts do
    KIFMultiplayer::OriginalPresentation.with do
      ui.list_monster
      test.check(!model.original["view"]["monsters"].any? { |row| row["id"]==monster["id"] },"ORIGINAL_TRADE_UI_ESCROW_REMOVED_ONCE")
      decisions.concat([0,3])
      original_preview=ui.method(:show_monster)
      ui.define_singleton_method(:show_monster) do |row|
        available=original_preview.call(row)
        test.check(available,"ORIGINAL_TRADE_NATIVE_PREVIEW_AVAILABLE")
        available
      end
      ui.browse(true)
      test.check(model.original["view"]["monsters"].count { |row| row["id"]==monster["id"] }==1,"ORIGINAL_TRADE_UI_CANCEL_DELIVERED_ONCE")
      test.check(model.character["wallet"]["balance"]==1000,"ORIGINAL_TRADE_UI_CANCEL_GOLD_UNCHANGED")
    end
  end
  Input.singleton_class.define_method(:trigger?,trigger)
  test.check(test.digest==baseline,"ORIGINAL_TRADE_UI_LEGACY_ISOLATION")
  test.log("ORIGINAL_COMMERCE_GAME_PASS")
  exit!(0)
rescue Exception => error
  $kif_test_log.call("ORIGINAL_COMMERCE_GAME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
  exit!(1)
end
