# Matomo owns storage, geolocation, aggregation and reports. This adapter sends
# only allowlisted usage fields; it never reads trainer data or multiplayer IDs.
module KIF
  module Analytics
    DIMENSIONS = %w[platform app_version device_model manufacturer channel].freeze

    def self.parse(text)
      return KIFMultiplayer::WireJSON.parse(text) if defined?(KIFMultiplayer::WireJSON)
      return normalize_native_numbers(HTTPLite::JSON.parse(text)) if defined?(HTTPLite::JSON)
      require "json"
      JSON.parse(text)
    rescue Exception => error
      # mkxp raises its non-StandardError MKXPError for malformed JSON. Convert
      # that one native failure so corrupt analytics files cannot stop boot.
      raise ArgumentError, "Invalid analytics JSON" if defined?(MKXPError) && error.is_a?(MKXPError)
      raise
    end

    # mkxp's native parser represents every JSON number as a Float. Restore
    # integral values so the standalone client can validate numeric config IDs.
    def self.normalize_native_numbers(value, depth = 0)
      raise ArgumentError, "Analytics JSON is too deeply nested" if depth > 8
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key] = normalize_native_numbers(item, depth + 1) }
      when Array then value.map { |item| normalize_native_numbers(item, depth + 1) }
      when Float then value.finite? && value == value.to_i ? value.to_i : value
      else value
      end
    end

    def self.dump(value)
      return KIFMultiplayer::WireJSON.dump(value) if defined?(KIFMultiplayer::WireJSON)
      return HTTPLite::JSON.stringify(value) if defined?(HTTPLite::JSON)
      require "json"
      JSON.generate(value)
    end

    def self.https_url?(value)
      return false unless value.is_a?(String) && value.bytesize <= 2048 && value.ascii_only?
      match = /\Ahttps:\/\/([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::([0-9]{1,5}))?(\/[^\x00-\x20\x7f?#\\]*)?\z/.match(value)
      return false unless match
      return false if match[2] && !match[2].to_i.between?(1, 65535)
      host = match[1]
      host.start_with?("[") || (host.bytesize <= 253 && host.split(".", -1).all? { |part| part =~ /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/ })
    end

    def self.validate_config(config)
      raise ArgumentError, "Invalid analytics config" unless config.is_a?(Hash)
      return nil unless config["enabled"] == true
      raise ArgumentError, "Analytics requires HTTPS" unless https_url?(config["endpoint"]) && https_url?(config["app_url"])
      raise ArgumentError, "Invalid analytics site" unless config["site_id"].is_a?(Integer) && config["site_id"] > 0
      channel = config["channel"]
      raise ArgumentError, "Invalid analytics channel" unless channel.is_a?(String) && channel.bytesize.between?(1, 100) && !channel.match?(/[\x00-\x1f\x7f]/)
      dimensions = config["dimensions"]
      raise ArgumentError, "Invalid analytics dimensions" unless dimensions.is_a?(Hash)
      ids = DIMENSIONS.map { |name| dimensions[name] }
      raise ArgumentError, "Invalid analytics dimension IDs" unless ids.all? { |id| id.is_a?(Integer) && id.between?(0, 999) }
      used = ids.reject(&:zero?)
      raise ArgumentError, "Duplicate analytics dimensions" unless used.uniq == used
      interval = config["heartbeat_seconds"]
      raise ArgumentError, "Invalid analytics interval" unless interval.is_a?(Integer)
      result = config.dup
      result["dimensions"] = dimensions.dup
      result["heartbeat_seconds"] = [[interval, 60].max, 3600].min
      result
    end

    # A child process avoids both unavailable Ruby TLS and unsafe native HTTP
    # concurrency. Polling never waits for network I/O on the render thread.
    class WindowsCollector
      attr_reader :last_status
      def initialize(script = File.expand_path("Data/analytics/windows-collector.ps1"))
        @script = script
      end

      def busy?
        return false unless @pid
        result = Process.waitpid2(@pid, Process::WNOHANG)
        if result
          @last_status = result[1].exitstatus
          @pid = nil
        elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started > 12
          cancel
        end
        !@pid.nil?
      rescue Errno::ECHILD
        @pid = nil
        false
      end

      def send_async(endpoint, body)
        return false if busy? || body.bytesize > 4096 || !File.file?(@script)
        return false unless Analytics.https_url?(endpoint)
        # Use the OS path rather than searching a game/mod-controlled PATH.
        executable = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32/WindowsPowerShell/v1.0/powershell.exe")
        return false unless File.file?(executable)
        reader, writer = IO.pipe
        # Scope execution policy to this trusted bundled script's child only;
        # never alter the machine/user policy or any sandbox configuration.
        @pid = Process.spawn(executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
                             "-ExecutionPolicy", "Bypass",
                             "-File", @script, "-Endpoint", endpoint,
                             :in => reader, :out => File::NULL, :err => File::NULL)
        @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reader.close
        writer.write(body)
        true
      rescue StandardError
        cancel
        false
      ensure
        reader.close if reader && !reader.closed?
        writer.close if writer && !writer.closed?
      end

      def cancel
        return unless @pid
        Process.kill("KILL", @pid)
        Process.detach(@pid) # Reap only this child, without waiting in the game.
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        @pid = nil
      end
    end

    class Tracker
      attr_reader :config
      def initialize(config, directory, version, collector = WindowsCollector.new)
        @config = Analytics.validate_config(config)
        @path = File.join(directory, "analytics-state.json")
        @version, @collector = version.to_s[0, 100], collector
        @state = read_state
        @next_check = @next_send = 0
        @starting = true
      end

      def read_state
        return {"enabled" => true} unless File.file?(@path)
        raise ArgumentError, "Analytics state too large" if File.size(@path) > 4096
        state = Analytics.parse(File.binread(@path))
        raise ArgumentError, "Invalid analytics state" unless state.is_a?(Hash) && [true, false].include?(state["enabled"])
        id = state["visitor_id"]
        raise ArgumentError, "Invalid analytics identity" if id && (!id.is_a?(String) || !id.match?(/\A[0-9a-f]{16}\z/))
        state.select { |key, _value| %w[enabled visitor_id].include?(key) }
      rescue StandardError
        {"enabled" => false}
      end

      def enabled?
        !!(@config && @state["enabled"])
      end

      def enabled=(value)
        return if @state["enabled"] == !!value
        previous = @state
        @state = {"enabled" => !!value}
        @state["visitor_id"] = previous["visitor_id"] if value && previous["enabled"] && previous["visitor_id"]
        persist
        @collector.cancel unless value
        @next_send = 0
        @starting = true if value && !previous["enabled"]
      rescue StandardError
        @state = {"enabled" => false}
        @collector.cancel
      end

      def persist
        temporary = @path + ".pending-#{Process.pid}"
        File.binwrite(temporary, Analytics.dump(@state))
        File.rename(temporary, @path)
      ensure
        File.delete(temporary) if temporary && File.file?(temporary)
      end

      def visitor_id
        return @state["visitor_id"] if @state["visitor_id"]
        @state["visitor_id"] = Random.urandom(8).unpack("H*").first
        persist # Never send an ID that could not be persisted across restarts.
        @state["visitor_id"]
      end

      def parameters(action)
        values = {"platform" => "windows", "app_version" => @version,
                  "device_model" => "desktop", "manufacturer" => "unknown", "channel" => @config["channel"]}
        params = {"rec" => "1", "apiv" => "1", "idsite" => @config["site_id"].to_s,
                  "_id" => visitor_id, "cookie" => "0", "send_image" => "0",
                  "url" => @config["app_url"].sub(/\/+\z/, "") + "/windows",
                  "e_c" => "game", "e_a" => action, "ca" => "1"}
        values.each do |name, value|
          id = @config["dimensions"][name]
          params["dimension#{id}"] = value if id > 0
        end
        params
      end

      def encode(params)
        params.map do |key, value|
          [key, value].map { |part| part.to_s.b.bytes.map { |byte| byte.chr.match?(/[A-Za-z0-9_.~-]/) ? byte.chr : "%%%02X" % byte }.join }.join("=")
        end.join("&")
      end

      def tick(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
        return if now < @next_check
        @next_check = now + 1
        busy = @collector.busy?
        return unless enabled? && !busy && now >= @next_send
        body = encode(parameters(@starting ? "app_start" : "active"))
        @starting = false if @collector.send_async(@config["endpoint"], body)
        # No retries or offline timestamps: Matomo must not count old activity today.
        @next_send = now + @config["heartbeat_seconds"]
      rescue StandardError
        @state = {"enabled" => false}
        @collector.cancel
      end
    end

    class << self
      def start
        return if @tracker || (defined?(Platform) && Platform.android?)
        return if $DEBUG || ENV["KIF_ANALYTICS_DISABLED"] == "1" || ENV["KIF_MULTIPLAYER_SAVE_DIR"]
        return unless RUBY_PLATFORM.match?(/mswin|mingw/i)
        path = "Data/analytics.json"
        return unless File.file?(path) && File.size(path) <= 8192
        config = validate_config(parse(File.binread(path)))
        return unless config
        @tracker = Tracker.new(config, System.data_directory, Settings::GAME_VERSION_NUMBER)
        @tracker.tick
      rescue StandardError
        @tracker = nil
      end

      def configured?; !@tracker.nil?; end
      def enabled?; @tracker && @tracker.enabled?; end
      def enabled=(value); @tracker.enabled = value if @tracker; end
      def tick; @tracker.tick if @tracker; end
    end

    module FrameHook
      def update(*args)
        result = super
        KIF::Analytics.tick
        result
      end
    end
  end
end

if defined?(Graphics) && !Graphics.singleton_class.ancestors.include?(KIF::Analytics::FrameHook)
  Graphics.singleton_class.prepend(KIF::Analytics::FrameHook)
end
