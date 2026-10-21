# Actual title/animation methods, with frame input and sprites supplied by the host.
# No SDL, assets, network, or player saves are loaded. An optional source argument
# lets the same regression run against the unchanged pre-fix script in temp/.
module Input
  DOWN = 2; B = 12; C = 13; CTRL = 17; LEFT = 4; RIGHT = 6
  class << self
    attr_reader :updates
    def reset(events = {}, held = false)
      @events = events; @updates = 0; @pressed = held; @triggered = false
    end
    def update
      @updates += 1
      @triggered = false
      case @events[@updates]
      when :tap then @triggered = true; @pressed = false
      when :down then @triggered = !@pressed; @pressed = true
      when :up then @pressed = false
      end
    end
    def trigger?(code); code == C && @triggered; end
    def press?(code); code == C && @pressed; end
  end
end

class FrameBudgetExceeded < StandardError; end
module Graphics
  class << self
    attr_accessor :limit
    attr_reader :updates
    def reset(limit)
      @updates = 0; @limit = limit
    end
    def update
      @updates += 1
      raise FrameBudgetExceeded, "title never accepted the single C edge" if @updates > @limit
    end
  end
end

class Tone
  attr_reader :red
  def initialize(red, *_rest); @red = red; end
end
class TitleTestSprite
  attr_accessor :x, :y, :ox, :opacity, :tone, :bitmap, :visible
  def initialize
    @x = @y = @ox = 0; @opacity = 255; @tone = Tone.new(0)
  end
end
NB_POKEMON = 501
def getRandomCustomFusionForIntro(*_args); [1, 4]; end
def getSpeciesIdForFusion(body, head); body * NB_POKEMON + head; end
module GameData
  module Species
    def self.sprite_bitmap_from_pokemon_id(_id)
      Struct.new(:bitmap).new(:host_bitmap)
    end
  end
end
class Scene_Intro
  def main; end # The real addon aliases its earlier definition when loaded.
end

root = File.expand_path("../..", __dir__)
load(ARGV[0] || File.join(root, "Data/Scripts/052_AddOns/IntroScreen.rb"))

checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
build = lambda do |colliding|
  screen = GenOneStyle.allocate
  sprites = %w[effect poke 2poke fpoke selector star bg bars logo poke2 2poke2].map do |key|
    [key, TitleTestSprite.new]
  end.to_h
  sprites["poke"].x = colliding ? 0 : 400
  sprites["2poke"].x = colliding ? 0 : -150
  { :@sprites => sprites, :@currentFrame => 0, :@totalFrames => 10_000,
    :@speed => 1, :@skip => false, :@maxPoke => 10, :@customPokeList => [],
    :@prevPoke1 => 1, :@prevPoke2 => 4, :@selector_pos => 0 }.each do |name, value|
    screen.instance_variable_set(name, value)
  end
  scene = Scene_Intro.allocate
  scene.instance_variable_set(:@screen, screen)
  scene.define_singleton_method(:closeTitle) { @test_closes = (@test_closes || 0) + 1 }
  [scene, screen]
end

# These are real GenOneStyle.update -> Object#wait(150) -> Scene_Intro.update
# calls. Input drops a trigger at the next update, as both native RGSS and the
# Android queue do; keeping C held does not create another trigger.
[
  ["tap at first wait frame", true, { 1 => :tap }, false, 2, false],
  ["tap midway through wait", true, { 75 => :tap }, false, 76, false],
  ["tap at last wait frame", true, { 150 => :tap }, false, 151, false],
  ["held C beginning in wait", true, { 20 => :down }, false, 21, false],
  ["tap in outer frame after full wait", true, { 151 => :tap }, false, 151, true],
  ["tap while the two sprites move", false, { 1 => :tap }, false, 1, true],
  ["old held C waits for a fresh press", true, { 153 => :up, 154 => :down }, true, 154, true]
].each do |label, colliding, events, held, expected_updates, last_edge|
  scene, = build.call(colliding)
  Input.reset(events, held)
  Graphics.reset(200)
  scene.update
  assert.call(scene.instance_variable_get(:@test_closes) == 1, "#{label}: did not open load screen once")
  assert.call(Input.updates == expected_updates, "#{label}: unexpected extra frame/input updates")
  assert.call(Input.trigger?(Input::C) == last_edge, "#{label}: input trigger lifetime changed")
end

# One confirmation in the actual intro skips the cinematic waits and continues
# through the title without needing a second press or replaying an input edge.
scene, screen = build.call(false)
Input.reset({ 1 => :tap })
Graphics.reset(20)
screen.intro
scene.update
assert.call(scene.instance_variable_get(:@test_closes) == 1, "intro confirmation required a second press")
assert.call(Input.updates == 2 && !Input.trigger?(Input::C), "intro edge was replayed instead of preserved locally")

scene, = build.call(true)
Input.reset
Graphics.reset(180)
begin
  scene.update
  raise "idle title opened a load screen without confirmation"
rescue FrameBudgetExceeded
  assert.call(scene.instance_variable_get(:@test_closes).nil?, "idle animation acted as confirmation")
end
puts "PASS: #{checks} title input assertions (actual title, animation and wait methods; mocked native frames)"
