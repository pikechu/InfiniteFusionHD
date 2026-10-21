# Exercise mode changes through the real Android Input.update wrapper. Native
# graphics/input are replaced here; device screenshots verify actual rendering.
require_relative "../ruby/kif_android_input"

module Graphics
  class << self
    attr_reader :changes
    def fixed_aspect_ratio=(fixed)
      (@changes ||= []) << [fixed, Thread.current]
    end
  end
end

input = Module.new do
  def self.update; :native_result; end
  def self.press?(_code); false; end
  def self.trigger?(_code); false; end
  def self.repeat?(_code); false; end
  def self.dir4; 0; end
  def self.dir8; 0; end
end
bridge = Object.new
class << bridge
  attr_accessor :mode, :snapshot
  def input_poll; @snapshot || [0, 0, 0]; end
  def display_mode_poll; @mode || 0; end
end
KIF::AndroidInputBackend.install(input, bridge)
checks = 0
check = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
check.call(input.update == :native_result, "display handling changed Input.update return")
check.call(Graphics.changes.map(&:first) == [true], "default must preserve aspect")
3.times { input.update }
check.call(Graphics.changes.length == 1, "unchanged mode recalculates viewport every frame")
Thread.new { bridge.mode = 1 }.join
check.call(Graphics.changes.length == 1, "UI request modified graphics outside game update")
input.update
check.call(Graphics.changes.map(&:first) == [true, false], "stretch was not applied on next update")
check.call(Graphics.changes.all? { |_, thread| thread == Thread.current }, "graphics called off game thread")
bridge.snapshot = [0, 1 << 13, 1 << 13]
input.update
check.call(input.trigger?(13) && !input.press?(13), "mode handling lost short confirm input")
bridge.snapshot = [-1, 0, 0]
bridge.mode = 0
input.update
check.call(Graphics.changes.map(&:first) == [true, false, true], "input failure prevented mode restoration")
bridge.snapshot = nil
bridge.mode = 1
input.update
check.call(Graphics.changes.last.first == false, "second stretch request was lost")
bridge.mode = 2
begin
  input.update
  raise "invalid mode accepted"
rescue ArgumentError
  check.call(Graphics.changes.last.first == false, "invalid mode changed graphics")
end
puts "PASS: #{checks} display mode assertions (mocked native host; no device rendering)"
