# Scene-lifetime fault tests, separate from real Game.exe acceptance.
require "ostruct"
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
raise "Run this stub suite in standalone Ruby" if defined?(System)
class PokeBattle_Battle; end
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/002_UI.rb"
load "Data/Scripts/054_Multiplayer/003_Battle.rb"
load "Data/Scripts/054_Multiplayer/008_Hall.rb"
load "Data/Scripts/054_Multiplayer/012_Replay.rb"
class PokemonSystem
  attr_accessor :download_sprites
  def initialize; @download_sprites = 0; end
end
module Graphics
  def self.frame_reset; end
end
class Scene_Map
  def miniupdate; $review_world_updates += 1; end
end
def pbMessage(_text, *_args)
  $scene.miniupdate if $scene.is_a?(Scene_Map)
  raise IOError, "Injected message-render failure" if $review_message_failure
end
class SceneReviewBoard
  def dispose; $review_disposals += 1; end
end
KIFMultiplayer::BattleBoard.define_singleton_method(:new) { |_state| SceneReviewBoard.new }
KIFMultiplayer::ReplayData.define_singleton_method(:validate) { |value, _compat| value["data"] }
KIFMultiplayer.define_singleton_method(:log_error) { |error| ($review_cleanup_errors ||= []) << error }
client = OpenStruct.new(:wait_update => proc {}, :compatibility => {})
def client.pump; $scene.miniupdate if $scene.is_a?(Scene_Map); end
checks, failures = 0, []
verify = lambda do |condition, name|
  checks += 1
  failures << name unless condition
  puts("#{condition ? 'PASS' : 'FAIL'} #{name}")
end
originals = [{"party" => [1]}, {"items" => [2]}, {"progress" => [3]}, PokemonSystem.new, {}, {}]
$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables = originals
original_bytes = originals.map { |value| Marshal.dump(value) }
original_scene, callback = Scene_Map.new, client.wait_update
replay = {"id" => "replay_scene_guard", "data" => {"updates" => [{"turn" => 0, "state" => {"events" => ["Recorded event"]}}], "result" => {"reason" => "recorded_result"}}}
[false, true].each do |inject_failure|
  $scene, $review_world_updates, $review_disposals, $review_message_failure = original_scene, 0, 0, inject_failure
  begin
    KIFMultiplayer.play_replay(client, replay, false)
  rescue IOError
  end
  verify.call($review_world_updates == 0, "manual replay #{inject_failure ? 'failure' : 'normal'} never updates the original map")
  verify.call($scene.equal?(original_scene) && client.wait_update.equal?(callback), "manual replay restores original scene and callback")
  verify.call($review_disposals == 1 && originals.map { |value| Marshal.dump(value) } == original_bytes, "manual replay disposes board and restores original save globals")
end
$review_message_failure = false
session = Object.new
def session.map_compatible?; false; end
def session.close; raise IOError, "Injected departure profile write failure"; end
hall = KIFMultiplayer::HallScene.allocate
hall.instance_variable_set(:@session, session)
hall.instance_variable_set(:@client, client)
hall.instance_variable_set(:@avatars, {})
hall.instance_variable_set(:@sprites, {})
def hall.menu_fallback; :returned; end
$scene, client.wait_update = original_scene, callback
begin
  hall.run
rescue IOError
end
verify.call($scene.equal?(original_scene), "hall departure persistence failure restores original map scene")
verify.call(client.wait_update.equal?(callback), "hall departure persistence failure restores original callback")
verify.call(($review_cleanup_errors || []).length == 1, "hall departure failure is recorded without masking scene cleanup")
KIFMultiplayer.define_singleton_method(:client) { client }
KIFMultiplayer::UI.define_method(:main) do
  pbMessage("online menu")
  raise KIFMultiplayer::Error, "injected menu failure" if $review_menu_failure
end
[false, true].each do |inject_failure|
  $scene, $review_world_updates, $review_menu_failure = original_scene, 0, inject_failure
  KIFMultiplayer.open_menu
  verify.call($review_world_updates == 0, "online menu #{inject_failure ? 'error' : 'normal'} never updates original world while waiting")
  verify.call($scene.equal?(original_scene) && Marshal.dump($PokemonSystem) == original_bytes[3], "online menu restores original scene and single-player settings")
end
puts("SCENE_RESTORE_#{failures.empty? ? 'PASS' : 'FAIL'} checks=#{checks} failures=#{failures.length}")
exit(failures.empty? ? 0 : 1)
