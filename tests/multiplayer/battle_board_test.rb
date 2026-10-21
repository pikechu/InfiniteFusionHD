load File.expand_path("guest_scene_test.rb", __dir__)

module Graphics
  def self.width; 512; end
  def self.height; 384; end
end
class Color
  def initialize(*); end
end
class Viewport < FakeDisposable
  attr_accessor :z
  def initialize(*); end
end
class BoardTestBitmap
  attr_reader :width, :height, :font, :labels
  def initialize(width, height)
    @width, @height, @font, @labels = width, height, OpenStruct.new(:size => 18), []
  end
  def fill_rect(*); end
  def text_size(text); OpenStruct.new(:width => text.length * @font.size / 2.0); end
  def draw_text(x, y, width, height, text, align)
    @labels << [x, y, width, height, text, align, @font.size]
  end
end
class BitmapSprite < FakeDisposable
  attr_reader :bitmap
  def initialize(width, height, _viewport); @bitmap = BoardTestBitmap.new(width, height); end
end
class Pokemon
  attr_accessor :form, :gender, :shiny
  attr_reader :species, :level
  def initialize(species = nil, level = nil, *)
    @species, @level, @totalhp, @hp = species, level, 100, 100
  end
end
class PokemonSprite < FakeDisposable
  attr_accessor :x, :y, :ox, :oy, :zoom_x, :zoom_y
  attr_reader :bitmap, :pokemon
  def initialize(_viewport); @bitmap = BoardTestBitmap.new(768, 640); end
  def setPokemonBitmap(pokemon); @pokemon = pokemon; end
end
def pbSetSystemFont(_bitmap); end
def KIFMultiplayer.log_error(error)
  (@board_test_errors ||= []) << error
end

def board_document(count)
  battlers = count.times.map do |index|
    {"index" => index, "species" => "PIKACHU", "name" => "A long public Pokemon nickname", "hp" => 43,
     "totalhp" => 100, "status" => index == 0 ? "PARALYSIS" : "NONE"}
  end
  public = battlers.map do |entry|
    {"slot" => entry["index"], "party_index" => 0, "species" => entry["species"], "level" => 61,
     "form" => 2, "gender" => 1, "shiny" => true, "name" => entry["name"], "hp" => 80,
     "totalhp" => 100, "status" => "NONE", "appearance" => {"shinyR" => 4,
       "shinyKRS" => [0, 0, 0, 0, 0, 0, 0, 0, 0], "size_category" => "SMALL"}}
  end
  {"battlers" => battlers, "visuals" => {"version" => 1, "seq" => 1, "complete" => true,
                                       "events" => [], "battlers" => public}}
end

[3, 4].each do |count|
  document = board_document(count)
  before = Marshal.dump(document)
  board = KIFMultiplayer::BattleBoard.new(document)
  sprites = board.instance_variable_get(:@sprites)
  labels = sprites.first.bitmap.labels
  assert(sprites.length == count + 1 && labels.length == count * 3, "Board omitted a public sprite or independent label")
  assert(sprites.first.bitmap.font.size == 20 && labels.all? { |row| row[6] <= 20 }, "Board changed global/default font sizing")
  sprites.drop(1).each_with_index do |sprite, index|
    left, right = index * 512 / count, (index + 1) * 512 / count
    assert(sprite.x - sprite.ox * sprite.zoom_x >= left + 7 &&
           sprite.x + (sprite.bitmap.width - sprite.ox) * sprite.zoom_x <= right - 7,
           "Large public sprite escaped its own column")
    assert(sprite.y - sprite.oy * sprite.zoom_y >= 27 && sprite.y == (384 * 0.48).to_i,
           "Public sprite did not share a safe bottom baseline")
    assert(sprite.pokemon.shiny && sprite.pokemon.form == 2 && sprite.pokemon.gender == 1 && sprite.pokemon.level == 61,
           "Board lost validated shiny/form/gender/level")
    assert(sprite.pokemon.instance_variable_get(:@shinyR) == 4 &&
           sprite.pokemon.instance_variable_get(:@size_category) == :SMALL,
           "Board lost validated custom appearance")
    assert(!sprite.pokemon.instance_variable_get(:@shinyKRS).equal?(document["visuals"]["battlers"][index]["appearance"]["shinyKRS"]),
           "Temporary display object retained a mutable authority appearance array")
    column = labels[index * 3, 3]
    assert(column.all? { |x, _, width, _, _, _, _| x >= left && x + width <= right } &&
           column.first[1] > sprite.y && column.map { |row| row[1] }.uniq.length == 3,
           "Name/HP/status labels overlap sprite or another column")
    assert(column[1][4] == "43/100 HP" && column[2][4] == (index == 0 ? "PARALYSIS" : "Healthy"),
           "Board presented old timeline HP/status instead of final authority state")
  end
  assert(Marshal.dump(document) == before, "Board mutated public network input")
  board.dispose
  assert(sprites.all?(&:disposed?) && board.instance_variable_get(:@viewport).disposed?, "Board left native resources alive")
end

invalid = board_document(3)
invalid["visuals"]["battlers"][0]["appearance"]["size_category"] = {"execute" => "invalid"}
board = KIFMultiplayer::BattleBoard.new(invalid)
assert(board.instance_variable_get(:@sprites).empty? && !board.instance_variable_get(:@viewport),
       "Unvalidated public appearance reached native display allocation")
assert(KIFMultiplayer.instance_variable_get(:@board_test_errors).last.is_a?(KIFMultiplayer::Error),
       "Invalid public appearance did not report a safe display failure")
legacy = board_document(3)
legacy.delete("visuals")
legacy["battlers"][0]["appearance"] = {"size_category" => "SUPER"}
board = KIFMultiplayer::BattleBoard.new(legacy)
assert(!board.instance_variable_get(:@sprites)[1].pokemon.instance_variable_defined?(:@size_category),
       "Board trusted unvalidated appearance outside public visuals")
board.dispose
puts "PASS: #{$checks} battle/Boss/guest/board checks; native screenshot acceptance is separate"
