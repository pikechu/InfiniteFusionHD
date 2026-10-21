load File.expand_path("rental_test.rb", __dir__)
load File.join(ROOT, "Data/Scripts/054_Multiplayer/008_Hall.rb")
$hall_checks = 0
def hall_assert(condition, message)
  raise message unless condition
  $hall_checks += 1
end
def hall_reject(message)
  begin
    yield
  rescue KIFMultiplayer::Error
    $hall_checks += 1
    return
  end
  raise message
end
class HallTransportFixture
  attr_accessor :document, :delay, :fail_before_commit
  attr_reader :calls
  def initialize(document)
    @document, @calls, @delay = document, [], 0
  end
  def call(method, url, body, _token, _timeout)
    sleep(@delay) if @delay > 0
    @calls << [method, url, body]
    if @fail_before_commit && url.end_with?("/move")
      @fail_before_commit = false
      raise IOError, "lost uncommitted movement"
    end
    member = @document["members"].find { |value| value["id"] == "host_id" }
    if url.end_with?("/move") && body["seq"] > member["seq"]
      member.merge!(body.reject { |key, _value| key == "request_id" })
    elsif url.end_with?("/emote")
      member["emote"] = body["emote"]
    end
    { :status => 200, :body => KIFMultiplayer::WireJSON.dump({"ok" => true, "hall" => @document}) }
  end
end
class HallClientFixture
  attr_reader :transport, :calls, :profile
  def initialize(document)
    @transport = HallTransportFixture.new(document)
    @calls = []
    @profile = OpenStruct.new(:account => {})
    def @profile.save; true; end
  end
  def player_id; "host_id"; end
  def server; "http://127.0.0.1:18779"; end
  def token; "private_test_token"; end
  def pump; Thread.pass; end
  def request(method, path, body = {})
    @calls << [method, path, body]
    hall = @transport.document
    if path.end_with?("/invite")
      hall["invites"] << {"id" => "invite_test_0001", "from_id" => "host_id", "to_id" => body["target_id"], "kind" => body["kind"], "status" => "pending"}
    elsif path.end_with?("/accept")
      hall["invites"].find { |invite| invite["id"] == body["invite_id"] }["status"] = "accepted"
    end
    {"ok" => true, "hall" => rental_copy(hall)}
  end
end
def hall_finish_worker(session)
  # Consume exactly the current response. A slow Windows test scheduler can
  # otherwise start a new poll in the final tick and leave this helper early.
  session.instance_variable_set(:@next_poll, Time.now + 3600)
  deadline = Time.now + 3
  while session.busy? && Time.now < deadline
    Thread.pass
  end
  raise "Hall worker stuck" if session.busy?
  session.tick
end
def hall_cycle(session)
  hall_finish_worker(session)
  session.instance_variable_set(:@next_poll, Time.now - 1)
  session.tick
  hall_finish_worker(session)
end
document = {"code" => "HALL123", "name" => "Test", "map" => {"id" => "social-lobby-v1", "width" => 20, "height" => 15}, "members" => [
  {"id" => "host_id", "nickname" => "Host", "x" => 10, "y" => 7, "direction" => 2, "seq" => 0, "emote" => nil, "status" => "online"},
  {"id" => "guest_id", "nickname" => "Guest", "x" => 11, "y" => 7, "direction" => 4, "seq" => 0, "emote" => nil, "status" => "online"}], "invites" => []}
client = HallClientFixture.new(rental_copy(document))
session = KIFMultiplayer::HallSession.new(client, rental_copy(document))
hall_assert(session.map_compatible? && session.local_position["x"] == 10, "Hall map/state not initialized")
hall_assert(session.move(6) && session.local_position["x"] == 11, "Player collision blocked crossing another member")
client.transport.delay = 0.04
session.tick
session.move(6)
while session.busy?; Thread.pass; end
session.tick
hall_assert(session.local_position["x"] == 12 && session.local_position["seq"] == 2, "Old server movement rewound a newer local intent")
client.transport.delay = 0
hall_cycle(session)
hall_assert(client.transport.document["members"][0]["x"] == 12 && client.transport.document["members"][0]["seq"] == 2, "Queued position not sent with monotonic sequence")
session.emote("hello")
hall_cycle(session)
hall_assert(session.own_member["emote"] == "hello", "Preset emote did not synchronize")
hall_reject("Arbitrary emote accepted") { session.emote("<script>") }
hall_assert(session.move(5) == false, "Unsupported direction accepted")
30.times { session.move(6) }
hall_assert(session.local_position["x"] == 19, "Movement escaped lobby grid")
hall_cycle(session)
client.transport.fail_before_commit = true
session.move(4)
hall_cycle(session)
hall_assert(session.error.is_a?(IOError), "Lost position response not recorded")
hall_cycle(session)
hall_assert(session.local_position["x"] == 19, "Reconnect did not adopt authoritative uncommitted position")
session.invite("guest_id", "battle")
hall_assert(client.calls.last[1].end_with?("/invite") && client.calls.last[2]["target_id"] == "guest_id", "Invite did not use durable foreground client")
hall_reject("Self invitation allowed") { session.invite("host_id", "battle") }
hall_reject("Invitation to absent member allowed") { session.invite("absent", "trade") }
bad = rental_copy(document)
bad["members"] << rental_copy(bad["members"][0])
hall_reject("Duplicate hall members accepted") { session.adopt(bad) }
bad = rental_copy(document)
bad["members"][0]["direction"] = 3
hall_reject("Invalid facing accepted") { session.adopt(bad) }
bad = rental_copy(document)
bad["members"].shift
hall_reject("Missing self member treated as connected") { session.adopt(bad) }
different_map = rental_copy(document)
different_map["map"]["id"] = "future-lobby-v2"
session.adopt(different_map)
hall_assert(!session.map_compatible? && session.move(2) == false, "Incompatible map still allowed movement")
session.close
hall_assert(client.calls.last[1].end_with?("/leave") && !session.busy?, "Leaving retained worker or omitted server departure")
# A resolver/adapter that outlives the UI's drain deadline must finish on its
# own. Asynchronous Thread#kill could interrupt a native binding's cleanup.
closing_session = KIFMultiplayer::HallSession.new(client, rental_copy(document))
gate, worker_finished = Queue.new, false
closing_worker = Thread.new { gate.pop; worker_finished = true }
closing_session.instance_variable_set(:@worker, closing_worker)
def closing_session.drain
  raise KIFMultiplayer::UncertainRequest.new("diagnostic drain deadline", "hall_busy")
end
closing_session.close(false)
hall_assert(closing_worker.alive? && closing_session.busy?, "Hall close killed or forgot an unfinished network worker")
gate << true
closing_worker.join
hall_assert(worker_finished && !closing_session.busy?, "Detached hall worker did not finish naturally")
module KIFMultiplayer
  class UI
    def initialize(_client); end
  end
end
scene = KIFMultiplayer::HallScene.new(client, rental_copy(document))
scene.remember_invite("invite_done_0001")
reopened = KIFMultiplayer::HallScene.new(client, rental_copy(document))
hall_assert(reopened.instance_variable_get(:@opened_invites)["invite_done_0001"], "Reopening hall replayed an already opened invitation")
bad = rental_copy(document)
bad["invites"] = [{"id" => "invite_bad_0001", "kind" => "battle", "status" => "accepted", "from_id" => "host_id", "to_id" => "guest_id", "room_code" => "../../collections"}]
hall_reject("Activity code permitted network path injection") { KIFMultiplayer::HallSession.new(client, bad) }
puts "PASS: #{$hall_checks} hall state/worker checks; native rendering and real multi-client checks are separate"
