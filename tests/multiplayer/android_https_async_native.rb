# Dedicated network-probe APK only. Uses its own app directory and fixture CA.
begin
  load "kif_android_preload.rb"
  %w[000_Platform.rb 001_Client.rb 015_Transport.rb 020_AndroidNetwork.rb].each { |path| load path }
  config = KIFMultiplayer::WireJSON.parse(File.read("probe-config.json"))
  root = ENV.fetch("KIF_ANDROID_FILES")
  checks, measurements = [], []
  check = lambda do |condition, name|
    raise "FAIL #{name}" unless condition
    checks << name
    System.puts("ASYNC_HTTPS_CHECK #{name}")
  end
  check.call(System.is_android? && KIFAndroidBridge.http_async_version >= 1, "updated JNI and Java asynchronous APIs are configured")
  # Any accidental regression to the blocking entry point fails this probe.
  KIFAndroidBridge.define_singleton_method(:request) { |*| raise "Blocking JNI HTTPS was called" }
  transport = KIFMultiplayer::HTTPTransport.new
  Graphics.resize_screen(512, 384)
  canvas = Bitmap.new(512, 384)
  sprite = Sprite.new
  sprite.bitmap = canvas
  Graphics.transition(0)
  tick_count = 0
  draw = lambda do
    canvas.fill_rect(0, 0, 512, 384, Color.new(20, 32, 45))
    canvas.fill_rect((tick_count * 5) % 460, 140, 48, 48, Color.new(80, 190, 245))
    canvas.fill_rect(12, 340, tick_count % 488, 12, Color.new(100, 220, 130))
    Graphics.update
    Input.update
    tick_count += 1
  end
  measure = lambda do |label, timeout, path|
    started, frames, max_poll = KIFMultiplayer.monotonic, 0, 0.0
    task = KIFMultiplayer.network_worker do
      begin
        transport.call("GET", config["server"] + path, {}, nil, timeout)
      rescue KIFMultiplayer::Error => error
        {"error" => error.code}
      end
    end
    while task.alive?
      before = KIFMultiplayer.monotonic
      task.poll
      max_poll = [max_poll, KIFMultiplayer.monotonic - before].max
      draw.call
      frames += 1
    end
    result = task.value
    elapsed = KIFMultiplayer.monotonic - started
    measurements << {"name" => label, "elapsed" => elapsed, "frames" => frames, "input_updates" => frames, "max_poll_seconds" => max_poll}
    [result, elapsed, frames, max_poll]
  end
  response, elapsed, frames, max_poll = measure.call("delayed_https", 10, "/probe/slow")
  check.call(response[:status] == 200 && KIFMultiplayer::WireJSON.parse(response[:body])["ok"], "trusted HTTPS completes through asynchronous JNI")
  check.call(elapsed >= 3.8 && frames >= 40 && max_poll < 0.8, "four-second HTTPS wait keeps Graphics and Input updating")

  response, elapsed, frames, max_poll = measure.call("deadline", 0.4, "/probe/timeout")
  check.call(response["error"] == "network_timeout" && elapsed < 2.0 && frames >= 3, "short HTTPS deadline cancels promptly while rendering continues")
  response, = measure.call("recovery", 5, "/v1/health")
  check.call(response[:status] == 200, "HTTPS recovers after cancellation and timeout")

  cancelled = KIFMultiplayer.network_worker { transport.call("GET", config["server"] + "/probe/timeout", {}, nil, 10) }
  8.times { cancelled.poll; draw.call }
  before_cancel = KIFMultiplayer.monotonic
  cancelled.cancel
  check.call(!cancelled.alive? && KIFMultiplayer.monotonic - before_cancel < 0.5, "closing a pending HTTPS request does not wait for the server")

  parallel = 2.times.map { KIFMultiplayer.network_worker { transport.call("GET", config["server"] + "/probe/parallel", {}, nil, 8) } }
  parallel_frames = 0
  while parallel.any?(&:alive?)
    parallel.each(&:poll)
    draw.call
    parallel_frames += 1
  end
  check.call(parallel.all? { |task| task.value[:status] == 200 } && parallel_frames >= 20, "two background HTTPS requests allow frames to continue")

  untrusted = KIFMultiplayer.network_worker { KIF::Platform.http_get(config["untrusted"]) }.value
  check.call(untrusted[:status] == 0 && untrusted[:error].to_s.start_with?("SSL"), "untrusted certificate remains rejected")
  report = {"passed" => true, "ruby" => RUBY_VERSION, "async_version" => KIFAndroidBridge.http_async_version,
    "checks" => checks, "measurements" => measurements, "parallel_frames" => parallel_frames}
  File.write(File.join(root, "https-async-result.json"), KIFMultiplayer::WireJSON.dump(report))
  System.puts("ASYNC_HTTPS_NATIVE_PASS checks=#{checks.length}")
rescue Exception => error
  report = {"passed" => false, "error" => "#{error.class}: #{error.message}", "backtrace" => error.backtrace}
  File.write(File.join(ENV.fetch("KIF_ANDROID_FILES"), "https-async-result.json"), KIFMultiplayer::WireJSON.dump(report)) if defined?(KIFMultiplayer::WireJSON)
  System.puts("ASYNC_HTTPS_NATIVE_FAIL #{error.class}: #{error.message}")
end
loop { Graphics.update; Input.update }
