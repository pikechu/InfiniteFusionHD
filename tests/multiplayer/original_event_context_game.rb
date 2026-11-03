begin
  load "scripts/multiplayer/test-bootstrap.rb"
  report = KIFMultiplayer::WireJSON.parse(File.read(File.join(ENV.fetch("KIF_ORIGINAL_EVENT_REPORT"))))
  context = Interpreter.new
  availability = report.fetch("unknown").keys.to_h { |name| [name, context.respond_to?(name, true)] }
  constants = report.fetch("unknown_constants", {}).keys.to_h { |name| [name, Object.const_defined?(name)] }
  File.write(File.join($kif_test_directory, "original-event-constants.json"), KIFMultiplayer::WireJSON.dump(constants))
  File.write(File.join($kif_test_directory, "original-event-context.json"), KIFMultiplayer::WireJSON.dump(availability))
  KIFMultiplayerFeatureTest.log("ORIGINAL_EVENT_CONTEXT_PASS total=#{availability.length} available=#{availability.values.count(true)}")
  exit!(0)
rescue Exception => error
  $kif_test_log.call("ORIGINAL_EVENT_CONTEXT_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
  exit!(1)
end
