# Read installed map fixtures and invoke the real event-start method, without a game/save.
require_relative "../../server/multiplayer/native/rgss_data"
class Tone
  def self._load(*); new; end
end
class Color
  def self._load(*); new; end
end
class Game_Character; end
load File.expand_path("../../Data/Scripts/004_Game classes/008_Game_Event.rb", __dir__)
$door_sounds = []
def pbSEPlay(sound); $door_sounds << sound; end
checks, silent = 0, []
[[1,3], [42,4], [42,5], [79,1], [79,72], [710,1], [710,72], [711,1], [711,72], [79,4], [79,70]].each do |map_id,event_id|
  map = Marshal.load(File.binread(File.expand_path("../../Data/Map%03d.rxdata" % map_id, __dir__)))
  event = map.events.fetch(event_id)
  page = event.pages.first
  original = Marshal.dump(page.list)
  character = Game_Event.allocate
  character.instance_variable_set(:@event, event)
  character.instance_variable_set(:@list, page.list)
  character.instance_variable_set(:@trigger, page.trigger)
  character.instance_variable_set(:@starting, false)
  $door_sounds.clear
  2.times { character.start }
  animated = [4,70].include?(event_id) && map_id == 79
  raise "Door sound duplicated or missing on #{map_id}:#{event_id}" unless $door_sounds == (animated ? [] : ["Entering Door"])
  raise "Door event failed to start" unless character.starting
  raise "Door fix rewrote original event commands" unless Marshal.dump(page.list) == original
  checks += 3
  unless animated
    silent << [map_id, event_id]
    character.clear_starting
    character.start
    raise "Re-entered door lost its sound" unless $door_sounds.length == 2
    checks += 1
  end
end
raise "Bundled door sound missing" unless File.file?(File.expand_path("../../Audio/SE/Entering Door.wav", __dir__))
puts "HOME_DOOR_SOUND_PASS assertions=#{checks+1} repaired_entrances=#{silent.length} maps=1,42,79,710,711"
