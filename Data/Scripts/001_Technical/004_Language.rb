# Keep Settings::LANGUAGES indices stable: they are stored in existing saves.
module GameLanguage
  def self.bitmap_path(path)
    return path unless path.is_a?(String) && $PokemonSystem && $PokemonSystem.language == 2
    if !@image_paths
      @image_paths = {}
      begin
        data = HTTPLite::JSON.parse(File.binread("Data/localization/zh-CN-images.json"))
        data["images"].each do |source, row|
          target = row["path"]
          next unless target.is_a?(String) && target.start_with?("Graphics/Chinese/") && !target.include?("..")
          @image_paths[source.downcase.sub(/\.(png|gif|bmp|jpe?g)\z/i, "")] = target if File.file?(target)
        end
      rescue StandardError, MKXPError
        # Optional translated art can fall back to the original assets.
      end
    end
    key = path.tr("\\", "/").sub(/\A\.\//, "")
    root = Dir.pwd.tr("\\", "/") + "/"
    key = key[root.length..-1] if key.downcase.start_with?(root.downcase)
    @image_paths[key.downcase.sub(/\.(png|gif|bmp|jpe?g)\z/i, "")] || path
  end

  def self.message(type, id, original)
    return original if !$PokemonSystem || $PokemonSystem.language == 0
    text = MessageTypes.getTranslation(type, id)
    return text unless text.empty?
    return original.is_a?(String) ? _INTL(original) : original
  end

  def self.fusion_name(head, body, original)
    return original unless $PokemonSystem && $PokemonSystem.language == 2
    prefix = MessageTypes.getTranslation(MessageTypes::FusionNamePrefixes, head)
    suffix = MessageTypes.getTranslation(MessageTypes::FusionNameSuffixes, body)
    return original if prefix.empty? || suffix.empty?
    prefix = prefix[0..-2] if prefix.length > 1 && suffix.length > 1 && prefix[-1] == suffix[0]
    return prefix + suffix
  end

  def self.available
    Settings::LANGUAGES.each_index.select do |index|
      pbRgssExists?("Data/" + Settings::LANGUAGES[index][1])
    end
  end

  def self.load(index)
    index = 0 unless available.include?(index)
    loaded = pbLoadMessages("Data/" + Settings::LANGUAGES[index][1])
    if !loaded
      index = 0
      pbLoadMessages("Data/" + Settings::LANGUAGES[0][1])
    end
    $PokemonSystem.language = index
    return !!loaded
  end

  def self.font_name
    chinese = $PokemonSystem && $PokemonSystem.language == 2
    return "Noto Sans SC" if (chinese || @choosing) && Font.exist?("Noto Sans SC")
    return nil
  end

  def self.choose
    indices = available
    return 0 if indices.empty?
    current = indices.index($PokemonSystem.language) || 0
    previous = @choosing
    begin
      @choosing = true
      selected = pbShowCommands(nil, indices.map { |index| Settings::LANGUAGES[index][0] }, -1, current)
      return indices[selected < 0 ? current : selected]
    ensure
      @choosing = previous
    end
  end
end

# Some scenes construct native Bitmaps directly, bypassing RPG::Cache.
if defined?(Bitmap)
  module ChineseBitmapPath
    def initialize(*args)
      args[0] = GameLanguage.bitmap_path(args[0]) if args[0].is_a?(String)
      super(*args)
    end
  end
  Bitmap.prepend(ChineseBitmapPath)
end
