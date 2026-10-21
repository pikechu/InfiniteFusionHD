# Executed by the actual bundled mkxp/Ruby process, not the standalone Ruby test VM.
begin
  load File.expand_path("scripts/multiplayer/runtime-preload.rb")
  log = lambda do |message|
    File.open($kif_multiplayer_runtime_log, "a") { |f| f.puts(message); f.flush }
  end
  log.call("PROBE engine=#{defined?(System::VERSION) ? System::VERSION : 'unknown'} pid=#{Process.pid}")
  ["json", "net/http", "socket", "digest", "digest/sha2"].each do |library|
    begin
      require library
      log.call("REQUIRE #{library} available")
    rescue LoadError => error
      log.call("REQUIRE #{library} unavailable #{error.message}")
    end
  end
  log.call("NATIVE http=#{defined?(HTTPLite)} json=#{defined?(HTTPLite::JSON)}")
  log.call("SHA256 #{Digest::SHA256.hexdigest('abc')}")
  if ENV["KIF_MULTIPLAYER_TRANSPORT_PROBE"] == "1"
    gaps = []
    ticks = 0
    previous = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    worker = Thread.new { HTTPLite.get("http://127.0.0.1:18766/probe") }
    while worker.alive?
      Graphics.update
      Input.update
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gaps << now - previous
      previous = now
      ticks += 1
      Thread.pass
    end
    response = worker.value
    log.call("TRANSPORT frames=#{ticks} max_frame_gap=#{gaps.max} status=#{response[:status]} body=#{response[:body]}")
    log.call("TRANSPORT_NONBLOCKING=#{ticks > 10 && gaps.max < 0.5}")
  end
  archive = Marshal.load(File.binread("Data/Scripts.rxdata")) # Trusted local build artifact only.
  require "zlib"
  archive.each do |entry|
    script = Zlib::Inflate.inflate(entry[2])
    log.call("ARCHIVE #{entry[1]} source_loader=#{script.include?('load_scripts_from_folder')}")
  end
  log.call("PROBE_PASS")
rescue Exception => error
  if defined?(log) && log
    log.call("PROBE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  end
ensure
  exit
end
