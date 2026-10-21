# Explicit customScript diagnostic. Android/device execution is pending until
# KIF_GAME_SMOKE_PASS appears in a captured log. This is data integration coverage;
# it does not certify battles, fusion/evolution animation, input, or game saves.
# Only android-integration-probe.rxdata in KIF_SAVE_DIR is written by this probe.
module Kernel
  def puts(*values)
    values.each { |value| System.puts(value.to_s) }
  end
end

$kif_android_probe_loaded = []
$kif_android_probe_last_script = nil

# Same per-directory files-first sort/eval order as Data/Scripts.rxdata's loader.
# The production Main owns an endless scene loop, so only that directory is skipped.
def kif_android_probe_load_scripts(path)
  files = []
  folders = []
  Dir.foreach(path) do |name|
    next if name == "." || name == ".."
    File.directory?(path + "/" + name) ? folders.push(name) : files.push(name)
  end
  files.sort.each do |name|
    full_path = path + "/" + name
    $kif_android_probe_last_script = full_path
    code = File.open(full_path, "r") { |file| file.read }
    eval(code, nil, name)
    $kif_android_probe_loaded << full_path
    if $kif_android_probe_loaded.length % 50 == 0
      puts "KIF_GAME_SMOKE_LOAD count=#{$kif_android_probe_loaded.length} last=#{full_path}"
    end
  end
  folders.sort.each do |folder|
    if path == "Data/Scripts" && folder == "999_Main"
      puts "KIF_GAME_SMOKE_SKIP Data/Scripts/999_Main (production scene loop)"
      next
    end
    kif_android_probe_load_scripts(path + "/" + folder)
  end
end

module KIFAndroidGameSmoke
  class UnfuseMessages
    attr_reader :refreshes
    def initialize
      @refreshes = 0
    end
    def pbDisplay(message)
      puts "KIF_GAME_SMOKE_UNFUSE_MESSAGE #{message}"
    end
    def pbHardRefresh
      @refreshes += 1
    end
  end

  class << self
    def check(condition, label)
      raise "Assertion failed: #{label}" unless condition
      @checks += 1
      puts "KIF_GAME_SMOKE_CHECK #{@checks} #{label}"
    end

    def phase(name)
      @stage = name
      puts "KIF_GAME_SMOKE_STAGE #{name}"
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      @timings[name] = elapsed
      puts "KIF_GAME_SMOKE_STAGE_PASS #{name} seconds=#{elapsed.round(4)}"
    end

    def sample(bitmap)
      pixels = []
      (0...bitmap.height).step(4) do |y|
        (0...bitmap.width).step(4) do |x|
          color = bitmap.get_pixel(x, y)
          pixels << [color.red, color.green, color.blue, color.alpha].map(&:to_i)
        end
      end
      pixels
    end

    def accept_unfuse_confirmation
      # Replace only the confirmation UI, never pbUnfuse or any model operation.
      # The test runs as a customScript and restores this method before continuing.
      singleton = Kernel.singleton_class
      had_own_method = singleton.instance_methods(false).include?(:pbConfirmMessage) ||
        singleton.private_instance_methods(false).include?(:pbConfirmMessage)
      original = Kernel.method(:pbConfirmMessage)
      singleton.send(:define_method, :pbConfirmMessage) do |message, *_args|
        puts "KIF_GAME_SMOKE_AUTO_CONFIRM #{message}"
        true
      end
      begin
        yield
      ensure
        if had_own_method
          singleton.send(:define_method, :pbConfirmMessage, original)
        else
          singleton.send(:remove_method, :pbConfirmMessage)
        end
      end
    end

    def run
      @checks = 0
      @timings = {}
      @stage = "preload"
      raise "This integration probe requires the Android RGSS runtime" unless
        defined?(System) && System.respond_to?(:is_android?) && System.is_android?
      # mkxp's customScript branch bypasses normal RGSS preloadScript execution.
      load "kif_android_preload.rb"
      puts "KIF_GAME_SMOKE_BEGIN ruby=#{RUBY_VERSION} runtime=#{System::VERSION} platform=#{System.platform}"

      phase("real_script_loader") do
        kif_android_probe_load_scripts("Data/Scripts")
        check($kif_android_probe_loaded.length > 400, "complete game script tree loaded")
        check(!$kif_android_probe_loaded.any? { |file| file.start_with?("Data/Scripts/999_Main/") }, "production Main was excluded")
        check(defined?(GameData::FusedSpecies) && defined?(PokemonStorage), "final fusion and storage classes exist")
        check(Bitmap.method_defined?(:hue_customcolor), "late-loaded custom shiny Bitmap method exists")
      end

      phase("new_game_globals_and_compiled_data") do
        $POKEMONDATA_QUEUEING = []
        MessageTypes.loadMessageFile("Data/messages.dat") if safeExists?("Data/messages.dat")
        PluginManager.runPlugins
        Compiler.main
        Game.initialize
        # Deliberately avoid Game.set_up_system: it discovers and loads player slots.
        SaveData.initialize_bootup_values
        SaveData.load_new_game_values
        $Trainer.name = "AndroidProbe"
        $Trainer.party.clear
        $PokemonSystem.shiny_cache = 2 # Do not create or modify the player's shiny cache.
        $PokemonSystem.pifimprovedshinies = 3
        check($Trainer.is_a?(Player) && $PokemonSystem.is_a?(PokemonSystem), "fresh Player and PokemonSystem initialized")
        check(GameData::Species.get(1).species == :BULBASAUR, "compiled Bulbasaur data resolves without fallback")
        check(GameData::Species.get(4).species == :CHARMANDER, "compiled Charmander data resolves without fallback")
        check($data_system.start_map_id > 0, "compiled System has a real start map")
      end

      phase("pokemon_and_fusion_model") do
        @body = Pokemon.new(:BULBASAUR, 12)
        @head = Pokemon.new(:CHARMANDER, 9)
        @body.shiny = false
        @head.shiny = false
        check(@body.level == 12 && @head.level == 9, "real Pokemon constructors and levels")
        check(@body.totalhp > 0 && !@body.moves.empty?, "real stat and learnset initialization")
        fused_id = get_fusion_id(@head.dexNum, @body.dexNum)
        check(fused_id == :B1H4, "game fusion identifier joins body and head")
        @fused = Pokemon.new(fused_id, calculateFusedPokemonLevel(12, 9, false))
        check(@fused.isFusion? && @fused.species_data.is_a?(GameData::FusedSpecies), "real FusedSpecies-backed Pokemon construction")
        check(getBasePokemonID(@fused.species, true) == 1 && getBasePokemonID(@fused.species, false) == 4, "game split helpers recover both components")
        check(calculateFusedPokemonLevel(12, 9, false) == 11 && calculateFusedPokemonLevel(12, 9, true) == 12, "normal and super splicer level helpers")
        reverse_id = get_fusion_id(@body.dexNum, @head.dexNum)
        reverse = GameData::Species.get(reverse_id)
        check(reverse.is_a?(GameData::FusedSpecies) && getBasePokemonID(reverse.id, true) == 4, "reverse fusion data model")
        GameData::Stat.each_main { |stat| @body.iv[stat.id] = 30; @head.iv[stat.id] = 10 }
        fusion_helper = PokemonFusionScene.allocate
        fusion_helper.instance_variable_set(:@pokemon1, @body)
        fusion_helper.instance_variable_set(:@pokemon2, @head)
        fusion_helper.setFusionIVs(false)
        check(@body.iv.values.all? { |iv| iv == 20 }, "real fusion IV averaging helper")
        puts "KIF_GAME_SMOKE_SCOPE fusion=model-and-IV-helper; animated-pbFuse-and-reverseFusion=not-tested"
      end

      phase("native_bitmap_and_real_shiny_processing") do
        @body.kuraycustomfile = "Graphics/BaseSprites/1.png"
        $PokemonSystem.kurayindividcustomsprite = 0 # Honor the explicit test sprite instead of choosing a random alt.
        @body.sprite_scale = 1
        check(File.file?(@body.kuraycustomfile), "required bundled Bulbasaur sprite is a real file")
        png_header = File.open(@body.kuraycustomfile, "rb") { |file| file.read(24) }
        raise "Probe sprite is not a PNG" unless png_header && png_header.start_with?("\x89PNG\r\n\x1a\n".b)
        source_width, source_height = png_header[16, 8].unpack("N2")
        puts "KIF_GAME_SMOKE_SPRITE_SOURCE path=#{@body.kuraycustomfile} realpath=#{File.realpath(@body.kuraycustomfile)} png=#{source_width}x#{source_height} sprite_scale=#{@body.sprite_scale} resolved=#{pbResolveBitmap(@body.kuraycustomfile)}"
        raw = nil
        begin
          # Do not let GifBitmap's rescue turn a native read/decoder failure into
          # an apparently valid empty 32x32 sprite during this diagnostic.
          raw = Bitmap.new(@body.kuraycustomfile)
          puts "KIF_GAME_SMOKE_RAW_BITMAP width=#{raw.width} height=#{raw.height}"
          check(raw.width == source_width && raw.height == source_height, "native Bitmap decodes the real bundled PNG dimensions")
        rescue Exception => error
          puts "KIF_GAME_SMOKE_RAW_BITMAP_FAIL #{error.class}: #{error.message}"
          raise
        ensure
          raw.dispose if raw && !raw.disposed?
        end
        normal = GameData::Species.sprite_bitmap_from_pokemon(@body)
        @normal_bitmap = normal.bitmap.copy
        puts "KIF_GAME_SMOKE_NORMAL_BITMAP path=#{normal.path} filename=#{normal.filename} width=#{@normal_bitmap.width} height=#{@normal_bitmap.height} sprite_scale=#{@body.sprite_scale}"
        normal.dispose
        @body.shiny = true
        @body.shinyValue = 90
        @body.shinyR = 2
        @body.shinyG = 0
        @body.shinyB = 1
        @body.shinyKRS = [0] * 9
        shiny = GameData::Species.sprite_bitmap_from_pokemon(@body)
        @shiny_bitmap = shiny.bitmap.copy
        puts "KIF_GAME_SMOKE_SHINY_BITMAP path=#{shiny.path} filename=#{shiny.filename} width=#{@shiny_bitmap.width} height=#{@shiny_bitmap.height} sprite_scale=#{@body.sprite_scale}"
        shiny.dispose
        expected_width = source_width == 96 && source_height == 96 ? source_width * 3 : source_width
        expected_height = source_width == 96 && source_height == 96 ? source_height * 3 : source_height
        check(@normal_bitmap.width == expected_width && @normal_bitmap.height == expected_height, "ordinary sprite preserves the deterministic bundled source dimensions")
        check(@normal_bitmap.width == @shiny_bitmap.width && @normal_bitmap.height == @shiny_bitmap.height, "shiny preserves sprite dimensions")
        normal_pixels = sample(@normal_bitmap)
        shiny_pixels = sample(@shiny_bitmap)
        opaque = normal_pixels.count { |pixel| pixel[3] > 0 }
        changed = normal_pixels.zip(shiny_pixels).count { |a, b| a != b }
        check(opaque > 0 && changed > 0, "real shiny renderer changes visible sprite pixels")
        @shiny_crc = Zlib.crc32(shiny_pixels.flatten.pack("C*"))
        fixture = Bitmap.new(4, 4)
        begin
          fixture.fill_rect(0, 0, 4, 4, Color.new(120, 100, 80, 200))
          fixture.hue_customcolor("120 100 80.30 200 60")
          transformed = fixture.get_pixel(1, 1)
          check([transformed.red, transformed.green, transformed.blue, transformed.alpha].map(&:to_i) == [30, 200, 60, 200], "late-loaded custom shiny algorithm and native pixels")
        ensure
          fixture.dispose
        end
        puts "KIF_GAME_SMOKE_BITMAP width=#{@shiny_bitmap.width} height=#{@shiny_bitmap.height} changed_samples=#{changed} crc32=#{@shiny_crc}"
      end

      phase("real_unfuse_and_storage_operations") do
        # A fused fixture supplies metadata normally written by the animated UI.
        # Its species/stats are real; the production pbUnfuse performs every split.
        @fused.exp_when_fused_body = @body.exp
        @fused.exp_when_fused_head = @head.exp
        @fused.exp_gained_since_fused = 0
        @fused.head_gender = @head.gender
        @fused.shiny = true
        @fused.body_shiny = true
        @fused.head_shiny = false
        @fused.body_shinyhue = @body.shinyValue
        @fused.body_shinyimprovpif = @body.shinyimprovpif
        @fused.body_shinyr = @body.shinyR
        @fused.body_shinyg = @body.shinyG
        @fused.body_shinyb = @body.shinyB
        @fused.body_shinykrs = @body.shinyKRS.clone
        @fused.shinyValue = @body.shinyValue
        $PokemonStorage = PokemonStorage.new(2, 30)
        check($PokemonStorage.pbStoreCaught(@fused) == 0, "production storage accepts fused Pokemon")
        scene = UnfuseMessages.new
        result = accept_unfuse_confirmation { pbUnfuse(@fused, scene, true, [0, 0]) }
        check(result == true && scene.refreshes == 1, "production pbUnfuse completed with UI-only auto confirmation")
        first = $PokemonStorage[0, 0]
        second = $PokemonStorage[0, 1]
        check(first.species == :BULBASAUR && second.species == :CHARMANDER, "unfuse produced both real Pokemon in storage")
        check(first.exp == @body.exp && second.exp == @head.exp, "unfuse preserved component experience")
        check(first.shiny? && !second.shiny?, "unfuse preserved body-only shininess")
        check($PokemonStorage.pbMove(1, 0, 0, 1), "production storage move succeeds")
        check($PokemonStorage[0, 1].nil? && $PokemonStorage[1, 0].species == :CHARMANDER, "storage move clears source and preserves destination")
      end

      phase("dedicated_probe_marshal_write_and_reload") do
        directory = File.expand_path(ENV.fetch("KIF_SAVE_DIR"))
        @probe_path = File.join(directory, "android-integration-probe.rxdata")
        check(File.dirname(File.expand_path(@probe_path)) == directory, "probe path stays in dedicated private save directory")
        if File.file?(@probe_path)
          old = File.open(@probe_path, "rb") { |file| Marshal.load(file) }
          check(old[:marker] == "KIF_ANDROID_INTEGRATION_PROBE_V1", "prior probe marker reloads in this process")
          check(old[:storage][0, 0].species == :BULBASAUR && old[:storage][1, 0].species == :CHARMANDER, "prior probe storage reloads after prior process/run")
          puts "KIF_GAME_SMOKE_PROBE_RELOAD_PASS #{@probe_path}"
        else
          puts "KIF_GAME_SMOKE_PROBE_FIRST_RUN restart verification still pending"
        end
        record = { :marker => "KIF_ANDROID_INTEGRATION_PROBE_V1", :ruby => RUBY_VERSION,
          :runtime => System::VERSION, :player => $Trainer, :pokemon_system => $PokemonSystem,
          :storage => $PokemonStorage, :shiny_crc32 => @shiny_crc }
        File.open(@probe_path, "wb") { |file| Marshal.dump(record, file); file.flush; file.fsync }
        restored = File.open(@probe_path, "rb") { |file| Marshal.load(file) }
        check(restored[:storage].is_a?(PokemonStorage) && restored[:player].is_a?(Player), "real game classes survive native Marshal round trip")
        check(restored[:storage][0, 0].shiny? && restored[:storage][0, 0].exp == @body.exp, "persisted shiny Pokemon and experience reload")
        check(restored[:storage][1, 0].species == :CHARMANDER && restored[:shiny_crc32] == @shiny_crc, "second box and render checksum reload")
      end

      phase("result_frame") do
        prepare_result
        Graphics.update
        Input.update
      end
      puts "KIF_GAME_SMOKE_PASS checks=#{@checks} loaded=#{$kif_android_probe_loaded.length} timings=#{@timings.inspect} probe=#{@probe_path}"
      puts "KIF_GAME_SMOKE_PENDING map-movement,battle,capture,animated-fusion,reversal,evolution,game-save-slots,lifecycle,Windows-save-import"
      loop { Graphics.update; Input.update }
    rescue Exception => error
      puts "KIF_GAME_SMOKE_FAIL stage=#{@stage} last_script=#{$kif_android_probe_last_script} #{error.class}: #{error.message}"
      puts error.backtrace.join("\n") if error.backtrace
      raise
    end

    def prepare_result
      Graphics.resize_screen(512, 384)
      board = Bitmap.new(512, 384)
      board.fill_rect(0, 0, 512, 384, Color.new(22, 37, 48))
      board.font.size = 20
      board.draw_text(0, 0, 512, 36, "KIF game data integration: PASS", 1)
      board.draw_text(0, 36, 512, 32, "#{@checks} assertions / #{$kif_android_probe_loaded.length} scripts", 1)
      board.draw_text(0, 344, 512, 36, "Gameplay and UI acceptance pending", 1)
      [@normal_bitmap, @shiny_bitmap].each_with_index do |bitmap, index|
        board.stretch_blt(Rect.new(index * 256, 80, 256, 256), bitmap, bitmap.rect)
        bitmap.dispose
      end
      @result_sprite = Sprite.new
      @result_sprite.bitmap = board
    end
  end
end

KIFAndroidGameSmoke.run
