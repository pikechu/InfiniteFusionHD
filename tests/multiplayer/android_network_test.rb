require "socket"
require "digest/sha2"
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
module System
  def self.is_android?; true; end
end
module HTTPLite
  def self.get(*); raise "unverified native HTTP must never run"; end
  def self.post_body(*); raise "unverified native HTTP must never run"; end
end
load "Data/Scripts/000_Platform.rb"
load "Data/Scripts/054_Multiplayer/001_Client.rb"
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
load "Data/Scripts/054_Multiplayer/020_AndroidNetwork.rb"
checks = 0
verify = lambda { |value, name| raise "FAIL #{name}" unless value; checks += 1; puts "PASS #{name}" }
verify.call(KIF::Platform.network_available?, "Android production adapter installs automatically")
transport = KIFMultiplayer::HTTPTransport.new
verify.call(transport.backend == :platform, "Android client selects installed production platform adapter")
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
worker = Thread.new do
  3.times do
    stream = server.accept
    first = stream.gets
    headers = {}
    while (line = stream.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip
    end
    payload = stream.read(headers.fetch("content-length", "0").to_i).force_encoding(Encoding::UTF_8)
    body = if first.include?("/binary")
             "\x89PNG\r\n\x1a\n\xff".b
           else
             KIFMultiplayer::WireJSON.dump({"ok" => true, "auth" => headers["authorization"], "body" => payload})
           end
    media = first.include?("/binary") ? "application/octet-stream" : "application/json"
    stream.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nContent-Type: #{media}\r\n\r\n" + body)
    stream.close
  end
rescue IOError
  nil
end
begin
  url = "http://127.0.0.1:#{port}"
  response = transport.call("POST", url + "/v1/probe", {"message" => "中文😀", "id" => 4294967295}, "fixture_token", 2)
  parsed = KIFMultiplayer::WireJSON.parse(response[:body])
  verify.call(parsed["auth"] == "Bearer fixture_token", "Android adapter preserves authenticated requests")
  body = KIFMultiplayer::WireJSON.parse(parsed["body"])
  verify.call(body["message"] == "中文😀" && body["id"] == 4294967295, "Android adapter preserves Unicode and uint32 JSON")
  binary = KIF::Platform.http_get(url + "/binary")
  verify.call(binary[:body] == "\x89PNG\r\n\x1a\n\xff".b, "platform downloads preserve binary image bytes")
  form = KIF::Platform.http_post_body(url + "/form", "name=a%20b", "application/x-www-form-urlencoded", {"User-Agent" => "fixture"})
  verify.call(KIFMultiplayer::WireJSON.parse(form[:body])["body"] == "name=a%20b", "legacy form requests use safe adapter without native HTTP")
  begin
    KIF::Platform.http_get(url + "/binary", {"Host" => "evil"})
    raise "unsafe Host override was accepted"
  rescue KIFMultiplayer::Error => error
    verify.call(error.code == "invalid_request", "adapter rejects request header injection")
  end
ensure
  server.close
  worker.join(2)
end
begin
  KIF::Platform.validate_http_url("http://abc/v1/health")
  raise "hostname HTTP was accepted"
rescue KIFMultiplayer::Error => error
  verify.call(error.code == "invalid_server", "Android HTTP never enters unsafe native DNS resolution for hostnames")
end

module KIFAndroidBridge
  class << self
    attr_reader :calls, :cancelled
    attr_accessor :held, :async_version
    def http_async_version; @async_version || 1; end
    def request(*); raise "Synchronous JNI HTTPS must never be called"; end
    def request_start(raw, timeout)
      raise "bridge envelope exceeded native limit" if raw.bytesize > 65536
      raise "bad deadline" unless timeout.is_a?(Integer) && timeout.between?(1, 20000)
      (@calls ||= []) << raw
      @next = (@next || 0) + 1
      (@jobs ||= {})[@next] = [raw, 0]
      @next
    end
    def pending_count; (@jobs || {}).length; end
    def request_poll(id)
      raw, polls = @jobs.fetch(id)
      @jobs[id][1] = polls + 1
      return nil if @held || polls == 0
      @jobs.delete(id)
      envelope = KIFMultiplayer::WireJSON.parse(raw)
      result = {"ok" => true}
      if envelope["url"].end_with?("/chunk")
        chunk = KIFMultiplayer::WireJSON.parse(envelope["body"].unpack1("m0"))
        @parts ||= {}
        @parts[chunk["index"]] = chunk["data"].unpack1("m0")
        result = {"ok" => true, "next_index" => chunk["index"] + 1, "upload_id" => chunk["upload_id"]}
        if @parts.length == chunk["total"]
          original = KIFMultiplayer::WireJSON.parse(@parts.sort.map(&:last).join)
          raise "chunk payload altered" unless Digest::SHA256.hexdigest(@parts.sort.map(&:last).join) == chunk["sha256"]
          result = {"ok" => true, "revision" => original["revision"] + 1, "slot" => original["slot"], "upload_id" => original["upload_id"]}
        end
      end
      KIFMultiplayer::WireJSON.dump({"status" => 200, "headers" => {}, "body" => [KIFMultiplayer::WireJSON.dump(result)].pack("m0")})
    end
    def request_cancel(id)
      (@cancelled ||= []) << id
      @jobs.delete(id)
    end
  end
end
body = {"session_id" => "a" * 32, "upload_id" => "b" * 32, "slot" => "file-a", "revision" => 0, "save" => {"payload" => "a" * 120000}}
response = transport.call("POST", "https://fixture.invalid/v1/cloud/upload", body, "fixture_token", 5)
verify.call(KIFMultiplayer::WireJSON.parse(response[:body])["revision"] == 1 && KIFAndroidBridge.calls.length > 3, "large HTTPS cloud saves use resumable chunks within native bridge limit")
KIFAndroidBridge.held = true
slow_https = KIFMultiplayer.network_worker { transport.call("GET", "https://fixture.invalid/slow", {}, nil, 2) }
100.times { slow_https.poll }
verify.call(slow_https.alive? && KIFAndroidBridge.pending_count == 1, "pending HTTPS yields across game frames without synchronous JNI")
KIFAndroidBridge.held = false
verify.call(KIFMultiplayer::WireJSON.parse(slow_https.value[:body])["ok"] && KIFAndroidBridge.pending_count == 0, "asynchronous HTTPS consumes and releases its response")
KIFAndroidBridge.held = true
begin
  expiring = KIFMultiplayer.network_worker { transport.call("GET", "https://fixture.invalid/slow", {}, nil, 0.02) }
  expiring.value
  raise "HTTPS timeout was ignored"
rescue KIFMultiplayer::Error => error
  verify.call(error.code == "network_timeout" && KIFAndroidBridge.pending_count == 0, "HTTPS deadline cancels native job instead of blocking the game")
end
abandoned = KIFMultiplayer.network_worker { transport.call("GET", "https://fixture.invalid/slow", {}, nil, 2) }
abandoned.poll
abandoned.cancel
verify.call(!abandoned.alive? && KIFAndroidBridge.pending_count == 0, "closing a cooperative HTTPS task runs native cancellation ensure")
KIFAndroidBridge.held = false
KIFAndroidBridge.async_version = 0
begin
  transport.validate_url("https://fixture.invalid/")
  raise "old blocking bridge was accepted"
rescue KIFMultiplayer::Error => error
  verify.call(error.code == "network_unavailable", "old APK cannot silently fall back to blocking HTTPS")
end
KIFAndroidBridge.async_version = 1

delayed = TCPServer.new("127.0.0.1", 0)
delayed_port = delayed.addr[1]
release = Queue.new
reply = Thread.new do
  socket = delayed.accept
  while (line = socket.gets) && line != "\r\n"; end
  release.pop
  socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
  socket.close
end
begin
  task = KIFMultiplayer.network_worker { transport.call("GET", "http://127.0.0.1:#{delayed_port}/v1/probe", {}, nil, 2) }
  task.poll
  raise "fiber failure: #{task.instance_variable_get(:@failure).inspect}" if task.instance_variable_get(:@failure)
  verify.call(task.is_a?(KIFMultiplayer::FiberWorker) && task.alive?, "Android socket worker yields while waiting instead of creating Ruby IO threads")
  release << true
  verify.call(KIFMultiplayer::WireJSON.parse(task.value[:body])["ok"], "cooperative Android worker resumes and completes normally")
ensure
  release << true
  reply.join(2)
  delayed.close
end
puts "ANDROID_NETWORK_CONTRACT_PASS checks=#{checks}; host runtime fixture, not Android device acceptance"
