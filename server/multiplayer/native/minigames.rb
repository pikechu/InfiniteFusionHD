# frozen_string_literal: true
# Original reel motion, slipping, line rules, payouts, replay and coin limits
# execute unchanged. Only bitmap presentation and input acquisition are adapted.
module KIFNative
  class << self; attr_accessor :minigame; end
  class MiniRect
    attr_accessor :x, :y, :width, :height
    def initialize(x = 0, y = 0, width = 0, height = 0); set(x,y,width,height); end
    def set(x,y,width,height); @x,@y,@width,@height = x,y,width,height; end
  end
  class MiniBitmap
    attr_reader :width, :height
    def initialize(width = 512, height = 384); @width,@height = width,height; end
    def clear; end
    def blt(*); end
    def dispose; end
    def rect; MiniRect.new(0,0,@width,@height); end
  end
  class MiniSprite
    attr_accessor :visible, :mirror, :bitmap, :x, :y, :z, :angle, :opacity
    attr_reader :src_rect
    def initialize; @bitmap = MiniBitmap.new; @src_rect = MiniRect.new; @x=@y=@z=@angle=0; @opacity=255; end
    def setBitmap(*); @bitmap = MiniBitmap.new; end
    def dispose; end
  end
end

def pbDrawImagePositions(*); raise "graphics_unavailable_on_server" unless KIFNative.minigame; end
def pbDrawShadowText(*); raise "graphics_unavailable_on_server" unless KIFNative.minigame; end

class VoltorbFlip
  attr_reader :current_key
  alias native_original_new_game pbNewGame
  def pbNewGame
    KIFNative.minigame = self
    @current_key = nil
    native_original_new_game
  end
  def pbCreateSprites
    @viewport = Viewport.new
    %w[bg text level curtain curtainL curtainR numbers total coins mark memo cursor icon animation].each { |name| @sprites[name] = KIFNative::MiniSprite.new }
    6.times { |index| @sprites[index] = KIFNative::MiniSprite.new }
    @sprites["curtainL"].angle = -180
    @cursor[0] = [@directory + "cursor",128,0,0,0,64,64]
  end
  def update; end
  def advance_input; @current_key = nil; end
  def pbUpdateRowNumbers(*); end
  def pbUpdateColumnNumbers(*); end
  def pbUpdateCoins; end
  def pbShowAndDispose; end
  def pbScene
    until @quit
      rows = 5.times.map do |row|
        entries = @squares[row*5,5]
        [entries.sum { |entry| entry[2] }, entries.count { |entry| entry[2] == 0 }]
      end
      columns = 5.times.map do |column|
        entries = 5.times.map { |row| @squares[row*5+column] }
        [entries.sum { |entry| entry[2] }, entries.count { |entry| entry[2] == 0 }]
      end
      selected = KIFNative.scene.ask("voltorb", {"level" => @level, "points" => @points, "coins" => $Trainer.coins,
        "rows" => rows, "columns" => columns, "tiles" => @squares.map { |entry| entry[3] ? entry[2] : nil },
        "marks" => @marks.map { |entry| [(entry[2] / 64).to_i, ((entry[1] - 128) / 64).to_i] }})
      if selected["row"] < 0
        @current_key = Input::BACK
        getInput
      else
        @index = [selected["column"], selected["row"]]
        if selected["mark"]
          @current_key = Input::ACTION
          getInput
        end
        @current_key = Input::USE
        getInput
        if selected["mark"]
          @current_key = Input::ACTION
          getInput
        end
      end
      @current_key = nil
    end
  end
  def pbEndScene; KIFNative.minigame = nil; end
end
module Input
  UP = :up
  LEFT = :left
  RIGHT = :right
end
class Rect < KIFNative::MiniRect; end
class Viewport
  attr_accessor :z, :color, :rect
  def initialize(x = 0, y = 0, width = 0, height = 0)
    @rect, @color = Rect.new(x,y,width,height), Color.new(0,0,0,0)
  end
  def dispose; end
end
class AnimatedBitmap
  attr_reader :bitmap
  def initialize(*)
    raise "graphics_unavailable_on_server" unless KIFNative.minigame
    @bitmap = KIFNative::MiniBitmap.new
  end
  def dispose; end
end
module KIFNativeMiniBitmapSprite
  def initialize(width = 0, height = 0, *)
    return super unless KIFNative.minigame
    @bitmap = KIFNative::MiniBitmap.new(width,height)
  end
end
BitmapSprite.prepend(KIFNativeMiniBitmapSprite)

module KIFNativeSlotInput
  def update
    KIFNative.minigame ? KIFNative.minigame.advance_input : super
  end
  def trigger?(key)
    KIFNative.minigame ? KIFNative.minigame.current_key == key : super
  end
end
Input.singleton_class.prepend(KIFNativeSlotInput)
module Input
  DOWN = :down
end

class SlotMachineScene
  attr_reader :current_key
  def pbStartScene(difficulty)
    @native_difficulty = difficulty
    KIFNative.minigame = self
    @sprites = {}
    3.times { |index| @sprites["reel#{index+1}"] = SlotMachineReel.new(0,0,difficulty) }
    @sprites["credit"] = SlotMachineScore.new(0,0,$Trainer.coins)
    @sprites["payout"] = SlotMachineScore.new(0,0,0)
    %w[bg button1 button2 button3 row1 row2 row3 row4 row5 light1 light2 window1 window2].each { |name| @sprites[name] = KIFNative::MiniSprite.new }
    @wager = 0
    update
  end
  def update
    @sprites.each_value { |sprite| sprite.update if sprite.respond_to?(:update) }
  end
  alias native_original_payout pbPayout
  def pbPayout
    @native_payout = true
    native_original_payout
  ensure
    @native_payout = false
  end
  def advance_input
    @current_key = nil
    if @native_payout || @gameEnd
      @current_key = Input::USE
      return
    end
    return if !@gameRunning && (@wager >= 3 || @replay || @sprites["credit"].score >= Settings::MAX_COINS)
    unless @native_pending_key
      before = KIFNative.clock
      mode = @gameRunning ? "stop" : "wager"
      selected = KIFNative.scene.ask("slot", {"mode" => mode, "difficulty" => @native_difficulty,
        "credit" => @sprites["credit"].score, "wager" => @wager,
        "reels" => (1..3).map { |index| @sprites["reel#{index}"].showing },
        "spinning" => (1..3).map { |index| @sprites["reel#{index}"].spinning }})
      @native_pending_key = mode == "stop" ? Input::USE : [Input::DOWN,Input::USE,Input::BACK].fetch(selected)
      frames = [[((KIFNative.clock - before) * Graphics.frame_rate).floor, 1].max, 2**53 - 1].min
      # After all pending slips finish, full reel rotations have no effect on
      # game state. Keep the exact remainder without replaying hours of pixels.
      cycle = SlotMachineReel::ICONSPOOL[@native_difficulty].length * (48 / SlotMachineReel::SCROLLSPEED)
      @native_wait_frames = frames > 1024 ? 1024 + (frames - 1024) % cycle : frames
    end
    if @native_wait_frames > 0
      @native_wait_frames -= 1
    else
      @current_key, @native_pending_key = @native_pending_key, nil
    end
  end
  def pbEndScene
    KIFNative.minigame = nil
  end
end
