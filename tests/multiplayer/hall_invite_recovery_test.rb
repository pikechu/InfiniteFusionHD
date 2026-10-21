require "ostruct"
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/002_UI.rb"
load "Data/Scripts/054_Multiplayer/008_Hall.rb"
directory = File.join(root, "temp", "multiplayer", "cr-20261020", "hall-invite-#{Process.pid}")
require "fileutils"
FileUtils.mkdir_p(directory)
class HallInviteProfile < KIFMultiplayer::Profile
  attr_accessor :fail_on
  attr_reader :writes
  def initialize(path); @writes = 0; super(path); end
  def save
    @writes += 1
    raise IOError, "Injected invitation write failure" if @writes == @fail_on
    super
  end
end
checks, failures = 0, []
verify = lambda do |condition, message|
  checks += 1
  failures << message unless condition
  puts("#{condition ? 'PASS' : 'FAIL'} #{message}")
end
make = lambda do |index|
  profile = HallInviteProfile.new(File.join(directory, "profile-#{index}.json"))
  profile.save
  transport = Object.new
  def transport.call(method, url, *)
    (@calls ||= []) << [method, url]
    return {:status => 404, :body => '{"ok":false,"error":{"code":"room_not_found","message":"old room expired"}}'} if url.end_with?("/DEAD01")
    body = if url.end_with?("/v1/rooms")
             '{"ok":true,"rooms":[{"code":"ABCDEF","name":"Owned room","status":"waiting","mode":"friendly_singles"}]}'
           else
             '{"ok":true,"room":{"code":"ABCDEF","status":"waiting"}}'
           end
    {:status => 200, :body => body}
  end
  client = KIFMultiplayer::Client.new(profile, transport)
  session = Object.new
  def session.accepted_invites; [{"id" => "invite_review_001", "kind" => "battle", "room_code" => "ABCDEF"}]; end
  def session.drain; end
  ui = OpenStruct.new(:opened => 0)
  def ui.room_menu(_room); self.opened += 1; end
  hall = KIFMultiplayer::HallScene.allocate
  {:@client => client, :@session => session, :@ui => ui, :@opened_invites => {}, :@viewport => OpenStruct.new(:visible => true)}.each { |key, value| hall.instance_variable_set(key, value) }
  [profile, hall, ui, client, transport]
end
profile, hall, ui = make.call(1)
before = profile.writes
profile.fail_on = before + 2
begin
  hall.auto_launch_accepted
rescue IOError
end
saved = KIFMultiplayer::Profile.new(profile.path).account
verify.call(saved["room_code"] == "ABCDEF" && (saved["hall_opened_invites"] || []).include?("invite_review_001"), "invitation handled marker and recoverable room persist together")
verify.call(profile.writes == before + 1, "opening an accepted battle uses one atomic profile update")
verify.call(ui.opened == 1 && hall.instance_variable_get(:@viewport).visible, "accepted room opens once and hall visibility returns")

profile, hall, ui = make.call(2)
profile.fail_on = profile.writes + 1
begin
  hall.auto_launch_accepted
rescue IOError
end
verify.call(!hall.instance_variable_get(:@opened_invites)["invite_review_001"] && !profile.account["hall_opened_invites"], "failed invitation persistence leaves the in-memory invite retryable")
hall.auto_launch_accepted
verify.call(ui.opened == 1 && KIFMultiplayer::Profile.new(profile.path).account["room_code"] == "ABCDEF", "same process safely retries an invitation after disk recovery")
hall.auto_launch_accepted
verify.call(ui.opened == 1, "successfully opened invitation is not launched twice")
profile, hall, ui, client, transport = make.call(3)
profile.fail_on = profile.writes + 1
begin
  client.room_code = "ABCDEF"
rescue IOError
end
verify.call(!client.room_code && !KIFMultiplayer::Profile.new(profile.path).account["room_code"], "room pointer write failure preserves consistent memory and disk")
restored = KIFMultiplayer::Client.new(KIFMultiplayer::Profile.new(profile.path), transport)
room = KIFMultiplayer::UI.new(restored).recover_room
verify.call(room["code"] == "ABCDEF" && KIFMultiplayer::Profile.new(profile.path).account["room_code"] == "ABCDEF", "a new process can recover committed room membership without a local room code")
restored.room_code = "DEAD01"
room = KIFMultiplayer::UI.new(restored).recover_room
verify.call(room["code"] == "ABCDEF" && transport.instance_variable_get(:@calls).all? { |method, _| method == "GET" }, "stale room pointer recovers membership by query without recreating or rejoining")
puts("HALL_INVITE_RECOVERY_#{failures.empty? ? 'PASS' : 'FAIL'} checks=#{checks} failures=#{failures.length}")
exit(failures.empty? ? 0 : 1)
