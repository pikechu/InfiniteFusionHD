# Runtime diagnosis only: no RPG scripts, sprites, moves, playback or Thread.kill.
# Exercise native HTTP response creation concurrently with ordinary Ruby GC.
passed = false
begin
  load "scripts/multiplayer/runtime-preload.rb"
  mode = ENV.fetch("KIF_GVL_TRANSPORT", "httplite")
  raise "Unknown transport mode" unless %w[httplite socket production].include?(mode)
  if mode == "socket"
    load "tests/multiplayer/native_socket_transport.rb"
    transport = NativeSocketDiagnosticTransport.new
  elsif mode == "production"
    load "Data/Scripts/054_Multiplayer/001_Client.rb"
    load "Data/Scripts/054_Multiplayer/015_Transport.rb"
    transport = KIFMultiplayer::SocketHTTP.new
  end
  path = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "http-gvl-probe.log")
  log = proc { |value| File.open(path, "a") { |file| file.puts("#{Time.now.utc} #{value}"); file.flush } }
  log.call("BEGIN pid=#{Process.pid} ruby=#{RUBY_VERSION} transport=#{mode} no_graphics=true no_sprites=true no_thread_kill=true")
  requests = 0
  worker = Thread.new do
    200.times do
      response = if transport
                   transport.call("GET", "http://127.0.0.1:18785/probe", nil, nil, 10)
                 else
                   HTTPLite.get("http://127.0.0.1:18785/probe")
                 end
      raise "Invalid native response" unless response.is_a?(Hash) && response[:status] == 200 && response[:body].bytesize > 16000
      requests += 1
      log.call("HTTP_PROGRESS requests=#{requests}") if requests % 25 == 0
    end
  end
  sweeps = 0
  while worker.alive?
    1000.times { ["diagnostic allocation".dup, {"nested" => [1, 2, 3]}] }
    GC.start
    sweeps += 1
    Thread.pass
  end
  worker.join
  worker.value
  log.call("HTTP_GVL_PROBE_PASS requests=#{requests} sweeps=#{sweeps} gc=#{GC.stat[:count]}")
  passed = true
rescue Exception => error
  log.call("HTTP_GVL_PROBE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(log) && log
ensure
  exit!(passed ? 0 : 1)
end
