load "Data/Scripts/054_Multiplayer/001_Client.rb"
module KIFMultiplayer; class UI; end; end
load "Data/Scripts/054_Multiplayer/029_OriginalUI.rb"
load "Data/Scripts/054_Multiplayer/026_OriginalCharacters.rb"

model = Object.new
model.instance_variable_set(:@calls, [])
model.define_singleton_method(:act) do |kind, _|
  @calls << kind
  raise KIFMultiplayer::UncertainRequest.new("truncated", "unreachable") if @calls.length == 1
  {"events" => []}
end
model.define_singleton_method(:refresh) { @calls << "recover"; self }
model.define_singleton_method(:calls) { @calls }
model.define_singleton_method(:original) { {"view" => {"battle" => nil}} }
ui = Object.new
ui.define_singleton_method(:current_model=) { |_| }
ui.define_singleton_method(:perform) { |&block| block.call }
renderer = Struct.new(:connection_status).new
scene = KIFMultiplayer::OriginalWorldScene.new(model,ui)
scene.instance_variable_set(:@renderer, renderer)
scene.define_singleton_method(:adopt) { }
raise "Uncertain idle wait was not deferred" unless scene.act("wait").nil? && renderer.connection_status
scene.act("move", {"direction" => 2})
raise "A new action preceded pending recovery" unless model.calls == ["wait", "recover"] && renderer.connection_status.nil?
scene.act("move", {"direction" => 2})
raise "Recovered controls stayed blocked" unless model.calls == ["wait", "recover", "move"]
model.define_singleton_method(:act) { |*| raise KIFMultiplayer::UncertainRequest, "economic uncertainty" }
begin
  scene.act("interact")
  raise "Non-idle uncertainty was silently retried"
rescue KIFMultiplayer::UncertainRequest
end
puts "ORIGINAL_IDLE_RECOVERY_BEFORE_NEXT_INTENT_PASS"
client = Object.new
client.define_singleton_method(:request) { |*| raise KIFMultiplayer::UncertainRequest, "temporary heartbeat loss" }
presence = KIFMultiplayer::OriginalClient.allocate
presence.instance_variable_set(:@client,client)
presence.instance_variable_set(:@original,{"active" => true})
raise "Heartbeat loss closed the native world" unless presence.heartbeat == false
presence.instance_variable_set(:@heartbeat_at,nil)
client.define_singleton_method(:request) { |*| raise KIFMultiplayer::HTTPRejected.new("banned","account_banned") }
begin
  presence.heartbeat
  raise "An authoritative account rejection was suppressed"
rescue KIFMultiplayer::HTTPRejected
end
puts "ORIGINAL_PRESENCE_FAILURE_KEEPS_WORLD_AND_REJECTIONS_VISIBLE_PASS"
