# Core HTTP protocol/security/lifecycle tests. Runs in standalone Ruby and the
# actual bundled Game.exe; no game save or third-party HTTP service is used.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
load "scripts/multiplayer/runtime-preload.rb" if defined?(System) && ENV["KIF_MULTIPLAYER_SAVE_DIR"]
load "Data/Scripts/000_Platform.rb"
load "Data/Scripts/054_Multiplayer/001_Client.rb"
$transport_test_android = false
KIF::Platform.define_singleton_method(:android?) { $transport_test_android }
KIF::Platform.define_singleton_method(:http_get) do |*args|
  if android?
    instance_variable_get(:@http_adapter).get(*args)
  else
    @transport_test_native_calls = (@transport_test_native_calls || 0) + 1
    {:status => 200, :body => '{"ok":true}'}
  end
end
KIF::Platform.define_singleton_method(:http_post_body) do |*args|
  if android?
    instance_variable_get(:@http_adapter).post_body(*args)
  else
    @transport_test_native_calls = (@transport_test_native_calls || 0) + 1
    {:status => 200, :body => '{"ok":true}'}
  end
end
load "Data/Scripts/054_Multiplayer/015_Transport.rb"
require "socket"
directory = ENV["KIF_MULTIPLAYER_SAVE_DIR"] || File.join(root, "temp", "multiplayer", "transport-unit")
paths, cursor = [], directory
until File.directory?(cursor)
  paths.unshift(cursor)
  cursor = File.dirname(cursor)
end
paths.each { |path| Dir.mkdir(path) }
log = File.open(File.join(directory, "transport-test.log"), "w")
checks, passed = 0, false
assert = lambda do |condition, description|
  raise "FAIL #{description}" unless condition
  checks += 1
  log.puts("PASS #{description}")
  log.flush
end
reject = lambda do |description, code = nil, &action|
  begin
    action.call
  rescue KIFMultiplayer::Error => error
    raise "FAIL #{description}: wrong error code #{error.code}" if code && error.code != code
    assert.call(true, description)
  else
    raise "FAIL accepted #{description}"
  end
end

class TransportFragmentStream
  def initialize(chunks); @chunks = chunks.dup; end
  def read_nonblock(maximum)
    raise EOFError if @chunks.empty?
    chunk = @chunks.shift.b
    if chunk.bytesize > maximum
      @chunks.unshift(chunk.byteslice(maximum, chunk.bytesize))
      chunk = chunk.byteslice(0, maximum)
    end
    chunk
  end
end

class TransportPartialWriter
  attr_reader :bytes, :calls
  def initialize; @bytes, @calls = "".b, 0; end
  def write_nonblock(bytes)
    @calls += 1
    length = [bytes.bytesize, 3].min
    @bytes << bytes.byteslice(0, length)
    length
  end
end

class TransportWouldBlock < IOError
  include IO::WaitWritable
end

class TransportBlockedWriter
  def initialize(io); @io = io; end
  def to_io; @io; end
  def write_nonblock(_bytes); raise TransportWouldBlock; end
end

class TransportTestProfile
  attr_accessor :server
  attr_reader :account, :saves
  def initialize(server)
    @server, @account, @saves = server, {"identity" => {"id" => "p_transport_test"}}, 0
  end
  def save; @saves += 1; true; end
end

class TransportNoTLS < KIFMultiplayer::SocketHTTP
  def self.ssl_available?; false; end
  def connect(*); raise "TLS rejection must happen before opening a socket"; end
end

class TransportSlowFake
  attr_accessor :delay
  attr_reader :completed, :kill_calls
  def initialize(delay); @delay, @completed, @kill_calls = delay, 0, []; end
  def call(*_arguments)
    calls = @kill_calls
    Thread.current.define_singleton_method(:kill) { calls << true; super() }
    sleep(@delay)
    @completed += 1
    {:status => 200, :body => '{"ok":true}'}
  end
end

positive_fixture_timeout = 5.0
response = lambda do |body, headers = {}|
  all = {"Content-Type" => "application/json; charset=utf-8", "Content-Length" => body.bytesize.to_s}.merge(headers)
  "HTTP/1.1 200 OK\r\n" + all.map { |key, value| "#{key}: #{value}\r\n" }.join + "\r\n" + body
end
parse = lambda do |wire, parts = nil|
  chunks = parts || [wire]
  KIFMultiplayer::SocketHTTP.new.read_response(TransportFragmentStream.new(chunks), KIFMultiplayer.monotonic + 5)
end

# The fixture reads the actual request and can deliberately fragment or delay
# its response. Each listener binds only loopback and closes in ensure.
serve = lambda do |parts, &action|
  listener = TCPServer.new("127.0.0.1", 0)
  received, accepted, server_error = [], nil, nil
  worker = Thread.new do
    begin
      accepted = listener.accept
      raw = "".b
      raw << accepted.readpartial(4096) until raw.include?("\r\n\r\n")
      offset = raw.index("\r\n\r\n") + 4
      header_text = raw.byteslice(0, offset)
      count = header_text[/\r\nContent-Length: ([0-9]+)\r\n/i, 1].to_i
      raw << accepted.readpartial(4096) until raw.bytesize >= offset + count
      received << [header_text, raw.byteslice(offset, count)]
      parts.each { |part| part.is_a?(Numeric) ? sleep(part) : accepted.write(part) }
    rescue SystemCallError, IOError => error
      server_error = error
    ensure
      accepted.close if accepted && !accepted.closed?
    end
  end
  worker.report_on_exception = false if worker.respond_to?(:report_on_exception=)
  begin
    action.call("http://127.0.0.1:#{listener.addr[1]}", received)
  ensure
    accepted.close if accepted && !accepted.closed?
    listener.close unless listener.closed?
    raise "Test server failed to finish" unless worker.join(positive_fixture_timeout)
  end
end

begin
  adapter = KIFMultiplayer::HTTPTransport.new
  assert.call(adapter.backend == :core_socket, "desktop factory selects safe core Socket")
  endpoint = adapter.validate_url("http://localhost:8765/v1/health?q=1")
  assert.call(endpoint[:host] == "localhost" && endpoint[:port] == 8765 && endpoint[:path] == "/v1/health?q=1", "URL preserves configured host port and request target")
  %w[http://user:pass@localhost/v1/health http://localhost:0/v1/health http://localhost:65536/v1/health http://localhost/v1/health#secret http://localhost\\x/v1/health file://localhost/v1/health].each do |bad|
    reject.call("unsafe endpoint rejected", "invalid_server") { adapter.validate_url(bad) }
  end
  reject.call("request line injection rejected", "invalid_server") { adapter.validate_url("http://localhost/v1/x\r\nInjected: yes") }
  assert.call(KIFMultiplayer::SocketHTTP.parse_url("http://[::1]:8765/v1/health")[:host] == "::1", "bracketed IPv6 authority parsed")

  no_tls = TransportNoTLS.new
  reject.call("missing TLS rejected before opening socket", "unsupported_https") { no_tls.call("GET", "https://localhost/v1/health", {}, nil, 1) }
  https_adapter = KIFMultiplayer::HTTPTransport.new
  https_adapter.instance_variable_set(:@socket_http, no_tls)
  https_profile = TransportTestProfile.new("https://localhost:8765")
  https_client = KIFMultiplayer::Client.new(https_profile, https_adapter)
  reject.call("HTTPS preflight precedes durable mutation", "unsupported_https") { https_client.request("POST", "/v1/rooms", {}) }
  assert.call(https_profile.account["pending"].nil? && https_profile.saves == 0 && KIFMultiplayer.network_workers.empty?, "unsupported HTTPS creates no journal and no worker")
  reject.call("authorization line injection rejected", "invalid_request") { adapter.call("GET", "http://localhost/v1/health", {}, "secret\r\nInjected: yes", 1) }
  [0, -1, Float::INFINITY, true].each do |timeout|
    reject.call("invalid deadline rejected", "invalid_request") { adapter.call("GET", "http://localhost/v1/health", {}, nil, timeout) }
  end

  unicode = '{"ok":true,"text":"中文 😀"}'
  wire = response.call(unicode)
  parsed = parse.call(wire, wire.bytes.map { |byte| byte.chr })
  assert.call(KIFMultiplayer::WireJSON.parse(parsed[:body])["text"] == "中文 😀", "one-byte partial headers and Unicode body decoded losslessly")
  assert.call(parsed[:headers]["content-type"] == "application/json; charset=utf-8", "response headers normalized")
  writer = TransportPartialWriter.new
  KIFMultiplayer::SocketHTTP.new.write_all(writer, unicode.b, KIFMultiplayer.monotonic + positive_fixture_timeout)
  assert.call(writer.bytes == unicode.b && writer.calls > 1, "partial socket writes preserve all bytes")
  eof_wire = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + unicode
  assert.call(parse.call(eof_wire)[:body] == unicode, "bounded EOF-delimited HTTP/1.0 body accepted")
  chunk_wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
  unicode.b.bytes.each_slice(5) { |bytes| part = bytes.pack("C*"); chunk_wire << "#{part.bytesize.to_s(16)};note=test\r\n" + part + "\r\n" }
  chunk_wire << "0\r\nX-Trace: safe\r\n\r\n"
  assert.call(parse.call(chunk_wire)[:body] == unicode, "chunked body extensions and bounded harmless trailer accepted")
  malformed = {
    "truncated body" => response.call('{}').sub(/\{\}\z/, '{'),
    "oversized Content-Length" => response.call('{}', "Content-Length" => (KIFMultiplayer::MAX_RESPONSE_BYTES + 1).to_s),
    "negative Content-Length" => response.call('{}', "Content-Length" => "-1"),
    "duplicate Content-Length" => response.call('{}').sub("Content-Length: 2", "Content-Length: 2\r\nContent-Length: 2"),
    "conflicting framing" => response.call('{}', "Transfer-Encoding" => "chunked"),
    "unsupported transfer encoding" => response.call('{}').sub("Content-Length: 2", "Transfer-Encoding: gzip"),
    "compressed JSON" => response.call('{}', "Content-Encoding" => "gzip"),
    "HTML response" => response.call('{}', "Content-Type" => "text/html"),
    "wrong charset" => response.call('{}', "Content-Type" => "application/json; charset=gbk"),
    "header folding" => response.call('{}').sub("Content-Type:", " Content-Type:"),
    "header control" => response.call('{}', "X-Trace" => "unsafe\x01"),
    "extra bytes" => response.call('{}') + 'junk',
    "bare LF headers" => response.call('{}').gsub("\r\n", "\n"),
    "invalid UTF-8" => response.call("\xff".b),
    "bad HTTP version" => response.call('{}').sub("HTTP/1.1", "HTTP/2"),
    "interim status" => response.call('{}').sub("200 OK", "100 Continue"),
    "bodyless JSON status" => response.call('{}').sub("200 OK", "204 No Content"),
    "oversized header line" => response.call('{}', "X-Huge" => 'x' * 5000),
    "too many headers" => response.call('{}').sub("\r\n\r\n", (0..100).map { |n| "\r\nX-#{n}: x" }.join + "\r\n\r\n"),
    "bad chunk size" => chunk_wire.sub("5;note=test", "z;note=test"),
    "bad chunk terminator" => chunk_wire.sub("\r\n5;note=test", "x\n5;note=test"),
    "forbidden trailer" => chunk_wire.sub("X-Trace: safe", "Content-Length: 2")
  }
  malformed.each { |name, bytes| reject.call(name, "invalid_http_response") { parse.call(bytes) } }
  redirect = response.call('{}', "Location" => "http://other.invalid/stolen").sub("200 OK", "302 Found")
  reject.call("redirect refused without forwarding credentials", "redirect_forbidden") { parse.call(redirect) }

  serve.call([wire.byteslice(0, 11), 0.01, wire.byteslice(11, 35), 0.01, wire.byteslice(46, wire.bytesize)]) do |url, requests|
    value = adapter.call("POST", url + "/v1/rooms", {"nickname" => "中文"}, "local-test-token", positive_fixture_timeout)
    assert.call(KIFMultiplayer::WireJSON.parse(value[:body])["ok"], "real loopback partial response succeeds")
    assert.call(requests[0][0].include?("Authorization: Bearer local-test-token\r\n") && requests[0][0].include?("Accept-Encoding: identity\r\n"), "own connection receives explicit authorization and identity encoding")
    assert.call(KIFMultiplayer::WireJSON.parse(requests[0][1])["nickname"] == "中文", "actual POST request uses UTF-8 byte Content-Length")
  end
  serve.call([response.call('{"ok":true}')]) do |url, _|
    local_url = url.sub("127.0.0.1", "localhost")
    assert.call(adapter.call("GET", local_url + "/v1/health", {}, nil, positive_fixture_timeout)[:status] == 200, "localhost falls back from refused IPv6 to listening IPv4")
  end
  refused_listener = TCPServer.new("127.0.0.1", 0)
  refused_port = refused_listener.addr[1]
  refused_listener.close
  refused_began = KIFMultiplayer.monotonic
  begin
    adapter.call("GET", "http://127.0.0.1:#{refused_port}/v1/health", {}, nil, 0.3)
    raise "FAIL refused connection accepted"
  rescue SystemCallError, KIFMultiplayer::Error => error
    raise if error.is_a?(KIFMultiplayer::Error) && error.code != "network_timeout"
    assert.call(KIFMultiplayer.monotonic - refused_began < 0.5, "refused connection or OS delay respects one connect deadline")
  end
  began = KIFMultiplayer.monotonic
  serve.call([0.12, response.call('{"ok":true}')]) do |url, _|
    reject.call("read deadline bounds stalled server", "network_timeout") { adapter.call("GET", url + "/v1/health", {}, nil, 0.025) }
  end
  assert.call(KIFMultiplayer.monotonic - began < 0.5, "read timeout does not extend for new response bytes")
  serve.call([0.12, response.call('{"ok":true}')]) do |url, _|
    bounded_profile = TransportTestProfile.new(url)
    bounded_client = KIFMultiplayer::Client.new(bounded_profile, KIFMultiplayer::HTTPTransport.new)
    bounded_client.define_singleton_method(:pump) { sleep(0.001) }
    begin
      bounded_client.request("POST", "/v1/rooms", {}, 0.025)
      raise "FAIL actual Socket timeout accepted"
    rescue KIFMultiplayer::UncertainRequest
      assert.call(!bounded_profile.account["pending"].nil?, "actual Socket timeout preserves the operation journal")
    end
    bounded_worker = bounded_client.instance_variable_get(:@inflight_worker)
    assert.call(!bounded_worker || bounded_worker.join(0.2), "actual Socket worker exits on its own IO deadline")
    assert.call(KIFMultiplayer.network_workers.empty?, "actual Socket timeout eventually releases native HTTP guard")
  end
  write_listener = TCPServer.new("127.0.0.1", 0)
  write_socket = TCPSocket.new("127.0.0.1", write_listener.addr[1])
  write_peer = write_listener.accept
  begin
    reject.call("repeated partial-write waits do not extend the deadline", "network_timeout") do
      KIFMultiplayer::SocketHTTP.new.write_all(TransportBlockedWriter.new(write_socket), "body".b, KIFMultiplayer.monotonic + 0.025)
    end
  ensure
    write_socket.close unless write_socket.closed?
    write_peer.close unless write_peer.closed?
    write_listener.close
  end

  profile = TransportTestProfile.new("http://localhost:8765")
  slow = TransportSlowFake.new(0.05)
  client = KIFMultiplayer::Client.new(profile, slow)
  pumps = 0
  client.define_singleton_method(:pump) { pumps += 1; sleep(0.001) }
  assert.call(client.request("POST", "/v1/rooms", {})["ok"], "Client naturally joins successful worker")
  assert.call(pumps > 1 && slow.completed == 1 && slow.kill_calls.empty? && client.instance_variable_get(:@inflight_worker).nil? && KIFMultiplayer.network_workers.empty?, "successful worker pumps UI, is never killed and unregisters")
  assert.call(profile.account["pending"].nil?, "successful operation clears its journal")
  slow.delay = 0.12
  reject.call("main-thread deadline remains uncertain", "network_timeout") { client.raw_request("GET", "/v1/health", {}, 0.01) }
  inflight = client.instance_variable_get(:@inflight_worker)
  assert.call(inflight.alive? && KIFMultiplayer.network_workers.include?(inflight) && slow.kill_calls.empty?, "timed-out worker remains guarded and is not killed")
  reject.call("inflight request forbids overlapping retries", "network_busy") { client.raw_request("GET", "/v1/health", {}, 0.01) }
  inflight.join
  assert.call(slow.completed == 2 && KIFMultiplayer.network_workers.empty?, "timeout worker finishes naturally and dead guard is pruned")
  slow.delay = 0.05
  client.define_singleton_method(:pump) { raise "intentional scene pump interruption" }
  begin
    client.raw_request("GET", "/v1/health", {}, 1)
    raise "FAIL scene interruption not propagated"
  rescue RuntimeError => error
    raise unless error.message == "intentional scene pump interruption"
  end
  interrupted = client.instance_variable_get(:@inflight_worker)
  assert.call(interrupted.alive? && slow.kill_calls.empty?, "scene pump failure retains live worker without kill")
  interrupted.join
  assert.call(slow.completed == 3 && KIFMultiplayer.network_workers.empty?, "interrupted worker cleans up after natural completion")

  thread = Thread.new { sleep(0.05) }
  KIFMultiplayer.register_worker(thread)
  before = KIF::Platform.instance_variable_get(:@transport_test_native_calls).to_i
  assert.call(KIF::Platform.http_get("http://legacy.invalid")[:status] == 0 && KIF::Platform.http_post_body("http://legacy.invalid", '{}', 'application/json')[:status] == 0, "legacy native HTTP deferred while registered worker is alive")
  assert.call(KIF::Platform.instance_variable_get(:@transport_test_native_calls).to_i == before, "deferred native guard never enters unsafe binding")
  thread.join
  assert.call(KIF::Platform.http_get("http://legacy.invalid")[:status] == 200, "normal single-player native path restored when no worker is alive")
  $transport_test_android = true
  KIF::Platform.instance_variable_set(:@http_adapter, nil)
  android = KIFMultiplayer::HTTPTransport.new
  reject.call("Android without explicit adapter fails closed", "network_unavailable") { android.validate_url("https://localhost/v1/health") }
  explicit = Object.new
  explicit.define_singleton_method(:get) { |*| {:status => 200, :body => '{"ok":true}'} }
  explicit.define_singleton_method(:post_body) { |*| {:status => 200, :body => '{"ok":true}'} }
  KIF::Platform.install_http_adapter(explicit)
  assert.call(android.backend == :platform && android.call("GET", "https://localhost/v1/health", {}, nil, 1)[:status] == 200, "Android retains explicitly installed verified adapter")
  $transport_test_android = false

  if KIFMultiplayer::SocketHTTP.ssl_available?
    require "openssl"
    # Certificate checks are correctness tests, not the short-deadline test.
    # The one budget includes localhost IPv6 fallback and TLS thread scheduling
    # while native Game.exe acceptance processes may also be using the CPU.
    tls_fixture_timeout = positive_fixture_timeout
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version, certificate.serial = 2, 1
    certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.issuer, certificate.public_key = certificate.subject, key.public_key
    certificate.not_before, certificate.not_after = Time.now - 60, Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate, extensions.issuer_certificate = certificate, certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost"))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    tls_serve = lambda do |&action|
      listener = TCPServer.new("127.0.0.1", 0)
      context = OpenSSL::SSL::SSLContext.new
      context.cert, context.key = certificate, key
      wrapped = OpenSSL::SSL::SSLServer.new(listener, context)
      worker = Thread.new do
        peer = nil
        begin
          peer = wrapped.accept
          request = "".b
          request << peer.readpartial(4096) until request.include?("\r\n\r\n")
          peer.write(response.call('{"ok":true}'))
        rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
        ensure
          peer.close if peer && !peer.closed?
        end
      end
      worker.report_on_exception = false if worker.respond_to?(:report_on_exception=)
      begin
        action.call(listener.addr[1])
      ensure
        listener.close
        raise "TLS fixture failed to finish" unless worker.join(tls_fixture_timeout)
      end
    end
    tls_serve.call do |port|
      begin
        KIFMultiplayer::SocketHTTP.new.call("GET", "https://localhost:#{port}/v1/health", {}, nil, tls_fixture_timeout)
        raise "FAIL untrusted TLS certificate accepted"
      rescue OpenSSL::SSL::SSLError
        assert.call(true, "TLS certificate chain verification rejects untrusted server")
      end
    end
    trusted = KIFMultiplayer::SocketHTTP.new
    trusted.define_singleton_method(:tls_context) do
      context = OpenSSL::SSL::SSLContext.new
      context.set_params
      store = OpenSSL::X509::Store.new
      store.add_cert(certificate)
      context.cert_store = store
      context
    end
    tls_serve.call { |port| assert.call(trusted.call("GET", "https://localhost:#{port}/v1/health", {}, nil, tls_fixture_timeout)[:status] == 200, "TLS verified hostname and trusted certificate succeed") }
    tls_serve.call do |port|
      begin
        trusted.call("GET", "https://127.0.0.1:#{port}/v1/health", {}, nil, tls_fixture_timeout)
        raise "FAIL TLS hostname mismatch accepted"
      rescue OpenSSL::SSL::SSLError
        assert.call(true, "TLS hostname mismatch is rejected")
      end
    end
  else
    reject.call("actual native runtime explicitly rejects HTTPS without OpenSSL", "unsupported_https") { adapter.validate_url("https://localhost/v1/health") }
  end
  passed = true
  log.puts("TRANSPORT_ALL_PASS checks=#{checks} pid=#{Process.pid} ruby=#{RUBY_VERSION} backend=#{adapter.backend}")
  log.flush
  puts "TRANSPORT_ALL_PASS checks=#{checks}"
rescue Exception => error
  log.puts("TRANSPORT_FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  log.flush
  STDERR.puts("TRANSPORT_FAIL #{error.class}: #{error.message}")
  raise unless defined?(System)
ensure
  $transport_test_android = false
  log.close unless log.closed?
  exit!(passed ? 0 : 1) if defined?(System)
end
