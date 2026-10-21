load File.expand_path("boss_test.rb", __dir__)

initial = battle_document("initializing").merge("turn" => 0, "status" => "active")
claim_client = FakeClient.new([{"battle" => initial}, {"battle" => initial}])
first = KIFMultiplayer::BattleSession.new(claim_client, initial)
first.claim_authority
second = KIFMultiplayer::BattleSession.new(claim_client, initial)
second.claim_authority
ids = claim_client.calls.map { |call| call[2]["authority_id"] }
assert(ids.length == 2 && ids.uniq.length == 2 && ids.all? { |id| id =~ /\A[A-Za-z0-9_-]{16,100}\z/ }, "Engine instances reused an authority identifier")
heartbeat_client = FakeClient.new([{"battle" => initial}, {"battle" => initial}])
heartbeat_session = KIFMultiplayer::BattleSession.new(heartbeat_client, initial)
heartbeat_session.claim_authority
heartbeat_session.fetch
assert(heartbeat_client.calls[1][0] == "POST" && heartbeat_client.calls[1][1].end_with?("/heartbeat") &&
       heartbeat_client.calls[0][2]["authority_id"] == heartbeat_client.calls[1][2]["authority_id"],
       "Authority fetch did not prove the same live engine instance")
read_client = FakeClient.new([{"battle" => initial}])
KIFMultiplayer::BattleSession.new(read_client, initial).fetch
assert(read_client.calls[0][0] == "GET", "A newly opened host view impersonated a live authority heartbeat")

conflict = KIFMultiplayer::Error.new("another engine owns this battle", "authority_conflict")
conflict_client = FakeClient.new([conflict])
conflict_session = KIFMultiplayer::BattleSession.new(conflict_client, initial)
assert_raises(KIFMultiplayer::Error, "Conflicting authority was silently accepted") { conflict_session.claim_authority }
conflict_session.abort("authority_unrecoverable")
assert(conflict_client.calls.length == 1 && conflict_client.calls[0][1].end_with?("/authority"),
       "Second host instance terminated the first engine after losing its claim")
restart_client = FakeClient.new([])
restarted = KIFMultiplayer::BattleSession.new(restart_client, battle_document("locked"))
restarted.abort("authority_unrecoverable")
assert(restart_client.calls.empty?, "A restarted unclaimed host terminated an existing live engine")

state, tape = {"kind" => "command", "battlers" => []}, [{"limit" => 16, "value" => 4}]
digest = KIFMultiplayer.battle_digest(state)
update = {"turn" => 1, "digest" => digest, "decision" => 0, "random_tape" => tape}
advanced = battle_document("commands").merge("turn" => 2, "updates" => [update])
turn_client = FakeClient.new([{"battle" => advanced}])
turn_session = KIFMultiplayer::BattleSession.new(turn_client, advanced)
turn_session.resolve(state, tape, 0, 1)
assert(turn_client.calls[0][2]["turn"] == 1, "Stale engine state was retagged to the newer heartbeat turn")

wrong_update = update.merge("digest" => "0" * 64)
wrong = advanced.merge("updates" => [wrong_update])
lost_client = FakeClient.new([KIFMultiplayer::Error.new("phase moved", "turn_mismatch"),
                            KIFMultiplayer::Error.new("not cached", "operation_not_found"), {"battle" => wrong}])
lost_session = KIFMultiplayer::BattleSession.new(lost_client, battle_document("locked"))
assert_raises(KIFMultiplayer::BattleError, "Different authority output was mistaken for the local engine's committed resolve") do
  lost_session.resolve(state, tape, 0, 1)
end
assert(lost_client.calls.count { |call| call[1].end_with?("/resolve") } == 1, "Conflicting engine output was retried under a later turn")

good_client = FakeClient.new([KIFMultiplayer::UncertainRequest.new("lost response"),
                            KIFMultiplayer::Error.new("receipt temporarily absent", "operation_not_found"), {"battle" => advanced}])
good_session = KIFMultiplayer::BattleSession.new(good_client, battle_document("locked"))
good_session.resolve(state, tape, 0, 1)
assert(good_session.battle["turn"] == 2, "Exact turn/digest/decision/random trace could not recover a committed resolution")

before_controller = KIFMultiplayer.battle_controller
KIFMultiplayer.battle_controller = proc { raise "Finished battle must not request commands" }
ended_client = FakeClient.new([])
ended = battle_document("finished").merge("status" => "finished", "result" => {"winner_id" => "host_id", "abnormal" => false})
assert(KIFMultiplayer.run_battle(ended_client, {}, ended) == 1 && ended_client.calls.empty?, "Host terminal recovery started another engine or requested authority")
KIFMultiplayer.battle_controller = before_controller
puts "AUTHORITY_SESSION_PASS checks=#{$checks}"
