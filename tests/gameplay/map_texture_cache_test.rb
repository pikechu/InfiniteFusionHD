# Exercise the production texture banks without starting the graphics runtime.
class Sprite; end
def nil_or_empty?(value); value.nil? || value.empty?; end
load File.expand_path("../../Data/Scripts/006_Map renderer/001_TilemapRenderer.rb", __dir__)
module TilemapRenderer::AutotileExpander
  def self.expand(bitmap); bitmap; end
end
class CacheTestBitmap
  attr_reader :width, :height, :disposals
  def initialize(width, height); @width, @height, @disposals = width, height, 0; end
  def mega?; false; end
  def dispose; @disposals += 1; end
  def disposed?; @disposals > 0; end
end
$texture_loads = Hash.new(0)
def pbGetTileset(name)
  $texture_loads[name] += 1
  CacheTestBitmap.new(1024, 4096) # 16 MiB
end
def pbGetAutotile(name)
  $texture_loads[name] += 1
  CacheTestBitmap.new(1024, 1024) # 4 MiB, 32 animation frames
end
checks = 0
check = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1 }
[TilemapRenderer::TilesetBitmaps, TilemapRenderer::AutotileBitmaps].each do |klass|
  bank = klass.new
  bank.define_singleton_method(:cache_limit) { 2 * (klass == TilemapRenderer::TilesetBitmaps ? 16 : 4) * 1024 * 1024 }
  prefix = klass.name
  a, b, c, active = %w[a b c active].map { |name| prefix + name }
  bank.add(a)
  original = bank[a]
  bank.add(a)
  bank.remove(a)
  check.call(!original.disposed?, "shared texture survives one owner releasing it")
  bank.remove(a)
  bank.remove(a)
  bank.add(b)
  bank.remove(b)
  bank.add(a)
  check.call(bank[a].equal?(original) && $texture_loads[a] == 1, "returning to a room reuses its decoded texture")
  bank.add(active)
  active_bitmap = bank[active]
  bank.remove(a)
  bank.add(c)
  bank.remove(c)
  check.call(!bank[b] && bank[a].equal?(original), "evicts the least recently used inactive texture")
  check.call(!active_bitmap.disposed?, "memory pressure never evicts active textures")
  check.call(bank.instance_variable_get(:@unused).sum { |name| bank[name].width * bank[name].height * 4 } <= bank.cache_limit, "inactive memory stays within budget")
  if bank.is_a?(TilemapRenderer::AutotileBitmaps)
    check.call(bank.frame_count(a) == 32 && bank.current_frames.key?(a), "cached animation metadata survives reuse")
    check.call(!bank.current_frames.key?(b) && !bank.instance_variable_get(:@frame_durations).key?(b), "eviction releases animation metadata")
  end
  bank.bitmaps.each_value(&:dispose)
  check.call(original.disposals == 1 && active_bitmap.disposals == 1, "shutdown releases active and cached textures exactly once")
end
puts "MAP_TEXTURE_CACHE_PASS checks=#{checks}"
