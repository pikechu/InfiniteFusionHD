begin
  load "scripts/multiplayer/test-bootstrap.rb"
  if ENV["KIF_ORIGINAL_PROBE_COOPERATIVE"] == "1"
    KIF::Platform.define_singleton_method(:android?) { true }
    KIFMultiplayer.install_android_network
  end
  module OriginalProbeReader
    def line(limit)
      value=super
      @probe_header_bytes=(@probe_header_bytes || 0)+value.bytesize+2
      value
    end
    def fill
      super
    rescue StandardError => error
      KIFMultiplayerFeatureTest.log("ORIGINAL_SOCKET_FAILURE #{error.class}: #{error.message} #{error.backtrace.first(5).join(' | ')}")
      raise
    end
    def exact(length)
      super
    rescue StandardError => error
      KIFMultiplayerFeatureTest.log("ORIGINAL_HTTP_REJECT #{error.message}")
      KIFMultiplayerFeatureTest.log("ORIGINAL_HTTP_BYTES wire=#{@wire_bytes} headers=#{@probe_header_bytes} buffer=#{@buffer.bytesize}")
      File.binwrite(File.join($kif_test_directory,"truncated-body.bin"),@buffer)
      raise
    end
  end
  KIFMultiplayer::SocketHTTP::Reader.prepend(OriginalProbeReader)
  module OriginalProbeCall
    def call(*arguments, **options)
      super
    rescue StandardError => error
      KIFMultiplayerFeatureTest.log("ORIGINAL_TRANSPORT_FAILURE #{error.class}: #{error.message} #{error.backtrace.first(6).join(' | ')}")
      raise
    end
  end
  KIFMultiplayer::SocketHTTP.prepend(OriginalProbeCall)
  test = KIFMultiplayerFeatureTest
  baseline = test.digest
  client = KIFMultiplayer::Client.new
  client.authenticate("login","original_game","OriginalNativeFixture123")
  character = KIFMultiplayer::ControlledClient.new(client).refresh.characters.find { |row| row["rules_mode"] == "original" }
  model = KIFMultiplayer::OriginalClient.new(client).refresh(character["id"])
  ui = KIFMultiplayer::OriginalUI.new(client)
  ui.current_model = model
  mode = ENV.fetch("KIF_ORIGINAL_PROBE_MODE","resume")
  if ["interactive", "transport"].include?(mode)
    module OriginalProbeHTTP
      def protocol_error(message)
        KIFMultiplayerFeatureTest.log("ORIGINAL_HTTP_REJECT #{message}")
        super
      end
    end
    KIFMultiplayer::SocketHTTP.prepend(OriginalProbeHTTP)
    module KIFOriginalProbeInput
      def trigger?(key)
        value = super
        KIFMultiplayerFeatureTest.log("ORIGINAL_TOUCH key=#{key}") if value && [Input::USE,Input::BACK].include?(key)
        value
      end
    end
    Input.singleton_class.prepend(KIFOriginalProbeInput)
    observer = Thread.new do
      loop do
        sleep 10
        test.log("ORIGINAL_PROBE_STACK #{Thread.main.backtrace.first(8).join(' | ')}")
      end
    end
    begin
      if mode == "transport"
        1000.times do |index|
          model.refresh(character["id"])
          test.log("ORIGINAL_TRANSPORT_RESPONSE #{index+1}")
        end
      else
        KIFMultiplayer.with_ui_fonts { ui.main(character["id"]) }
      end
    ensure
      observer.kill
    end
    test.check(test.digest == baseline,"ORIGINAL_INTERACTIVE_LEGACY_ISOLATION")
  else
    test.check(!!model.original["view"]["battle"],"ORIGINAL_PENDING_BATTLE_FOUND")
    KIFMultiplayer::OriginalPresentation.with do
      if mode == "observe"
        session = KIFMultiplayer::OriginalVisualSession.new(model)
        KIFMultiplayer::OriginalBattlePresenter.with(session) do |presenter|
          presenter.accept_original({})
          image = Graphics.snap_to_bitmap
          image.to_file(File.join($kif_test_directory,"original-resume.png"))
          image.dispose
        end
      else
        original_trigger = Input.method(:trigger?)
        Input.singleton_class.define_method(:trigger?) do |key|
          key == Input::USE || key == Input::BACK && !model.original["view"]["battle"] || original_trigger.call(key)
        end
        ui.define_singleton_method(:pause_menu) { |_model| :exit }
        KIFMultiplayer::OriginalWorldScene.new(model,ui).run
        Input.singleton_class.define_method(:trigger?,original_trigger)
        test.check(!model.original["view"]["battle"] && model.original["prompt"].nil?,"ORIGINAL_RESUMED_WORLD_LOOP_COMPLETED")
      end
    end
    test.check(test.digest == baseline,"ORIGINAL_RESUME_LEGACY_ISOLATION")
  end
  test.log("ORIGINAL_RESUME_PASS mode=#{mode} gold=#{model.character['wallet']['balance']}")
  exit!(0)
rescue Exception => error
  $kif_test_log.call("ORIGINAL_RESUME_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
  System.puts("ORIGINAL_RESUME_FAIL #{error.class}: #{error.message}") if defined?(System) && System.respond_to?(:puts)
  exit!(1)
end
