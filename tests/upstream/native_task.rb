# Explicit isolated native probe. No normal player saves or external requests.
passed = false
begin
  load File.join(ENV.fetch("KIF_TEST_SOURCE_ROOT", "."), "scripts/multiplayer/test-bootstrap.rb")
  module UpstreamTest
    class << self
      attr_accessor :checks
      def check(value, name)
        KIFMultiplayerFeatureTest.check(value, name)
        self.checks = (checks || 0) + 1
      end
      def override(target, name, callable)
        original = target.instance_method(name)
        target.send(:define_method, name, callable)
        yield
      ensure
        target.send(:define_method, name, original) if original
      end
    end
  end
  task = ENV.fetch("KIF_UPSTREAM_TASK")
  raise "Invalid task" unless task.match?(/\AU0[2-9]\z/)
  load File.join(ENV.fetch("KIF_TEST_SOURCE_ROOT", "."), "tests/upstream/#{task}.rb")
  KIFMultiplayerFeatureTest.log("#{task}_PASS checks=#{UpstreamTest.checks} native=true no_player_saves=true")
  passed = true
rescue Exception => error
  KIFMultiplayerFeatureTest.log("UPSTREAM_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
