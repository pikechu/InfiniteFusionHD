# Mocked-host contracts; no SDL, JNI, device, player save, or network access.
require "tmpdir"
require "fileutils"

module System
  class << self
    attr_accessor :android_host, :messages
    def is_android?; !!@android_host; end
    def data_directory; "desktop/"; end
    def puts(message); (@messages ||= []) << message; end
  end
end

module Input
  DOWN = 2; LEFT = 4; RIGHT = 6; UP = 8
  A = 11; B = 12; C = 13; X = 14; Y = 15; Z = 16; L = 17; R = 18; F8 = 28
  class << self
    attr_reader :native_updates
    attr_accessor :order, :forced_dir4, :forced_dir8
    def clear_native
      @physical = {}; @pending_trigger = {}; @pending_release = {}
      @native_trigger = {}; @native_release = {}; @extra_repeat = {}
      @forced_dir4 = @forced_dir8 = nil
    end
    def native_down(code)
      @pending_trigger[code] = true unless @physical[code]
      @physical[code] = true
    end
    def native_up(code)
      @pending_release[code] = true if @physical[code]
      @physical.delete(code)
    end
    def native_repeat(code); @extra_repeat[code] = true; end
    def update
      @native_updates = (@native_updates || 0) + 1
      (@order ||= []) << :native_update
      @native_trigger = @pending_trigger; @pending_trigger = {}
      @native_release = @pending_release; @pending_release = {}
      :native_update_result
    end
    def press?(code); !!@physical[code]; end
    def trigger?(code); !!@native_trigger[code]; end
    def repeat?(code); !!(@native_trigger[code] || @extra_repeat[code]); end
    def release?(code); !!@native_release[code]; end
    def dir4; @forced_dir4 || [2, 4, 6, 8].find { |code| press?(code) } || 0; end
    def dir8; @forced_dir8 || dir4; end
  end
  clear_native
end

module KIFAndroidBridge
  class << self
    attr_reader :polls
    attr_accessor :bad_snapshot
    def clear
      @pressed = @triggered = @released = 0
      @bad_snapshot = nil
    end
    def down(code)
      bit = 1 << code
      @triggered |= bit if (@pressed & bit) == 0
      @pressed |= bit
    end
    def up(code)
      bit = 1 << code
      @released |= bit if (@pressed & bit) != 0
      @pressed &= ~bit
    end
    def input_poll
      @polls = (@polls || 0) + 1
      Input.order << :bridge_poll
      return @bad_snapshot if @bad_snapshot
      result = [@pressed, @triggered, @released]
      @triggered = @released = 0
      result
    end
  end
  clear
end

root = File.expand_path("../..", __dir__)
platform = File.join(root, "Data/Scripts/000_Platform.rb")
game_input = File.join(root, "Data/Scripts/001_Technical/004_Input.rb")
preload = File.join(root, "android/ruby/kif_android_preload.rb")
helper = File.join(root, "android/ruby/kif_android_input.rb")
load platform

checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
environment_names = ["KIF_ANDROID_INPUT", "KIF_ANDROID_NETWORK", "KIF_NATIVE_LIB_DIR", "KIF_SAVE_DIR"]
old_environment = environment_names.map { |name| [name, ENV[name]] }.to_h
begin
  System.android_host = false
  ENV["KIF_ANDROID_INPUT"] = "1"
  load game_input
  desktop_update_result = Input.update
  desktop_methods = [:update, :press?, :trigger?, :repeat?, :release?, :dir4, :dir8].map { |name| [name, Input.method(name)] }.to_h
  assert.call(KIF::Platform.install_input_bridge == false, "input bridge installed on Windows")
  assert.call(desktop_methods.all? { |name, method| Input.method(name) == method }, "Windows Input methods changed")
  assert.call(KIFAndroidBridge.polls.nil?, "Windows polled Android input")

  FileUtils.mkdir_p(File.join(root, "temp"))
  Dir.mktmpdir("kif-input-contract-", File.join(root, "temp")) do |work|
    FileUtils.cp(helper, File.join(work, "kif_android_input.rb"))
    library = File.join(work, "libkif_android_bridge.so").tr("\\", "/")
    File.binwrite(library, "mock helper; must never be loaded as native code")
    $LOADED_FEATURES << library
    begin
      Dir.chdir(work) do
        System.android_host = true
        ENV["KIF_SAVE_DIR"] = File.join(work, "saves")
        ENV["KIF_NATIVE_LIB_DIR"] = work
        ENV["KIF_ANDROID_NETWORK"] = "0"
        ENV["KIF_ANDROID_INPUT"] = "0"
        assert.call(KIF::Platform.install_input_bridge == false, "input bridge ignored disabled INPUT flag")
        ENV["KIF_ANDROID_INPUT"] = "1"
        assert.call(KIF::Platform.install_input_bridge == false, "input bridge ignored missing preload marker")
        load preload
        assert.call(KIF::Platform.instance_variable_get(:@android_input_bridge_loaded), "offline preload did not load input capability")
        assert.call(!KIF::Platform.instance_variable_get(:@android_network_bridge_loaded), "input-only preload enabled network capability")
        assert.call(!KIF::Platform.network_available?, "input-only preload enabled unverified networking")
        assert.call(Input.method(:update) == desktop_methods[:update], "preload installed Input wrapper before game aliases")
        old_verbose = $VERBOSE
        begin
          $VERBOSE = nil # The same game file is intentionally loaded for a second host scenario.
          load game_input
        ensure
          $VERBOSE = old_verbose
        end
        backend = KIF::Platform.install_input_bridge
        assert.call(backend.is_a?(KIF::AndroidInputBackend), "game Input installation entry did not install backend")
        before_method = Input.method(:update)
        assert.call(KIF::Platform.install_input_bridge.equal?(backend) && Input.method(:update) == before_method, "duplicate platform install wrapped Input twice")
        assert.call(KIF::AndroidInputBackend.install(Input, KIFAndroidBridge).equal?(backend), "duplicate backend install created a second backend")

        KIFAndroidBridge.down(Input::C)
        Input.order = []
        assert.call(Input.update == desktop_update_result, "Input update changed the captured game wrapper's return value")
        assert.call(Input.order == [:native_update, :bridge_poll], "bridge polled before captured game/native update")
        assert.call(Input.press?(Input::C) && Input.trigger?(Input::C) && Input.repeat?(Input::C), "virtual down did not merge pressed/triggered/initial repeat")
        Input.update
        assert.call(Input.press?(Input::C) && !Input.trigger?(Input::C), "held virtual key retriggered")
        KIFAndroidBridge.up(Input::C); Input.update
        assert.call(!Input.press?(Input::C) && Input.release?(Input::C), "virtual up did not release")
        Input.update
        assert.call(!Input.release?(Input::C), "released edge survived two polls")

        KIFAndroidBridge.down(Input::C); KIFAndroidBridge.up(Input::C); Input.update
        assert.call(!Input.press?(Input::C) && Input.trigger?(Input::C) && Input.repeat?(Input::C) && Input.release?(Input::C), "between-frame tap was lost")
        Input.update
        assert.call(!Input.trigger?(Input::C) && !Input.repeat?(Input::C), "short tap repeated without another edge")

        KIFAndroidBridge.down(Input::A); Input.update
        assert.call(Input.repeat?(Input::A), "initial virtual down did not repeat")
        22.times { Input.update; assert.call(!Input.repeat?(Input::A), "virtual repeat began before native 23/6 interval") }
        Input.update
        assert.call(Input.repeat?(Input::A), "virtual repeat missing at held count 23")
        5.times { Input.update; assert.call(!Input.repeat?(Input::A), "virtual repeat interval was shorter than six updates") }
        Input.update
        assert.call(Input.repeat?(Input::A), "virtual repeat missing after six updates")
        KIFAndroidBridge.clear; Input.update
        assert.call(!Input.press?(Input::A) && !Input.trigger?(Input::A) && !Input.repeat?(Input::A) && !Input.release?(Input::A), "pause clear left a pressed/edge/repeat state")
        KIFAndroidBridge.down(Input::A); Input.update
        assert.call(Input.trigger?(Input::A) && Input.repeat?(Input::A), "fresh down after pause did not reset repeat counter")

        KIFAndroidBridge.clear; Input.clear_native; Input.update
        KIFAndroidBridge.down(Input::DOWN); Input.update
        assert.call(Input.dir4 == 2 && Input.dir8 == 2, "virtual down direction missing")
        KIFAndroidBridge.down(Input::RIGHT); Input.update
        assert.call(Input.dir4 == 6 && Input.dir8 == 3, "virtual diagonal did not prefer second direction in dir4")
        KIFAndroidBridge.up(Input::DOWN); Input.update
        Input.native_down(Input::UP); Input.update
        assert.call(Input.dir4 == 8 && Input.dir8 == 9, "physical and virtual directions did not merge")
        KIFAndroidBridge.up(Input::RIGHT); Input.update
        assert.call(Input.dir4 == 8 && Input.dir8 == 8, "virtual release erased physical direction")
        KIFAndroidBridge.down(Input::DOWN); Input.update
        assert.call(Input.dir4 == 0 && Input.dir8 == 0, "opposite physical/touch directions did not cancel")
        KIFAndroidBridge.clear; Input.clear_native; Input.update
        KIFAndroidBridge.down(Input::LEFT); KIFAndroidBridge.down(Input::RIGHT); Input.update
        assert.call(Input.dir4 == 0 && Input.dir8 == 0, "opposite touch directions did not cancel")

        KIFAndroidBridge.clear; Input.clear_native; Input.update
        Input.native_down(Input::C); Input.update
        assert.call(Input.press?(Input::C) && Input.trigger?(Input::C) && Input.repeat?(Input::C), "native physical key was lost")
        KIFAndroidBridge.down(Input::C); Input.update
        KIFAndroidBridge.up(Input::C); Input.update
        assert.call(Input.press?(Input::C), "touch release erased held physical key")
        Input.native_up(Input::C); Input.update
        assert.call(Input.release?(Input::C) && !Input.press?(Input::C), "native release was lost")
        Input.forced_dir4 = 4; Input.forced_dir8 = 7
        assert.call(Input.dir4 == 4 && Input.dir8 == 7, "no-touch native direction behavior changed")
        Input.forced_dir4 = Input.forced_dir8 = nil
        Input.native_repeat(Input::R)
        assert.call(Input.repeat?(Input::R), "native repeat was lost")

        KIFAndroidBridge.down(Input::C); Input.update
        KIFAndroidBridge.bad_snapshot = [-1, 0, 0]; Input.update
        assert.call(!Input.press?(Input::C), "invalid poll left a stuck touch key")
        assert.call(System.messages.any? { |message| message.include?("input poll unavailable") }, "invalid poll was not diagnosed")
        KIFAndroidBridge.clear; Input.clear_native; Input.update
        KIFAndroidBridge.down(Input::C); Input.update
        assert.call(Input.trigger?(Input::C), "input backend did not recover after invalid poll")

        class << Input
          alias_method :later_mod_update, :update
          def update
            @later_mod_calls = (@later_mod_calls || 0) + 1
            later_mod_update
          end
        end
        mod_method = Input.method(:update)
        native_before = Input.native_updates
        poll_before = KIFAndroidBridge.polls
        Input.update
        assert.call(Input.native_updates == native_before + 1 && KIFAndroidBridge.polls == poll_before + 1, "later Mod alias recursed or duplicated polling")
        KIF::Platform.install_input_bridge
        assert.call(Input.method(:update) == mod_method, "repeat install replaced later Mod alias")
        assert.call(!Input.trigger?(:C) && !Input.press?(1000), "virtual backend changed unsupported key arguments")
      end
    ensure
      $LOADED_FEATURES.delete(library)
    end
  end
  puts "PASS: #{checks} Android input bridge assertions (mocked native host; no SDL/JNI/device test)"
ensure
  old_environment.each { |name, value| ENV[name] = value }
end
