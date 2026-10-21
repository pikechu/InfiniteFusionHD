# Renamed/imported saves must never write back to a different manual slot.
require "tmpdir"
require "digest"
module System
  class << self
    attr_accessor :android_host
    def is_android?; !!@android_host; end
  end
end
module SaveData
  MANUAL_SLOTS = ("A".."H").map { |letter| "File #{letter}" }.freeze
end
class SlotTestPlayer
  attr_accessor :save_slot
  def initialize(slot); @save_slot = slot; end
end
root = File.expand_path("../..", __dir__)
load File.join(root, "Data/Scripts/000_Platform.rb")
checks = 0
assert = lambda do |condition, message|
  raise message unless condition
  checks += 1
end
make = lambda { { player: SlotTestPlayer.new("File E"), kuray_player: SlotTestPlayer.new("File E"), bag: [:original] } }
System.android_host = false
data = make.call
assert.call(KIF::Platform.prepare_loaded_save(data, "File D").equal?(data), "Windows data identity changed")
assert.call(data.values_at(:player, :kuray_player).all? { |p| p.save_slot == "File E" }, "Windows slot was rewritten")
System.android_host = true
SaveData::MANUAL_SLOTS.each do |selected|
  data = make.call
  bag = data[:bag]
  assert.call(KIF::Platform.prepare_loaded_save(data, selected).equal?(data), "Manual load replaced save hash")
  assert.call(data[:player].save_slot == selected && data[:kuray_player].save_slot == selected, "Vanilla/modded clone did not both bind to #{selected}")
  assert.call(data[:bag].equal?(bag), "Unrelated save component changed")
end
["Auto 1", "Auto 2", "File Z", nil].each do |selected|
  data = make.call
  KIF::Platform.prepare_loaded_save(data, selected)
  assert.call(data.values_at(:player, :kuray_player).all? { |p| p.save_slot == "File E" }, "Auto/unknown slot replaced the original manual destination")
end
assert.call(KIF::Platform.prepare_loaded_save(nil, "File D").nil?, "Invalid data changed")
assert.call(KIF::Platform.prepare_loaded_save({}, "File D") == {}, "Missing players were fabricated")
Dir.mktmpdir("loaded-slot-", File.join(root, "temp")) do |work|
  original = File.join(work, "File E.rxdata")
  target = File.join(work, "File D.rxdata")
  File.binwrite(original, Marshal.dump(make.call))
  baseline = File.binread(original)
  # A byte-only SAF import can rename E to D without deserializing anything.
  File.binwrite(target, baseline)
  loaded = Marshal.load(File.binread(target))
  KIF::Platform.prepare_loaded_save(loaded, "File D")
  # Model the next save's actual destination from the modded Player clone.
  destination = File.join(work, loaded[:kuray_player].save_slot + ".rxdata")
  File.binwrite(destination, Marshal.dump(loaded))
  assert.call(destination == target, "Next save escaped selected imported slot")
  assert.call(File.binread(original) == baseline, "Original slot was overwritten")
  restored = Marshal.load(File.binread(target))
  assert.call(restored[:player].save_slot == "File D" && restored[:kuray_player].save_slot == "File D", "Rebound target did not persist")
end
puts "PASS: #{checks} loaded-slot assertions (real Marshal/files; no game/player saves loaded)"
