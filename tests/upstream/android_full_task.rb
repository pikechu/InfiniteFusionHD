# Full branch sources in the installed Android runtime, with isolated fixtures.
load "kif_android_preload.rb"
root = File.join(ENV.fetch("KIF_ANDROID_FILES"), "diagnostics", "upstream-sheets")
config = HTTPLite::JSON.parse(File.read(File.join(root, "config.json")))
ENV["KIF_TEST_SOURCE_ROOT"] = File.expand_path(config.fetch("source_root"))
ENV["KIF_MULTIPLAYER_SAVE_DIR"] = File.join(ENV.fetch("KIF_TEST_SOURCE_ROOT"), "saves")
ENV["KIF_MULTIPLAYER_PROFILE"] = "android-upstream-u09"
ENV["KIF_UPSTREAM_TASK"] = "U09"
Dir.mkdir(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR")) unless File.directory?(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"))
module Kernel
  alias_method :upstream_native_exit!, :exit!
  def exit!(status = false)
    root = File.join(ENV.fetch("KIF_ANDROID_FILES"), "diagnostics", "upstream-sheets")
    log = File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"), "feature-smoke.log")
    rss = File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1].to_i
    File.write(File.join(root, "result.json"), HTTPLite::JSON.stringify({"passed" => status == 0, "ruby" => RUBY_VERSION, "rss_at_exit_kib" => rss, "native_log" => (File.file?(log) ? File.read(log) : "missing log")}))
    upstream_native_exit!(status)
  end
end
load File.join(ENV.fetch("KIF_TEST_SOURCE_ROOT"), "tests/upstream/native_task.rb")
