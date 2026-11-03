# Exercise real Android touch events through the production JNI/Ruby input backend.
require "./kif_android_input.rb"
raise "Native Android input helper missing" unless defined?(KIFAndroidBridge)
KIF::AndroidInputBackend.install(Input, KIFAndroidBridge)
received = []
[2, 13, 12].each do |code|
  Input.update
  File.write($qa_stage, "input-ready-#{code}")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
  loop do
    Graphics.update
    Input.update
    if Input.trigger?(code)
      received << code
      break
    end
    raise "Android touch input timeout: #{code}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
raise "Incorrect touch sequence" unless received == [2, 13, 12]
File.write(File.join(ENV.fetch("KIF_SAVE_DIR"), "touch-input-result.json"), HTTPLite::JSON.stringify({"received" => received, "native_bridge" => true}))
exit!(0)
