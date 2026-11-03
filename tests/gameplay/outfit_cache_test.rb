# Exercise production ownership/invalidation with counted graphics resources.
class TestBitmap
  attr_reader :released
  def initialize; @released = false; end
  def copy; TestBitmap.new; end
  def rect; nil; end
  def blt(*); raise "disposed bitmap used" if disposed?; end
  def dispose; raise "double dispose" if @released; @released = true; end
  def disposed?; @released; end
end
class AnimatedBitmap
  attr_reader :bitmap
  class << self; attr_accessor :created; end
  self.created = []
  def initialize(*)
    @bitmap = TestBitmap.new
    self.class.created << self
  end
  def dispose; @bitmap.dispose; end
end
class Sprite_Character
  def dispose; end
end
module Settings; PLAYER_TEMP_OUTFIT_FALLBACK = "fallback"; end
def pbResolveBitmap(path); path != "missing"; end
def getOverworldOutfitFilename(id, action = "walk"); "#{id}/#{action}"; end
def getOverworldHairFilename(id); id; end
def getOverworldHatFilename(id); id; end
class TestLayer
  attr_reader :updates
  def initialize; @updates = 0; end
  def update(*); @updates += 1; end
  def dispose; end
end
load File.expand_path("../../Data/Scripts/005_Sprites/016_Sprite_Player.rb", __dir__)
$Trainer = Struct.new(:skin_tone,:clothes,:hair,:hat,:clothes_color,:hair_color,:hat_color).new(0,"coat","hair","hat",0,0,0)
player = Sprite_Player.allocate
base = AnimatedBitmap.new("base")
player.instance_variable_set(:@charbitmap,base)
player.instance_variable_set(:@hair,TestLayer.new)
player.instance_variable_set(:@hat,TestLayer.new)
checks = 0
check = ->(condition,label) { raise label unless condition; checks += 1 }
seen = []
48.times do |frame|
  player.instance_variable_set(:@character_name,frame.even? ? "walk" : "run")
  seen << player.getClothedPlayerSprite
end
check.call(seen.uniq.length == 2,"Repeated actions allocate new outfit sheets")
check.call(!seen.any?(&:disposed?),"Active outfit sheets were released early")
check.call(AnimatedBitmap.created.drop(1).all? { |wrapper| wrapper.bitmap.disposed? },"Temporary outfit source was not released")
[:skin_tone,:clothes,:hair,:hat,:clothes_color,:hair_color,:hat_color].each do |field|
  old = seen.last
  value = $Trainer.public_send(field)
  $Trainer.public_send("#{field}=",value.is_a?(Integer) ? value+1 : value+"2")
  seen << player.getClothedPlayerSprite
  check.call(old.disposed?,"Appearance change retained an old outfit: #{field}")
end
old = seen.last
player.refreshOutfit
check.call(player.instance_variable_get(:@manual_refresh),"Outfit refresh did not reload the base skin")
seen << player.getClothedPlayerSprite
check.call(old.disposed?,"Explicit outfit refresh retained old actions")
old = seen.last
seen << player.getClothedPlayerSprite(true)
check.call(old.disposed?,"Forced rebuild retained the old outfit")
player.dispose
check.call(seen.all?(&:disposed?),"Outfit sheets survived player disposal")
check.call(!base.bitmap.disposed?,"Disposing a composite released the shared base")
base.dispose
puts "OUTFIT_ACTION_CACHE_INVALIDATION_AND_OWNERSHIP_PASS assertions=#{checks}"
