class Sprite_Player < Sprite_Character
  def initialize(viewport, character = nil)
    super
    @viewport = viewport
    @outfit_bitmap = nil
    @hat_bitmap = nil

    hatFilename = ""
    hairFilename = ""
    @hair = Sprite_Hair.new(self, hairFilename, @character_name, @viewport)
    @hat = Sprite_Hat.new(self, hatFilename, @character_name, @viewport)

    @previous_skinTone = 0

    @current_bitmap = nil
    @previous_action =nil
    getClothedPlayerSprite(true)
  end


  def updateCharacterBitmap
    skinTone = $Trainer.skin_tone ? $Trainer.skin_tone : 0
    appearance = [skinTone, @character_hue]
    if @base_appearance != appearance
      disposeBaseBitmaps
      @base_appearance = appearance
    end
    @base_bitmaps ||= {}
    unless @base_bitmaps[@character_name]
      path = getBaseOverworldSpriteFilename(@character_name, skinTone)
      path = Settings::PLAYER_GRAPHICS_FOLDER + @character_name if !pbResolveBitmap(path)
      @base_bitmaps[@character_name] = [path, AnimatedBitmap.new(path, @character_hue)]
    end
    path, owner = @base_bitmaps[@character_name]
    # Keep one reference while Sprite_Character releases its current action.
    # Map transfers can clear RPG::Cache; restore this still-owned entry there.
    key = @character_hue == 0 ? path : [path, @character_hue]
    RPG::Cache.setKey(key, owner.bitmap)
    AnimatedBitmap.new(path, @character_hue)
  end

  def disposeBaseBitmaps
    @base_bitmaps&.each_value { |_, bitmap| bitmap.dispose }
    @base_bitmaps = {}
  end

  def applyDayNightTone
    super
    pbDayNightTint(@hat.sprite) if @hat && @hat.sprite.bitmap
    pbDayNightTint(@hair.sprite) if @hair && @hair.sprite.bitmap
  end

  def opacity=(value)
    super
    @hat.sprite.opacity= value if @hat && @hat.sprite.bitmap
    @hair.sprite.opacity= value if @hair && @hair.sprite.bitmap
  end

  def getClothedPlayerSprite(forceUpdate=false)
    appearance = [$Trainer.skin_tone, $Trainer.clothes, $Trainer.hair, $Trainer.hat,
                  $Trainer.clothes_color, $Trainer.hair_color, $Trainer.hat_color, @character_hue]
    if forceUpdate || @outfit_appearance != appearance
      disposeOutfitBitmaps
      @outfit_appearance = appearance
    end
    # Keep only the action sheets for the current appearance, owned by this
    # sprite. Walking/running switches reuse them instead of decoding again.
    @outfit_bitmaps ||= {}
    @current_bitmap = @outfit_bitmaps[@character_name] ||= generateClothedBitmap
    @previous_action = @character_name
    return @current_bitmap
  end

  def disposeOutfitBitmaps
    @outfit_bitmaps&.each_value { |bitmap| bitmap.dispose unless bitmap.disposed? }
    @outfit_bitmaps = {}
  end

  def refreshOutfit
    @outfit_appearance = nil
    @base_appearance = nil
    @manual_refresh = true
  end

  def generateClothedBitmap()
    # BitmapWrapper#copy resets reference ownership; clone inherits the source's
    # cache refcount and cannot be fully released with a single dispose.
    baseBitmap = @charbitmap.bitmap.copy

    outfitFilename = getOverworldOutfitFilename($Trainer.clothes, @character_name) #
    outfitFilename = getOverworldOutfitFilename(Settings::PLAYER_TEMP_OUTFIT_FALLBACK) if !pbResolveBitmap(outfitFilename)
    hairFilename = getOverworldHairFilename($Trainer.hair)
    hatFilename = getOverworldHatFilename($Trainer.hat)

    hair_color_shift = $Trainer.hair_color
    hat_color_shift = $Trainer.hat_color
    clothes_color_shift = $Trainer.clothes_color

    hair_color_shift = 0 if !hair_color_shift
    hat_color_shift = 0 if !hat_color_shift
    clothes_color_shift = 0 if !clothes_color_shift
    @hair.update(@character_name, hairFilename, hair_color_shift) if @hair
    @hat.update(@character_name, hatFilename, hat_color_shift) if @hat

    if !pbResolveBitmap(outfitFilename)
      raise "No temp clothes graphics available"
    end

    outfitBitmap = AnimatedBitmap.new(outfitFilename, clothes_color_shift) if pbResolveBitmap(outfitFilename) #pbLoadOutfitBitmap(outfitFilename) if pbResolveBitmap(outfitFilename)
    baseBitmap.blt(0, 0, outfitBitmap.bitmap, outfitBitmap.bitmap.rect) if outfitBitmap
    @previous_action = @character_name
    return baseBitmap
  rescue Exception
    baseBitmap.dispose if baseBitmap && !baseBitmap.disposed?
    raise
  ensure
    outfitBitmap.dispose if outfitBitmap
  end




  def update
    super
    # Character.update places/hides the body after resolving its bitmap.
    @hair.animate(@character_name) if @hair
    @hat.animate(@character_name) if @hat
  end

  def dispose
    super
    disposeOutfitBitmaps
    disposeBaseBitmaps
    @hat.dispose if @hat
    @hair.dispose if @hair
  end

  def pbLoadOutfitBitmap(outfitFileName)
    begin
      outfitBitmap = RPG::Cache.load_bitmap("", outfitFileName)
      return outfitBitmap
    rescue
      return nil
    end
  end
end
