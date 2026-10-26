# Keep Settings::LANGUAGES indices stable: they are stored in existing saves.
module GameLanguage
  def self.message(type, id, original)
    return original if !$PokemonSystem || $PokemonSystem.language == 0
    text = MessageTypes.getTranslation(type, id)
    return text.empty? ? original : text
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
