# Real character updater and reference-counted cache with a minimal graphics host.
require "ostruct"
class Bitmap
  attr_reader :width, :height
  def initialize(*); @width, @height = 96, 128; end
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
module RPG
  class Sprite
    attr_accessor :x, :y, :z, :ox, :oy, :visible, :opacity, :blend_type
    attr_reader :bitmap, :src_rect
    def initialize(*)
      @src_rect = Object.new
      def @src_rect.set(*); end
    end
    def bitmap=(value)
      raise "AnimatedBitmap wrapper assigned as a drawable bitmap" if value && !value.is_a?(Bitmap)
      @bitmap = value
    end
    def update; end
    def dispose; end
  end
end
class Game_Event; end
class Game_Map; TILE_WIDTH = TILE_HEIGHT = 32; end
def darknessEffectOnCurrentMap; false; end
def pbDayNightTint(*); end
def pbGetTileBitmap(*); Bitmap.new; end
load File.expand_path("../../Data/Scripts/007_Objects and windows/001_RPG_Cache.rb", __dir__)
RPG::Cache.instance_variable_set(:@cache, {})
class AnimatedBitmap
  attr_reader :bitmap, :updates
  def initialize(path, hue = 0)
    @bitmap = RPG::Cache.load_bitmap("", path, hue)
    @updates = 0
  end
  def width; @bitmap.width; end
  def height; @bitmap.height; end
  def update; @updates += 1; end
  def dispose; @bitmap.dispose; end
end
load File.expand_path("../../Data/Scripts/005_Sprites/003_Sprite_Character.rb", __dir__)
character = OpenStruct.new(tile_id: 0, character_name: "fixture", character_hue: 0, bush_depth: 0,
  width: 1, height: 1, map: OpenStruct.new(tileset_name: "fixture"), transparent: false,
  pattern: 0, direction: 2, bob_height: 0, screen_x: 32, screen_y: 64,
  opacity: 255, blend_type: 0, animation_id: 0)
def character.screen_z(*); 100; end
checks = 0
check = lambda { |value, name| raise name unless value; checks += 1 }
first = Sprite_Character.new(nil, character)
shared = first.charbitmap.bitmap
check.call(first.instance_variable_get(:@charbitmapAnimated) == true, "ordinary PNG sheets still use AnimatedBitmap state")
check.call(first.bitmap.equal?(shared) && first.charbitmap.updates == 1, "character draws and updates the wrapped bitmap")
check.call(shared.never_dispose, "character cache retains its existing reuse policy")
second = Sprite_Character.new(nil, character)
check.call(second.bitmap.equal?(shared) && shared.refcount == 2, "two sprites share the cached bitmap with separate references")
first.dispose
check.call(!shared.disposed? && shared.refcount == 1, "disposing one sprite does not release another sprite's image")
character.tile_id = 384
second.update
tile = second.charbitmap
check.call(second.instance_variable_get(:@charbitmapAnimated) == false, "tile graphics use raw bitmap state")
check.call(second.bitmap.equal?(tile) && !tile.respond_to?(:update), "tile graphics are not treated as AnimatedBitmap wrappers")
character.tile_id = 0
second.update
check.call(tile.disposed?, "returning from a tile releases its old bitmap")
check.call(second.instance_variable_get(:@charbitmapAnimated) == true, "tile-to-character transition restores wrapper state")
check.call(second.bitmap.equal?(shared) && second.charbitmap.updates == 1, "returning to a character reuses the retained image")
character.character_name = "fixture-other"
second.update
check.call(!second.bitmap.equal?(shared) && !second.bitmap.disposed?, "changing character graphics installs a live replacement")
second.dispose
RPG::Cache.instance_variable_get(:@cache).each_value do |bitmap|
  bitmap.never_dispose = false
  bitmap.dispose unless bitmap.disposed?
end
puts "CHARACTER_BITMAP_PASS checks=#{checks} game_loaded=false"
