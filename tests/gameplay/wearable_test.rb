# Production wearable/player methods with a minimal graphics host. No saves loaded.
module RPG; class Sprite; end; end
class Sprite
  attr_accessor :x, :y, :z, :ox, :oy, :visible, :opacity, :bitmap, :src_rect
  def initialize(*)
    @x = @y = @z = @ox = @oy = 0
    @visible, @opacity = true, 255
    @src_rect = Object.new
    def @src_rect.set(*); end
  end
  def dispose; @disposed = true; end
end
class Sprite_Character < Sprite
  attr_accessor :character, :next_position
  def update
    # The real character updater resolves the bitmap before placing the body.
    getClothedPlayerSprite
    self.x, self.y, self.z, self.visible, self.opacity = next_position
  end
end
def pbResolveBitmap(*); false; end
def echoln(*); end
def _INTL(text, *); text; end
DIRECTION_DOWN, DIRECTION_LEFT, DIRECTION_RIGHT, DIRECTION_UP = 2, 4, 6, 8
$game_map = Object.new
def $game_map.scrolling?; true; end
def $game_map.scroll_direction; DIRECTION_RIGHT; end
load File.expand_path("../../Data/Scripts/005_Sprites/013_Sprite_Wearable.rb", __dir__)
load File.expand_path("../../Data/Scripts/005_Sprites/014_Sprite_Hair.rb", __dir__)
load File.expand_path("../../Data/Scripts/005_Sprites/014_Sprite_Hat.rb", __dir__)
load File.expand_path("../../Data/Scripts/005_Sprites/016_Sprite_Player.rb", __dir__)

player = Sprite_Player.allocate
player.x, player.y, player.z, player.ox, player.oy = 100, 200, 231, 40, 80
player.visible, player.opacity = true, 255
player.character = Struct.new(:pattern, :direction).new(0, 8)
player.instance_variable_set(:@character_name, "walk")
player.instance_variable_set(:@previous_action, "walk")
player.define_singleton_method(:getClothedPlayerSprite) { |*| nil }
layers = [Sprite_Hair.new(player, "", "walk", nil), Sprite_Hat.new(player, "", "walk", nil)]
player.instance_variable_set(:@hair, layers[0])
player.instance_variable_set(:@hat, layers[1])
checks = 0
check = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
[[108, 200, 231, true, 255], [108, 192, 223, false, 255], [108, 200, 231, true, 96],
 [108,200,-1,true,255], [108,200,999,true,255]].each do |position|
  player.next_position = position
  player.update
  layers.each_with_index do |layer, index|
    check.call([layer.sprite.x, layer.sprite.y] == [player.x-player.ox, player.y-player.oy], "Wearable lagged a frame or applied scrolling twice")
    check.call(layer.sprite.visible == player.visible, "Door hid the body but left a visible head")
    check.call(layer.sprite.opacity == player.opacity, "Wearable ignored the player's fade")
    check.call(layer.sprite.z == player.z && layer.sprite.z < player.z+1, "Wearable crosses the roof priority immediately above the body")
  end
end
player.character.pattern = 1
layers.each do |layer|
  layer.animate("walk", 0)
  check.call(layer.sprite.y == player.y-player.oy, "Explicit animation frame zero was ignored")
  layer.animate("walk")
  check.call(layer.sprite.y == player.y-player.oy-2, "Walking bob was lost")
end
class AnimatedBitmap
  attr_reader :bitmap, :releases
  def initialize(name,*)
    raise "fixture decode failure" if name == "broken"
    @bitmap, @releases = Object.new,0
  end
  def dispose; @releases += 1; end
end
def pbResolveBitmap(path); !path.to_s.empty?; end
layer = layers.first
layer.update("walk","first",0)
first = layer.instance_variable_get(:@wearableBitmap)
layer.update("walk","first",0)
check.call(layer.instance_variable_get(:@wearableBitmap).equal?(first),"Unchanged hair/hat reloaded its texture")
layer.update("walk","second",0)
second = layer.instance_variable_get(:@wearableBitmap)
check.call(first.releases == 1,"Replacing hair/hat leaked its old texture")
begin
  layer.update("walk","broken",0)
  raise "broken texture did not fail"
rescue RuntimeError => error
  raise unless error.message == "fixture decode failure"
end
check.call(layer.instance_variable_get(:@wearableBitmap).equal?(second) && second.releases == 0,"Decode failure destroyed the current texture")
layer.update("walk","",0)
check.call(second.releases == 1 && layer.sprite.bitmap.nil?,"Removing a hat retained its texture")
layer.update("walk","last",0)
last = layer.instance_variable_get(:@wearableBitmap)
2.times { layer.dispose }
check.call(last.releases == 1,"Disposing a wearable leaked or double-released its texture")
puts "WEARABLE_MOVEMENT_DOOR_VISIBILITY_AND_FADE_PASS assertions=#{checks}"
