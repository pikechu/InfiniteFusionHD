# IF 6.4 layouts: 96px cells; custom sheets use 20 columns, base/autogen 10.
# Extracted PNGs preserve all existing KIF hue/channel/individual-sprite paths.
module KIF
  module SpriteSheets
    SOURCE = "https://raw.githubusercontent.com/infinitefusion/infinitefusion-e18/main/Graphics/"
    CELL = 96
    class << self
      attr_writer :test_root
      def mode
        defined?($PokemonSystem) && $PokemonSystem && $PokemonSystem.respond_to?(:sprite_sheet_mode) ? $PokemonSystem.sprite_sheet_mode : 1
      end
      def cache_budget; KIF::Platform.android? ? 24 * 1024 * 1024 : 64 * 1024 * 1024; end
      def stats; (@stats || {}).merge(:cache_bytes => @cache_bytes || 0, :sheets => (@cache || {}).length); end
      def count(key); @stats ||= {}; @stats[key] = (@stats[key] || 0) + 1; end
      def clear
        (@cache || {}).each_value { |entry| entry[:bitmap].dispose unless entry[:bitmap].disposed? }
        @cache, @cache_bytes, @attempted = {}, 0, {}
      end
      def pack
        files = [Settings::CUSTOM_SPRITES_FILE_PATH, Settings::BASE_SPRITES_FILE_PATH]
        signature = files.map { |path| File.file?(path) ? [path, File.size(path), File.mtime(path).to_f.to_s, File.ctime(path).to_f.to_s] : [path] }
        version = [Settings::NEWEST_SPRITEPACK_YEAR, Settings::NEWEST_SPRITEPACK_MONTH, SOURCE]
        if @index_signature != [signature, version]
          require "digest/sha2"
          hashes = files.map { |path| File.file?(path) ? Digest::SHA256.hexdigest(File.binread(path)) : "missing" }
          key = Digest::SHA256.hexdigest((version + hashes).join("|"))[0, 16]
          clear if @pack != key
          @pack, @index_signature = key, [signature, version]
        end
        @pack
      end
      def root(type)
        return native_path(File.join(@test_root, type == :autogen ? "generated-cache" : "custom-cache")) if @test_root
        File.join(type == :autogen ? Settings::BATTLERS_FOLDER : Settings::CUSTOM_BATTLERS_FOLDER, "spritesheets", "kif-cache")
      end
      def validate(type, head, body, alt)
        [:base, :custom, :autogen].include?(type) && head.is_a?(Integer) && head.between?(1, Settings::NB_POKEMON) &&
          (type == :base ? body.nil? : (body.is_a?(Integer) && body.between?(1, Settings::NB_POKEMON))) &&
          alt.is_a?(String) && alt.match?(/\A[a-z]{0,3}\z/) && (type != :autogen || alt.empty?)
      end
      def filename(head, body, alt)
        "#{head}#{body ? '.' + body.to_s : ''}#{alt}.png"
      end
      def candidate(type, head, body = nil, alt = "")
        return nil unless validate(type, head, body, alt)
        File.join(root(type), pack, type.to_s, head.to_s, "pending", filename(head, body, alt))
      end
      def request(path)
        return nil unless path.is_a?(String)
        normalized = path.tr("\\", "/")
        [:custom, :autogen].each do |kind|
          prefix = root(kind).tr("\\", "/").sub(%r{/+\z}, "") + "/"
          next unless normalized.start_with?(prefix)
          rest = normalized[prefix.length..-1].split("/")
          next unless rest.length == 5 && rest[0].match?(/\A[0-9a-f]{16}\z/) && rest[3].match?(/\A(?:pending|[0-9a-f]{16})\z/)
          type = rest[1].to_sym
          entry = SpriteIndex.parse_name(rest[4])
          next unless entry && rest[2] == entry[:head].to_s && (kind == :autogen ? type == :autogen : [:base, :custom].include?(type))
          return [type, entry[:head], entry[:body], entry[:alt]] if validate(type, entry[:head], entry[:body], entry[:alt])
        end
        nil
      end
      def local_png(type, head, body, alt)
        name = filename(head, body, alt)
        case type
        when :base then File.join(Settings::CUSTOM_BASE_SPRITE_FOLDER, name)
        when :custom then File.join(Settings::CUSTOM_BATTLERS_FOLDER_INDEXED, head.to_s, name)
        else File.join(Settings::BATTLERS_FOLDER, head.to_s, name)
        end
      end
      def sheet_relative(type, head, alt)
        case type
        when :base then "CustomBattlers/spritesheets/spritesheets_base/#{head}.png"
        when :custom then "CustomBattlers/spritesheets/spritesheets_custom/#{head}/#{head}#{alt}.png"
        else "Battlers/spritesheets_autogen/#{head}.png"
        end
      end
      def bundled(type, head, alt)
        return File.join(@test_root, sheet_relative(type, head, alt)) if @test_root
        File.join("Graphics", sheet_relative(type, head, alt))
      end
      def sheet(type, head, alt, download)
        relative = sheet_relative(type, head, alt)
        saved = File.join(root(type), pack, "downloads", relative)
        @attempted ||= {}
        if mode == 2 && download && downloadAllowed?() && !File.file?(saved) && !@attempted[saved]
          @attempted[saved] = true
          response = KIF::Platform.http_get(SOURCE + relative)
          if response.is_a?(Hash) && response[:status] == 200 && png_header(response[:body], type)
            SpriteImport.mkdir(File.dirname(saved))
            pending = saved + ".#{Process.pid}.pending"
            begin
              File.binwrite(pending, response[:body])
              probe = Bitmap.new(native_path(pending))
              probe.dispose
              File.rename(pending, saved)
              count(:downloads)
            ensure
              File.delete(pending) if File.file?(pending)
            end
          end
        end
        return saved if File.file?(saved)
        path = bundled(type, head, alt)
        File.file?(path) ? path : nil
      rescue Exception => error
        raise unless error.is_a?(StandardError) || (defined?(MKXPError) && error.is_a?(MKXPError))
        count(:failures)
        path = bundled(type, head, alt)
        File.file?(path) ? path : nil
      end
      def png_header(body, type)
        return nil unless body.is_a?(String) && body.bytesize.between?(24, 16 * 1024 * 1024) && body.b.start_with?(SpriteImport::PNG)
        return nil unless body.byteslice(12, 4) == "IHDR"
        width, height = body.byteslice(16, 8).unpack("NN")
        columns = type == :custom ? 20 : 10
        return nil unless width == CELL * columns && height > 0 && height % CELL == 0 && height <= 8192 && width * height * 4 <= cache_budget
        [width, height]
      end
      def native_path(path)
        expanded = File.expand_path(path).tr("\\", "/")
        prefix = File.expand_path(".").tr("\\", "/").sub(%r{/+\z}, "") + "/"
        match = prefix.match?(/\A[A-Za-z]:\//) ? expanded.downcase.start_with?(prefix.downcase) : expanded.start_with?(prefix)
        match ? expanded[prefix.length..-1] : path.tr("\\", "/")
      end
      def bitmap(path, type)
        raise ArgumentError, "Sheet file is too large" if File.size(path) > 16 * 1024 * 1024
        stamp = [File.size(path), File.mtime(path).to_f.to_s, File.ctime(path).to_f.to_s]
        key = [path, stamp]
        @cache ||= {}; @cache_bytes ||= 0
        if (entry = @cache.delete(key))
          @cache[key] = entry
          count(:hits)
          return entry[:bitmap]
        end
        size = png_header(File.binread(path, 24), type)
        raise ArgumentError, "Invalid sheet dimensions" unless size
        bytes = size[0] * size[1] * 4
        while !@cache.empty? && (@cache.length >= 2 || @cache_bytes + bytes > cache_budget)
          _, old = @cache.shift
          old[:bitmap].dispose
          @cache_bytes -= old[:bytes]
        end
        image = Bitmap.new(native_path(path))
        @cache[key] = { :bitmap => image, :bytes => bytes }
        @cache_bytes += bytes
        @stats ||= {}
        @stats[:peak_cache_bytes] = [@stats[:peak_cache_bytes] || 0, @cache_bytes].max
        count(:misses)
        image
      end
      def resolve(type, head, body = nil, alt = "", download = true)
        return nil if mode == 0 || !validate(type, head, body, alt)
        local = local_png(type, head, body, alt)
        return local if File.file?(local)
        source = sheet(type, head, alt, download)
        return nil unless source
        signature = [source, File.size(source), File.mtime(source).to_f.to_s, File.ctime(source).to_f.to_s].join("|")
        require "digest/sha2"
        digest = Digest::SHA256.hexdigest(signature)[0, 16]
        path = File.join(root(type), pack, type.to_s, head.to_s, digest, filename(head, body, alt))
        return path if File.file?(path)
        image = bitmap(source, type)
        index = type == :base ? alt.each_byte.inject(0) { |value, code| value * 26 + code - 96 } : body
        columns = type == :custom ? 20 : 10
        x, y = index % columns * CELL, index / columns * CELL
        return nil if x + CELL > image.width || y + CELL > image.height
        sprite = Bitmap.new(CELL, CELL)
        sprite.blt(0, 0, image, Rect.new(x, y, CELL, CELL))
        # Empty cells are not usable custom sprites and must fall back normally.
        visible = false
        CELL.times do |row|
          CELL.times { |column| visible ||= sprite.get_pixel(column, row).alpha > 0 }
          break if visible
        end
        return nil unless visible
        SpriteImport.mkdir(File.dirname(path))
        pending = path + ".#{Process.pid}.pending"
        sprite.save_to_png(pending)
        File.rename(pending, path)
        count(:extractions)
        path
      rescue Exception => error
        raise unless error.is_a?(StandardError) || (defined?(MKXPError) && error.is_a?(MKXPError))
        count(:failures)
        nil
      ensure
        sprite.dispose if sprite && !sprite.disposed?
        File.delete(pending) if pending && File.file?(pending)
      end
      def resolve_path(path, download = true)
        entry = request(path)
        return nil unless entry
        resolved = resolve(*entry, download)
        resolved || (File.file?(path) ? path : nil)
      end
      def candidates(type, head, body = nil)
        return [] if mode == 0
        alts = type == :base ? SpriteIndex.base_alts(head) : SpriteIndex.fusion_alts(head, body)
        alts.filter_map do |alt|
          next if File.file?(local_png(type, head, body, alt))
          next if !(mode == 2 && downloadAllowed?()) && !sheet(type, head, alt, false)
          candidate(type, head, body, alt)
        end
      end
      def logical_path(path)
        entry = request(path)
        entry && local_png(*entry)
      end
      def shiny_prefix(directory)
        normalized = directory.tr("\\", "/")
        return nil unless [:custom, :autogen].any? { |type| normalized.start_with?(root(type).tr("\\", "/") + "/") }
        require "digest/sha2"
        "sheet_#{Digest::SHA256.hexdigest(normalized)[0, 20]}_"
      end
      def preload_party(trainer)
        return unless trainer && mode != 0
        trainer.party.first(6).each do |pokemon|
          next if pokemon.egg?
          stored = pokemon.instance_variable_get(:@kuraycustomfile)
          next if stored.is_a?(String) && (resolve_path(stored, false) || File.file?(stored))
          id = pokemon.species_data.id_number
          if id <= Settings::NB_POKEMON
            resolve(:base, id, nil, "", false)
          elsif id < Settings::ZAPMOLCUNO_NB
            body = getBodyID(id); head = getHeadID(id, body)
            resolve(:custom, head, body, "", false) || resolve(:autogen, head, body, "", false)
          end
        end
      end
    end

    module AnimatedPath
      def initialize(file, *args)
        super(KIF::SpriteSheets.resolve_path(file) || file, *args)
      end
    end
    module ResolvePath
      def pbResolveBitmap(path)
        KIF::SpriteSheets.resolve_path(path, false) || super
      end
      def getPathForShinyCache(path)
        KIF::SpriteSheets.shiny_prefix(path) || super
      end
    end
    module LoadPrewarm
      def load(*args)
        value = super
        KIF::SpriteSheets.preload_party($Trainer)
        value
      end
    end
    module DexClose
      def pbEndScene
        super
      ensure
        disposeAvailableBitmaps
        @creditsOverlay.dispose if @creditsOverlay && !@creditsOverlay.disposed?
        @creditsOverlay = nil
      end
    end
  end
end
AnimatedBitmap.prepend(KIF::SpriteSheets::AnimatedPath) if defined?(AnimatedBitmap) && !AnimatedBitmap.ancestors.include?(KIF::SpriteSheets::AnimatedPath)
Object.prepend(KIF::SpriteSheets::ResolvePath) unless Object.ancestors.include?(KIF::SpriteSheets::ResolvePath)
Game.singleton_class.prepend(KIF::SpriteSheets::LoadPrewarm) if defined?(Game) && !Game.singleton_class.ancestors.include?(KIF::SpriteSheets::LoadPrewarm)
PokemonPokedexInfo_Scene.prepend(KIF::SpriteSheets::DexClose) if defined?(PokemonPokedexInfo_Scene) && !PokemonPokedexInfo_Scene.ancestors.include?(KIF::SpriteSheets::DexClose)
