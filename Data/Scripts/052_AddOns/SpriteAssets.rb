module KIF
  module SpriteIndex
    def self.parse_name(name)
      return nil unless name.is_a?(String) && name.valid_encoding?
      match = /\A([1-9]\d*)(?:\.([1-9]\d*))?([a-z]*)\.png\z/i.match(name)
      return nil unless match
      head, body = match[1].to_i, match[2] && match[2].to_i
      return nil if head > Settings::NB_POKEMON || (body && body > Settings::NB_POKEMON)
      { :head => head, :body => body, :alt => match[3].downcase }
    end

    def self.reload(custom_path = Settings::CUSTOM_SPRITES_FILE_PATH, base_path = Settings::BASE_SPRITES_FILE_PATH)
      signature = [custom_path, base_path].map do |path|
        File.file?(path) ? [path, File.size(path), File.mtime(path).to_f, File.ctime(path).to_f] : [path]
      end
      return if @signature == signature
      fusions, bases = {}, {}
      [[custom_path, true], [base_path, false]].each do |path, fusion|
        next unless File.file?(path)
        File.foreach(path) do |line|
          entry = parse_name(line.strip)
          next unless entry && !!entry[:body] == fusion
          key = fusion ? entry[:body] * Settings::NB_POKEMON + entry[:head] : entry[:head]
          table = fusion ? fusions : bases
          table[key] ||= []
          table[key] << entry[:alt] unless table[key].include?(entry[:alt])
        end
      end
      @signature, @fusions, @bases = signature, fusions, bases
    end

    def self.fusion_alts(head, body)
      reload
      (@fusions[body * Settings::NB_POKEMON + head] || []).dup
    end

    def self.base_alts(head)
      reload
      (@bases[head] || []).dup
    end

    def self.completion_percent
      reload
      100.0 * (@fusions.length + @bases.length) / (Settings::NB_POKEMON * Settings::NB_POKEMON + Settings::NB_POKEMON)
    end

    def self.reset; @signature = nil; end
  end

  module SpriteImport
    PNG = "\x89PNG\r\n\x1a\n".b
    def self.valid_png?(path)
      return false if File.symlink?(path) || File.size(path) > 8 * 1024 * 1024
      header = File.binread(path, 24)
      return false unless header.bytesize == 24 && header.start_with?(PNG) && header.byteslice(12, 4) == "IHDR"
      width, height = header.byteslice(16, 8).unpack("NN")
      return false unless width.between?(1, 4096) && height.between?(1, 4096)
      # mkxp's Bitmap resolver uses the mounted game root, not OS absolute paths.
      expanded = File.expand_path(path).tr("\\", "/")
      root = File.expand_path(".").tr("\\", "/").sub(%r{/+\z}, "") + "/"
      prefix_matches = root.match?(/\A[A-Za-z]:\//) ? expanded.downcase.start_with?(root.downcase) : expanded.start_with?(root)
      bitmap = Bitmap.new(prefix_matches ? expanded[root.length..-1] : path.tr("\\", "/"))
      true
    rescue Exception => error
      raise unless error.is_a?(StandardError) || (defined?(MKXPError) && error.is_a?(MKXPError))
      false
    ensure
      bitmap.dispose if bitmap && !bitmap.disposed?
    end
    def self.mkdir(path)
      return if File.directory?(path)
      mkdir(File.dirname(path))
      Dir.mkdir(path)
    end

    def self.run(source = Settings::CUSTOM_BATTLERS_FOLDER, bases = Settings::CUSTOM_BASE_SPRITE_FOLDER, indexed = Settings::CUSTOM_BATTLERS_FOLDER_INDEXED)
      result = { :imported => 0, :duplicates => {}, :invalid => [] }
      [source, File.join(source, "Sprites to import")].each do |folder|
        next unless File.directory?(folder)
        names = Dir.children(folder).sort rescue nil
        unless names
          result[:invalid] << folder
          next
        end
        names.each do |name|
          from = File.join(folder, name)
          next unless File.file?(from)
          entry = SpriteIndex.parse_name(name)
          unless entry && valid_png?(from)
            result[:invalid] << from
            next
          end
          directory = entry[:body] ? File.join(indexed, entry[:head].to_s) : bases
          filename = "#{entry[:head]}#{entry[:body] ? '.' + entry[:body].to_s : ''}#{entry[:alt]}.png"
          destination = File.join(directory, filename)
          if File.exist?(destination)
            result[:duplicates][from] = destination
            next
          end
          owned = complete = false
          begin
            mkdir(directory)
            File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0600) do |output|
              owned = true
              File.open(from, "rb") do |input|
                while (chunk = input.read(65_536))
                  raise IOError, "Short sprite import" unless output.write(chunk) == chunk.bytesize
                end
              end
              output.flush
              output.fsync
            end
            complete = true
            File.delete(from)
            result[:imported] += 1
          rescue Errno::EEXIST
            result[:duplicates][from] = destination
          rescue SystemCallError, IOError
            result[:invalid] << from
          ensure
            File.delete(destination) if owned && !complete && File.file?(destination)
          end
        end
      end
      SpriteIndex.reset if result[:imported] > 0
      result
    end
  end
end
