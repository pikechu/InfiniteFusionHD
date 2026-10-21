# Fault-boundary review regression. Uses real on-disk Profile, never player saves.
begin
  root = File.expand_path("../..", __dir__)
  Dir.chdir(root)
  load "scripts/multiplayer/runtime-preload.rb" if defined?(System) && ENV["KIF_MULTIPLAYER_SAVE_DIR"]
  load "Data/Scripts/054_Multiplayer/001_Client.rb"
  directory = ENV["KIF_MULTIPLAYER_SAVE_DIR"] || File.join(root, "temp", "multiplayer", "cr-20261020", "journal-#{Process.pid}-#{Time.now.to_i}")
  missing, cursor = [], directory
  until File.directory?(cursor)
    missing.unshift(cursor)
    cursor = File.dirname(cursor)
  end
  missing.each { |path| Dir.mkdir(path) }
  log = File.open(File.join(directory, "reconnect-journal-test.log"), "w")
  original_server = ENV.delete("KIF_MULTIPLAYER_SERVER")

  class JournalReviewProfile < KIFMultiplayer::Profile
    attr_reader :save_calls
    attr_accessor :fail_on_save
    def initialize(path)
      @save_calls = 0
      super(path)
    end
    def save
      @save_calls += 1
      raise IOError, "Injected atomic profile write failure" if @save_calls == @fail_on_save
      super
    end
  end
  class JournalReviewTransport
    attr_accessor :mode, :submitted
    attr_reader :calls
    def initialize(mode)
      @mode, @calls = mode, []
    end
    def call(method, url, body, *_args)
      @calls << [method, url, body]
      if url.include?("/operations/")
        return reply(401, {"ok" => false, "error" => {"code" => "identity_invalid", "message" => "restore credentials"}}) if mode == :unauthorized
        return reply(404, {"ok" => false, "error" => {"code" => "operation_not_found", "message" => "not committed"}}) if mode == :not_found
        return reply(200, {"ok" => true}) if mode == :malformed_receipt
        return reply(200, {"ok" => true, "status" => "running", "http_status" => 200, "response" => {"ok" => true}}) if mode == :unfinished_receipt
        return reply(200, {"ok" => true, "status" => "completed", "http_status" => 409,
                           "response" => {"ok" => false, "error" => {"code" => "route_expired", "message" => "expired with persisted final state"}}}) if mode == :cached_rejection
        return reply(200, {"ok" => true, "status" => "completed", "http_status" => 200,
                           "response" => {"ok" => true, "room" => {"code" => "ORIGINAL"}}})
      end
      return reply(503, {"ok" => false, "error" => {"code" => "gateway_error", "message" => "response lost after upstream commit"}}) if mode == :gateway
      if mode == :body_delay
        sleep(0.05)
        @submitted = KIFMultiplayer::WireJSON.parse(KIFMultiplayer::WireJSON.dump(body))
      end
      reply(200, {"ok" => true, "room" => {"code" => "ORIGINAL"}})
    end
    def reply(status, body)
      {:status => status, :body => KIFMultiplayer::WireJSON.dump(body)}
    end
  end
  checks, failures, number = 0, [], 0
  verify = lambda do |condition, name|
    checks += 1
    if condition
      log.puts("PASS #{name}")
    else
      failures << name
      log.puts("FAIL #{name}")
    end
    log.flush
  end
  make = lambda do |mode, pending = false|
    number += 1
    profile = JournalReviewProfile.new(File.join(directory, "synthetic-profile-#{number}.json"))
    profile.account["identity"] = {"id" => "p_aaaaaaaaaaaaaaaaaaaaaaaa"}
    profile.account["token"] = "synthetic_test_credential"
    profile.account["pending"] = {"identity_id" => profile.account["identity"]["id"], "method" => "POST", "path" => "/v1/rooms", "body" => {"request_id" => "original_operation", "name" => "immutable"}} if pending
    profile.save
    transport = JournalReviewTransport.new(mode)
    [profile, transport, KIFMultiplayer::Client.new(profile, transport)]
  end

  profile, transport, client = make.call(:unauthorized, true)
  begin
    client.request("POST", "/v1/rooms", {"request_id" => "original_operation", "name" => "immutable"})
  rescue KIFMultiplayer::Error
  end
  verify.call(profile.account["pending"] && KIFMultiplayer::Profile.new(profile.path).account["pending"], "authentication failure during recovery preserves old pending in memory and disk")
  verify.call(transport.calls.length == 1 && transport.calls[0][0] == "GET", "failed recovery never sends a second mutation")

  profile, transport, client = make.call(:gateway)
  uncertain = false
  begin
    client.request("POST", "/v1/rooms", {"name" => "gateway"})
  rescue KIFMultiplayer::UncertainRequest
    uncertain = true
  rescue KIFMultiplayer::Error
  end
  verify.call(uncertain && profile.account["pending"], "structured HTTP 503 retains original operation as uncertain")
  transport.mode = :success
  client.recover_pending
  verify.call(transport.calls.drop(1).map(&:first) == ["GET"], "HTTP 503 recovers committed operation before any retry")

  profile, transport, client = make.call(:success, true)
  before = profile.save_calls
  profile.fail_on_save = before + 2
  begin
    client.recover_pending
  rescue IOError
  end
  recovered = KIFMultiplayer::Profile.new(profile.path).account
  verify.call(!recovered["pending"] && recovered.dig("last_recovered_operation", "response", "room", "code") == "ORIGINAL", "known committed receipt and pending removal persist atomically")
  verify.call(profile.save_calls == before + 1, "known recovery uses exactly one durable profile update")

  profile, transport, client = make.call(:not_found, true)
  before = profile.save_calls
  profile.fail_on_save = before + 3
  begin
    client.recover_pending
  rescue IOError
  end
  recovered = KIFMultiplayer::Profile.new(profile.path).account
  verify.call(!recovered["pending"] && recovered.dig("last_recovered_operation", "response", "room", "code") == "ORIGINAL", "query-not-found retry keeps the resulting receipt durable without a clear/save gap")

  profile, transport, client = make.call(:success)
  profile.fail_on_save = profile.save_calls + 2 # After POST success, while clearing pending.
  begin
    client.request("POST", "/v1/rooms", {"request_id" => "write_failure_operation"})
  rescue IOError
  end
  disk_pending = KIFMultiplayer::Profile.new(profile.path).account["pending"]
  verify.call(disk_pending && profile.account["pending"] == disk_pending, "failed pending clear rolls memory back to its durable journal")
  client.request("POST", "/v1/rooms", {"request_id" => "later_operation"})
  verify.call(transport.calls[1] && transport.calls[1][0] == "GET", "same process cannot overwrite a prior durable journal after a disk write failure")

  profile, transport, client = make.call(:malformed_receipt, true)
  begin
    client.recover_pending
  rescue KIFMultiplayer::Error
  end
  verify.call(profile.account["pending"] && KIFMultiplayer::Profile.new(profile.path).account["pending"], "malformed operation receipt cannot erase recovery journal")

  profile, transport, client = make.call(:unfinished_receipt, true)
  begin
    client.recover_pending
  rescue KIFMultiplayer::UncertainRequest
  end
  verify.call(profile.account["pending"] && KIFMultiplayer::Profile.new(profile.path).account["pending"], "an unfinished operation cannot be treated as a completed receipt")

  profile, transport, client = make.call(:cached_rejection, true)
  rejection = nil
  begin
    client.recover_pending
  rescue KIFMultiplayer::HTTPRejected => error
    rejection = error.code
  end
  verify.call(rejection == "route_expired" && !profile.account["pending"] && profile.account.dig("last_recovered_operation", "response", "ok") == false, "completed cached 4xx preserves its definitive rejection and durable receipt")
  verify.call(transport.calls.map(&:first) == ["GET"] && !KIFMultiplayer::Profile.new(profile.path).account["pending"], "cached rejected operation is never resubmitted or left permanently pending")

  profile, transport, client = make.call(:success, true)
  profile.fail_on_save = profile.save_calls + 1
  begin
    client.recover_pending
  rescue IOError
  end
  verify.call(profile.account["pending"] == KIFMultiplayer::Profile.new(profile.path).account["pending"] && !profile.account["last_recovered_operation"], "recovery receipt disk failure preserves the prior complete journal")
  client.recover_pending
  verify.call(profile.account["pending"].nil? && profile.account.dig("last_recovered_operation", "response", "room", "code") == "ORIGINAL", "recovery receipt can be persisted by retrying the same operation after write recovery")

  profile, transport, client = make.call(:success)
  original_url = profile.server
  profile.fail_on_save = profile.save_calls + 1
  begin
    profile.server = "http://127.0.0.1:9876"
  rescue IOError
  end
  verify.call(profile.server == original_url && KIFMultiplayer::Profile.new(profile.path).server == original_url, "failed server setting write cannot redirect a later operation to another server in memory")

  profile, transport, client = make.call(:gateway, true)
  pending_before = KIFMultiplayer::WireJSON.dump(profile.account["pending"])
  begin
    client.request("POST", "/v1/battles/b_review/heartbeat", {"authority_id" => "authority_review_1"})
  rescue KIFMultiplayer::UncertainRequest
  end
  verify.call(KIFMultiplayer::WireJSON.dump(profile.account["pending"]) == pending_before && transport.calls.length == 1 && transport.calls[0][1].end_with?("/heartbeat"), "authority heartbeat never overwrites or replays a pending economic operation")
  transport.mode = :success
  client.request("POST", "/v1/battles/b_review/heartbeat", {"authority_id" => "authority_review_1"})
  verify.call(KIFMultiplayer::WireJSON.dump(KIFMultiplayer::Profile.new(profile.path).account["pending"]) == pending_before, "successful heartbeat leaves the exact durable economic journal untouched")

  profile, transport, client = make.call(:body_delay)
  body = {"nested" => {"value" => "original"}}
  client.wait_update = proc { body["nested"]["value"] = "changed by UI" }
  client.request("POST", "/v1/rooms", body, 1.0)
  verify.call(transport.submitted.dig("nested", "value") == "original", "network and durable journal use an immutable deep copy of caller payload")

  profile, transport, client = make.call(:success)
  begin
    client.request("POST", "/v1/rooms", {"unsupported" => Object.new})
  rescue KIFMultiplayer::Error
  end
  verify.call(profile.account["pending"].nil? && transport.calls.empty?, "invalid outgoing JSON is rejected before touching the durable operation journal")
  success = failures.empty?
  log.puts("RECONNECT_JOURNAL_#{success ? 'PASS' : 'FAIL'} checks=#{checks} failures=#{failures.length}")
  puts("RECONNECT_JOURNAL_#{success ? 'PASS' : 'FAIL'} checks=#{checks} failures=#{failures.length} evidence=#{directory}")
  failures.each { |failure| puts("FAIL #{failure}") }
rescue Exception => error
  success = false
  log.puts("UNEXPECTED #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if log
  raise unless defined?(System)
ensure
  ENV["KIF_MULTIPLAYER_SERVER"] = original_server if defined?(original_server)
  log.close if log
  exit!(success ? 0 : 1) if defined?(System)
end
exit(success ? 0 : 1)
