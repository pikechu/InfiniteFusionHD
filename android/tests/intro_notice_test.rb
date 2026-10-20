# Exercise the real interpreter dispatch with the checked-in upstream event fixture.
require "json"
module System
  class << self
    attr_accessor :android_host
    def is_android?; !!@android_host; end
  end
end
module RPG
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code = 0, indent = 0, parameters = [])
      @code, @indent, @parameters = code, indent, parameters
    end
  end
end
class Interpreter
  attr_reader :depth, :list, :event_id, :child_interpreter
  def initialize(depth = 0); @depth = depth; end
  def setup(list, event_id); @list, @event_id = list, event_id; end
end
root = File.expand_path("../..", __dir__)
load File.join(root, "Data/Scripts/000_Platform.rb")
load File.join(root, "Data/Scripts/003_Game processing/004_Interpreter_Commands.rb")
fixture = JSON.parse(File.read(File.join(__dir__, "fixtures/common-event-108.json")))
list = fixture.fetch("commands").map { |c| RPG::EventCommand.new(c.fetch("code"), c.fetch("indent"), c.fetch("parameters")) }
IntroNoticeEventFixture = Struct.new(:name, :trigger, :list)
event = IntroNoticeEventFixture.new(fixture.fetch("name"), fixture.fetch("trigger"), list)
before = Marshal.dump(event)
checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
System.android_host = false
assert.call(KIF::Platform.common_event_commands(108, event).equal?(list), "Desktop survey changed")
System.android_host = true
assert.call(KIF::Platform.common_event_commands(107, event).equal?(list), "Other event overridden")
replacement = KIF::Platform.common_event_commands(108, event)
assert.call(!replacement.equal?(list), "Android notice not installed for verified event")
assert.call(Marshal.dump(event) == before, "Original database event was mutated")
text = replacement.select { |c| [101, 401].include?(c.code) }.flat_map(&:parameters).join(" ")
assert.call(text.include?("independent test port") && text.include?("not an official upstream release"), "Notice misrepresents source")
scripts = replacement.select { |c| c.code == 355 }.flat_map(&:parameters)
assert.call(scripts == ["pbSet(5,4)"], "Notice fabricates official survey answer or changes other game state")
assert.call(replacement.map(&:code) == [101, 401, 101, 401, 355, 115, 0], "Notice does not use normal messages and return")

[[4, :code, 655], [9, :parameters, ["different survey"]], [84, :parameters, ["new upstream behavior"]]].each do |index, field, value|
  changed = Marshal.load(before)
  changed.list[index].public_send("#{field}=", value)
  assert.call(KIF::Platform.common_event_commands(108, changed).equal?(changed.list), "Changed event signature was silently overridden")
end
changed = Marshal.load(before); changed.name = "new event"
assert.call(KIF::Platform.common_event_commands(108, changed).equal?(changed.list), "Reused event id was overridden")
changed = Marshal.load(before); changed.trigger = 1
assert.call(KIF::Platform.common_event_commands(108, changed).equal?(changed.list), "Changed event trigger was overridden")
changed = Marshal.load(before); changed.list.pop
assert.call(KIF::Platform.common_event_commands(108, changed).equal?(changed.list), "Changed event length was overridden")

$data_common_events = []; $data_common_events[108] = event
parent = Interpreter.new(2)
parent.setup([RPG::EventCommand.new(117, 0, [108]), RPG::EventCommand.new], 4)
parent.instance_variable_set(:@index, 0)
assert.call(parent.execute_command, "Actual common-event dispatch failed")
child = parent.child_interpreter
assert.call(child.depth == 3 && child.event_id == 4, "Child interpreter context was lost")
assert.call(child.list.map(&:code) == replacement.map(&:code), "Actual interpreter used unsafe original survey")
child.instance_variable_set(:@index, 5)
assert.call(child.execute_command && child.list.nil?, "Notice cannot finish its child interpreter")
assert.call(!parent.list.nil?, "Notice ended the parent story interpreter")
puts "PASS: #{checks} intro notice assertions (real command dispatch; no game/saves executed)"
