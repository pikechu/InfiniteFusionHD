# Standalone Ruby and bundled mkxp customScript; no external collector traffic.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
# Exercise the standalone main-branch client without the multiplayer codec.
load "Data/Scripts/055_Analytics/001_Analytics.rb"
directory = ENV["KIF_MULTIPLAYER_SAVE_DIR"] || File.join(root, "temp/analytics-client-test")
missing = []
parent = directory
until File.directory?(parent)
  missing.unshift(parent)
  parent = File.dirname(parent)
end
missing.each { |path| Dir.mkdir(path) }
log = File.open(File.join(directory, "analytics-test.log"), "w")
checks = 0
assert = lambda do |value, message|
  raise "FAIL #{message}" unless value
  checks += 1
  log.puts("PASS #{message}")
  log.flush
end
reject = lambda do |config, message|
  rejected = false
  begin
    KIF::Analytics.validate_config(config)
  rescue ArgumentError
    rejected = true
  end
  assert.call(rejected, message)
end

class FakeAnalyticsCollector
  attr_reader :events, :cancelled
  attr_accessor :busy, :raises, :accept
  def initialize; @events = []; @accept = true; end
  def busy?; !!@busy; end
  def cancel; @cancelled = true; @busy = false; end
  def send_async(endpoint, body)
    raise IOError, "simulated failure" if @raises
    return false unless @accept
    @events << [endpoint, body]
    true
  end
end

begin
  config = KIF::Analytics.parse(File.binread("Data/analytics.json"))
  assert.call(config["site_id"].is_a?(Integer), "parsed config site ID retains integer semantics without multiplayer")
  assert.call(KIF::Analytics.validate_config(config).nil?, "shipped config has no enabled collection")
  config["enabled"] = true
  config["endpoint"] = "https://analytics.example.test/matomo.php"
  assert.call(KIF::Analytics.validate_config(config)["heartbeat_seconds"] == 300, "valid public config accepted")
  ["http://example.test/matomo.php", "https://user:pass@example.test/matomo.php", "https://example.test/matomo.php?token_auth=secret", "https://example.test/#fragment", "https://example.test:65536/matomo.php", "https://example.test/\n"].each do |url|
    reject.call(config.merge("endpoint" => url), "unsafe collector endpoint rejected: #{url.inspect}")
  end
  reject.call(config.merge("dimensions" => config["dimensions"].merge("channel" => 1)), "overlapping dimensions rejected")
  reject.call(config.merge("site_id" => "1"), "string site ID rejected")
  reject.call(config.merge("site_id" => 1.5), "fractional site ID rejected")
  reject.call(config.merge("channel" => "bad\nchannel"), "control character in channel rejected")
  assert.call(KIF::Analytics.validate_config(config.merge("heartbeat_seconds" => 1))["heartbeat_seconds"] == 60, "heartbeat bounded below")
  assert.call(KIF::Analytics.validate_config(config.merge("heartbeat_seconds" => 99999))["heartbeat_seconds"] == 3600, "heartbeat bounded above")

  state_path = File.join(directory, "analytics-state.json")
  File.delete(state_path) if File.file?(state_path) # This suite's isolated save root only.
  disabled = FakeAnalyticsCollector.new
  tracker = KIF::Analytics::Tracker.new(config.merge("enabled" => false), directory, "test", disabled)
  tracker.tick(0)
  assert.call(disabled.events.empty? && !File.file?(state_path), "disabled stats write no identity and send nothing")

  collector = FakeAnalyticsCollector.new
  tracker = KIF::Analytics::Tracker.new(config, directory, "0.20.7", collector)
  tracker.tick(0)
  assert.call(collector.events.length == 1 && collector.events[0][1].include?("e_a=app_start"), "one real start event submitted")
  params = tracker.parameters("active")
  assert.call(params["_id"].match?(/\A[0-9a-f]{16}\z/), "random visitor ID has Matomo format")
  first_id = params["_id"]
  assert.call(KIF::Analytics.parse(File.binread(state_path))["visitor_id"] == first_id, "visitor ID persisted before sending")
  assert.call(params.keys.sort == %w[_id apiv ca cookie dimension1 dimension2 dimension3 dimension4 dimension5 e_a e_c idsite rec send_image url].sort, "only allowlisted fields sent; no trainer/save/account/token fields")
  assert.call(params["dimension1"] == "windows" && params["dimension2"] == "0.20.7", "platform and version dimensions populated")
  assert.call(!params.key?("uid") && !params.key?("cip"), "client has no account ID or IP override")
  encoded = tracker.encode({"unicode" => "中文+&", "space" => "a b"})
  assert.call(encoded == "unicode=%E4%B8%AD%E6%96%87%2B%26&space=a%20b", "UTF-8 form values encoded without command interpolation")
  tracker.tick(299)
  assert.call(collector.events.length == 1, "render ticks do not duplicate events or speed up heartbeat")
  collector.busy = true
  tracker.tick(300)
  assert.call(collector.events.length == 1, "busy transport never builds a queue")
  collector.busy = false
  tracker.tick(301)
  assert.call(collector.events.length == 2 && collector.events.last[1].include?("e_a=active"), "next live tick sends active event")
  tracker.tick(90000)
  assert.call(collector.events.length == 3 && !collector.events.last[1].include?("cdt="), "long/midnight sessions send current activity without offline replay")
  reloaded = KIF::Analytics::Tracker.new(config, directory, "new version", FakeAnalyticsCollector.new)
  assert.call(reloaded.parameters("app_start")["_id"] == first_id, "restart/version changes preserve installation identity")
  tracker.enabled = false
  tracker.tick(100000)
  assert.call(collector.events.length == 3 && collector.cancelled, "opt-out cancels pending work and future sends")
  state = KIF::Analytics.parse(File.binread(state_path))
  assert.call(state == {"enabled" => false}, "opt-out erases persistent installation ID")
  opted_out = KIF::Analytics::Tracker.new(config, directory, "test", FakeAnalyticsCollector.new)
  assert.call(!opted_out.enabled?, "opt-out survives restart")
  tracker.enabled = true
  assert.call(tracker.parameters("app_start")["_id"] != first_id, "opt-in after opt-out starts a fresh unrelated ID")
  saved = File.binread(state_path)
  tracker.enabled = true
  assert.call(File.binread(state_path) == saved, "unchanged option does not rewrite identity")

  File.binwrite(state_path, "{corrupt")
  corrupt = KIF::Analytics::Tracker.new(config, directory, "test", FakeAnalyticsCollector.new)
  assert.call(!corrupt.enabled?, "corrupt state fails closed")
  corrupt.enabled = true
  assert.call(corrupt.enabled?, "explicit opt-in can repair corrupt preferences")
  failing = FakeAnalyticsCollector.new
  failing.raises = true
  broken = KIF::Analytics::Tracker.new(config, directory, "test", failing)
  broken.tick(0)
  assert.call(!broken.enabled? && failing.cancelled, "transport exception contained outside gameplay")

  # Exercise actual process creation, piped form input and nonblocking reaping in
  # the bundled game VM, using a harmless local collector instead of the network.
  if RUBY_PLATFORM.match?(/mswin|mingw/i)
    script = File.join(directory, "collector-probe.ps1")
    marker = File.join(directory, "collector-probe.ok")
    File.delete(marker) if File.file?(marker)
    File.write(script, "$inputBody = [Console]::In.ReadToEnd()\n[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'collector-probe.ok'), $inputBody)\nif ($inputBody -ceq 'probe=ok') { exit 0 }; exit 2\n")
    actual = KIF::Analytics::WindowsCollector.new(script)
    assert.call(actual.send_async("https://example.invalid/matomo.php", "probe=ok"), "Windows collector child starts and receives stdin")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    frames = 0
    while actual.busy? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      if defined?(Graphics)
        Graphics.update
        Input.update
        frames += 1
      else
        sleep 0.01
      end
    end
    assert.call(!actual.busy?, "Windows child reaped without network or gameplay wait")
    assert.call(actual.last_status == 0 && File.binread(marker) == "probe=ok", "child really executed successfully and consumed exactly the encoded payload")
    assert.call(frames > 1, "native render frames continue while collector runs") if defined?(Graphics)
    assert.call(!actual.send_async("http://example.invalid", "probe=ok"), "actual Windows adapter refuses cleartext")
  end
  log.puts("ANALYTICS_CLIENT_PASS checks=#{checks}")
  puts "ANALYTICS_CLIENT_PASS checks=#{checks}"
rescue Exception => error
  log.puts("ANALYTICS_CLIENT_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  raise unless defined?(Graphics)
ensure
  log.close
  exit if defined?(Graphics)
end
