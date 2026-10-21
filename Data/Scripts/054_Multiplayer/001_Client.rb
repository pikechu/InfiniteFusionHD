# Multiplayer wire data is JSON only. None of the legacy Pokemon import paths
# are used here: they accept a much broader set of local-file data.
module KIFMultiplayer
  PROTOCOL = 2
  RULES_VERSION = "friendly-singles-v1"
  CLIENT_BUILD = "multiplayer-0.3.0-dev"
  MAX_RESPONSE_BYTES = 2 * 1024 * 1024
  NON_JOURNALED_POST = /\A\/v1\/(?:replays\/[A-Za-z0-9_-]+\/download|battles\/[A-Za-z0-9_-]+\/heartbeat|(?:auth|cloud|world|chat)\/[a-z]+)\z/

  class Error < StandardError
    attr_reader :code, :details
    def initialize(message, code = "client_error", details = nil)
      super(message)
      @code, @details = code, details
    end
  end
  class UncertainRequest < Error; end
  # Only a validated rejection of this exact request may clear its journal.
  # A failed operation query or a gateway error says nothing about an earlier
  # submission with the same operation ID.
  class HTTPRejected < Error; end

  # Android's translated MRI can crash while a secondary Ruby thread performs
  # socket IO. A cooperative Fiber keeps IO on the game thread and yields at
  # nonblocking socket waits, allowing Graphics/Input to continue between polls.
  class FiberWorker
    def initialize(&block)
      @fiber = Fiber.new do
        Thread.current[:kif_cooperative_network] = true
        begin
          @value = block.call
        rescue Exception => error
          @failure = error
        ensure
          Thread.current[:kif_cooperative_network] = false
        end
      end
    end
    def alive?; @fiber.alive?; end
    def poll; @fiber.resume if alive?; self; end
    def join
      while alive?
        poll
        KIFMultiplayer.pump if alive?
      end
      self
    end
    def value
      join
      raise @failure if @failure
      @value
    end
  end

  def self.network_worker(&block)
    if defined?(KIF::Platform) && KIF::Platform.android?
      FiberWorker.new(&block)
    else
      Thread.new(&block)
    end
  end

  class << self
    attr_accessor :identity_change_guard

    def persist_account(profile)
      account = profile.account
      previous = WireJSON.parse(WireJSON.dump(account))
      begin
        yield account
        profile.save
      rescue Exception
        account.replace(previous)
        raise
      end
    end

    def bound_identity_id(profile)
      account = profile.account
      candidates = []
      candidates << account.dig("pending", "identity_id")
      candidates << account.dig("gym_session", "owner_id")
      candidates << account.dig("trade_pending", "player_id")
      candidates << account.dig("pool_pending", "player_id")
      if defined?($Trainer) && $Trainer
        escrow = $Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow)
        candidates << escrow["player_id"] if escrow.is_a?(Hash) && escrow["server"] == profile.server
      end
      candidates = candidates.compact.uniq
      raise Error.new("Pending operations refer to different identities. Restore their original profile/save first.", "identity_switch_pending") if candidates.length > 1
      candidates.first
    end

    def assert_identity_change_safe!(profile, target_server = nil)
      accounts = profile.data["servers"] || {}
      bound_servers = accounts.select do |_server, account|
        account.is_a?(Hash) && %w[pending gym_session trade_pending pool_pending managed_trade_code managed_pool_id].any? { |key| account[key] }
      end.keys
      if defined?($Trainer) && $Trainer
        escrow = $Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow)
        bound_servers << escrow["server"] if escrow.is_a?(Hash) && escrow["server"]
      end
      # Recovering the one original server must remain possible after a lost
      # profile was recreated with a different default URL. This grants no
      # operation/identity permission; the saved owner is still checked later.
      return true if target_server && bound_servers.uniq == [target_server]
      unless bound_servers.empty?
        raise Error.new("Recover the pending operation on its original server before changing identity or server.", "identity_switch_pending")
      end
      if accounts.values.any? { |account| account.is_a?(Hash) && account["pending"] }
        raise Error.new("Resolve the pending operation before switching servers or identities.", "identity_switch_pending")
      end
      @identity_change_guard.call(profile) if @identity_change_guard
      true
    end
  end

  module WireJSON
    MAX_DEPTH = 32
    MAX_NODES = 100_000

    # mkxp's native JSON encoder truncates/rejects unsigned 32-bit Pokemon IDs.
    # Keep wire integers as Ruby Integers and parse only the JSON grammar; no
    # object hooks, class lookup, eval, or Marshal are involved.
    def self.parse(text, max_bytes = MAX_RESPONSE_BYTES, max_nodes = MAX_NODES)
      raise Error.new("Response is too large", "invalid_response") if text.bytesize > max_bytes
      Parser.new(text, max_nodes).parse
    rescue Error
      raise
    rescue StandardError => e
      raise Error.new("Invalid JSON response: #{e.class}", "invalid_response")
    end

    def self.dump(value)
      result = encode(value, 0)
      raise Error.new("JSON payload is too large", "invalid_json") if result.bytesize > MAX_RESPONSE_BYTES
      result
    end

    def self.string(value)
      raise Error.new("Invalid UTF-8 JSON string", "invalid_json") unless value.valid_encoding?
      escaped = value.each_codepoint.map do |code|
        case code
        when 34 then '\\"'
        when 92 then '\\\\'
        when 8 then '\\b'
        when 9 then '\\t'
        when 10 then '\\n'
        when 12 then '\\f'
        when 13 then '\\r'
        when 0...32 then '\\u%04x' % code
        else [code].pack("U")
        end
      end.join
      '"' + escaped + '"'
    end

    def self.encode(value, depth)
      raise Error.new("JSON nesting is too deep", "invalid_json") if depth > MAX_DEPTH
      case value
      when Hash
        "{" + value.map do |key, item|
          raise Error.new("JSON object keys must be strings", "invalid_json") unless key.is_a?(String)
          string(key) + ":" + encode(item, depth + 1)
        end.join(",") + "}"
      when Array then "[" + value.map { |item| encode(item, depth + 1) }.join(",") + "]"
      when String then string(value)
      when Integer then value.to_s
      when Float
        raise Error.new("Non-finite JSON number", "invalid_json") unless value.finite?
        value.to_s
      when TrueClass then "true"
      when FalseClass then "false"
      when NilClass then "null"
      else raise Error.new("Unsupported JSON value: #{value.class}", "invalid_json")
      end
    end

    class Parser
      def initialize(text, node_limit = MAX_NODES)
        @node_limit = node_limit
        @text = text.dup.force_encoding(Encoding::UTF_8)
        raise Error.new("Invalid UTF-8 JSON", "invalid_response") unless @text.valid_encoding?
        # Indices are bytes, including when strings contain Chinese characters.
        @text = @text.b
        @index, @nodes = 0, 0
      end
      def failure(message)
        raise Error.new("Invalid JSON: #{message}", "invalid_response")
      end
      def whitespace
        @index += 1 while [9, 10, 13, 32].include?(@text.getbyte(@index))
      end
      def parse
        result = value(0)
        whitespace
        failure("trailing content") unless @index == @text.bytesize
        result
      end
      def value(depth)
        failure("nesting limit exceeded") if depth > MAX_DEPTH
        @nodes += 1
        failure("node limit exceeded") if @nodes > @node_limit
        whitespace
        case @text.getbyte(@index)
        when 123 then object(depth)
        when 91 then array(depth)
        when 34 then read_string
        when 116 then literal("true", true)
        when 102 then literal("false", false)
        when 110 then literal("null", nil)
        when 45, 48..57 then number
        else failure("expected a value")
        end
      end
      def literal(token, result)
        failure("invalid literal") unless @text.byteslice(@index, token.bytesize) == token
        @index += token.bytesize
        result
      end
      def object(depth)
        @index += 1
        result = {}
        whitespace
        if @text.getbyte(@index) == 125
          @index += 1
          return result
        end
        loop do
          whitespace
          failure("expected object key") unless @text.getbyte(@index) == 34
          key = read_string
          failure("duplicate object key") if result.key?(key)
          whitespace
          failure("expected colon") unless @text.getbyte(@index) == 58
          @index += 1
          result[key] = value(depth + 1)
          whitespace
          delimiter = @text.getbyte(@index)
          @index += 1
          break if delimiter == 125
          failure("expected object delimiter") unless delimiter == 44
        end
        result
      end
      def array(depth)
        @index += 1
        result = []
        whitespace
        if @text.getbyte(@index) == 93
          @index += 1
          return result
        end
        loop do
          result << value(depth + 1)
          whitespace
          delimiter = @text.getbyte(@index)
          @index += 1
          break if delimiter == 93
          failure("expected array delimiter") unless delimiter == 44
        end
        result
      end
      def number
        match = /\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.match(@text, @index)
        failure("invalid number") unless match
        token = match[0]
        failure("number too long") if token.length > 128
        @index = match.end(0)
        result = token =~ /[.eE]/ ? Float(token) : Integer(token, 10)
        failure("non-finite number") if result.is_a?(Float) && !result.finite?
        result
      end
      def unicode
        hex = @text.byteslice(@index, 4)
        failure("invalid Unicode escape") unless hex && hex =~ /\A[0-9a-fA-F]{4}\z/
        @index += 4
        code = hex.to_i(16)
        if code.between?(0xd800, 0xdbff)
          failure("missing low surrogate") unless @text.byteslice(@index, 2) == '\\u'
          @index += 2
          low_hex = @text.byteslice(@index, 4)
          failure("invalid low surrogate") unless low_hex && low_hex =~ /\A[0-9a-fA-F]{4}\z/
          low = low_hex.to_i(16)
          failure("invalid low surrogate") unless low.between?(0xdc00, 0xdfff)
          @index += 4
          code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00
        elsif code.between?(0xdc00, 0xdfff)
          failure("unpaired low surrogate")
        end
        [code].pack("U").b
      end
      def read_string
        @index += 1
        result = "".b
        start = @index
        loop do
          byte = @text.getbyte(@index)
          failure("unterminated string") unless byte
          failure("unescaped control character") if byte < 32
          if byte == 34 || byte == 92
            result << @text.byteslice(start, @index - start)
            @index += 1
            if byte == 34
              result.force_encoding(Encoding::UTF_8)
              failure("invalid UTF-8 string") unless result.valid_encoding?
              return result
            end
            escape = @text.getbyte(@index)
            @index += 1
            escaped = case escape
                      when 34 then '"'
                      when 92 then '\\'
                      when 47 then '/'
                      when 98 then "\b"
                      when 102 then "\f"
                      when 110 then "\n"
                      when 114 then "\r"
                      when 116 then "\t"
                      when 117 then unicode
                      else failure("invalid string escape")
                      end
            result << escaped
            start = @index
          else
            @index += 1
          end
        end
      end
    end
  end

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.pump
    if defined?(Graphics)
      Graphics.update
      Input.update if defined?(Input)
    else
      sleep(0.002)
    end
  end

  def self.operation_id
    # A collision-resistant operation key, separate from the game's battle RNG.
    @operation_random ||= Random.new
    "%016x%016x" % [@operation_random.rand(0x10000000000000000),
                       @operation_random.rand(0x10000000000000000)]
  end

  def self.file_digest(path)
    require "digest/sha2"
    digest = Digest::SHA256.new
    chunks = 0
    File.open(path, "rb") do |file|
      while (chunk = file.read(1024 * 1024))
        digest.update(chunk)
        chunks += 1
        pump if chunks % 4 == 0
      end
    end
    digest.hexdigest
  end

  def self.build_inputs(root = ".")
    absolute_root = File.expand_path(root).tr("\\", "/") + "/"
    # mkxp's virtual Dir.glob does not enumerate absolute wildcard paths like
    # desktop Ruby. Follow the production loader's explicit Dir.entries walk.
    scripts = []
    walk = lambda do |directory|
      Dir.entries(directory).reject { |name| name == "." || name == ".." }.each do |name|
        path = File.join(directory, name)
        File.directory?(path) ? walk.call(path) : scripts << path
      end
    end
    walk.call(File.join(root, "Data", "Scripts"))
    data = Dir.entries(File.join(root, "Data")).select do |name|
      path = File.join(root, "Data", name)
      File.file?(path) && name.downcase.end_with?(".dat", ".rxdata") &&
        !name.start_with?("Map", "Copy", "Editor", "Tilesets") &&
        !%w[Animations.rxdata PkmnAnimations.rxdata PluginScripts.rxdata].include?(name) &&
        !name.downcase.include?("backup")
    end.map { |name| File.join(root, "Data", name) }
    mods_directory = File.join(root, "Mods")
    mods = if File.directory?(mods_directory)
             Dir.entries(mods_directory).select { |name| name.end_with?(".rb") && File.file?(File.join(mods_directory, name)) }.map { |name| File.join(mods_directory, name) }
           else
             []
           end
    plugin = File.join(root, "Data", "PluginScripts.rxdata")
    mods << plugin if File.file?(plugin)
    (scripts + data + mods).map do |path|
      File.expand_path(path).tr("\\", "/").sub(/\A#{Regexp.escape(absolute_root)}/, "")
    end.uniq.sort
  end

  def self.ensure_supported_mods(root = ".")
    directory = File.join(root, "Mods")
    blocked = if File.directory?(directory)
                Dir.entries(directory).select do |name|
                  name.downcase.end_with?(".rb") && File.file?(File.join(directory, name))
                end.map { |name| "Mods/#{name}" }
              else
                []
              end
    plugin = File.join(root, "Data", "PluginScripts.rxdata")
    # This is an exact check of a trusted LOCAL empty Ruby archive. Never load
    # or deserialize an arbitrary plugin archive to decide whether it is safe.
    empty_archive = [4, 8, 91, 0].pack("C*")
    if File.file?(plugin) && !(File.size(plugin) == 4 && File.binread(plugin) == empty_archive)
      blocked << "Data/PluginScripts.rxdata"
    end
    unless blocked.empty?
      raise Error.new("Standard multiplayer rules do not support these Mods/plugins: #{blocked.sort.join(', ')}", "unsupported_mods", { "files" => blocked.sort })
    end
    true
  end

  def self.normalized_url(value)
    text = value.to_s.strip.sub(/\/+\z/, "")
    unless text =~ /\Ahttps?:\/\/[A-Za-z0-9.\-]+(?::[0-9]{1,5})?\z/
      raise Error.new("Use http(s)://host:port without a path or credentials.", "invalid_server")
    end
    # HTTP is deliberately limited to explicitly configured development servers.
    text
  end

  # Local credentials are scoped to both a profile and a server. Test profiles
  # must never share the player's main save or a second client's token.
  class Profile
    attr_reader :path, :data
    def initialize(path = nil)
      profile = ENV.fetch("KIF_MULTIPLAYER_PROFILE", "default")
      raise Error, "Invalid multiplayer profile" unless profile =~ /\A[A-Za-z0-9_-]{1,48}\z/
      directory = if defined?(System) && System.respond_to?(:data_directory)
                    System.data_directory
                  else
                    "UserData"
                  end
      @path = path || File.join(directory, "Multiplayer", "#{profile}.json")
      @data = File.file?(@path) ? WireJSON.parse(File.binread(@path)) : {}
      raise Error, "Invalid local multiplayer configuration" unless @data.is_a?(Hash)
      @data["servers"] ||= {}
      raise Error, "Invalid local server identities" unless @data["servers"].is_a?(Hash)
      @data["server"] ||= ENV.fetch("KIF_MULTIPLAYER_SERVER", "http://127.0.0.1:8765")
      if ENV["KIF_MULTIPLAYER_SERVER"] && @data["server"] != ENV["KIF_MULTIPLAYER_SERVER"]
        KIFMultiplayer.assert_identity_change_safe!(self, KIFMultiplayer.normalized_url(ENV["KIF_MULTIPLAYER_SERVER"]))
        @data["server"] = ENV["KIF_MULTIPLAYER_SERVER"]
      end
      @data["server"] = KIFMultiplayer.normalized_url(@data["server"])
    end

    def server; @data["server"]; end
    def server=(url)
      normalized = KIFMultiplayer.normalized_url(url)
      KIFMultiplayer.assert_identity_change_safe!(self, normalized) if normalized != server
      previous = @data["server"]
      @data["server"] = normalized
      save
    rescue Exception
      @data["server"] = previous if defined?(previous) && previous
      raise
    end
    def account
      @data["servers"][server] ||= {}
      raise Error, "Invalid local server identity" unless @data["servers"][server].is_a?(Hash)
      @data["servers"][server]
    end
    def save
      parent = File.dirname(@path)
      parts = []
      current = parent
      until File.directory?(current)
        parts.unshift(current)
        next_parent = File.dirname(current)
        raise Error, "Configuration directory cannot be created" if next_parent == current
        current = next_parent
      end
      parts.each { |part| Dir.mkdir(part) }
      temporary = @path + ".tmp"
      File.open(temporary, "wb") do |file|
        file.write(WireJSON.dump(@data))
        file.flush
        file.fsync rescue nil
      end
      File.rename(temporary, @path)
      true
    end
  end

  # The worker never calls Graphics, Input, scene methods, or game data APIs.
  # 015_Transport installs the bounded core-Socket implementation after all
  # modules load. Do not instantiate/use the legacy adapter before that point.
  class HTTPTransport
    attr_reader :backend
    def initialize
      @backend = :unloaded
    end

    def call(*_arguments)
      raise Error.new("Multiplayer transport module 015_Transport.rb was not loaded", "transport_not_loaded")
    end
  end

  class Client
    attr_reader :profile, :transport
    attr_accessor :wait_update
    def initialize(profile = nil, transport = nil)
      @profile = profile || Profile.new
      @transport = transport || HTTPTransport.new
      @wait_update = nil
    end
    def server; @profile.server; end
    def token; @profile.account["token"]; end
    def identity; @profile.account["identity"]; end
    def player_id; identity && identity["id"]; end
    def room_code; @profile.account["room_code"]; end
    def room_code=(value)
      persist_account { |account| account["room_code"] = value }
    end
    def pump
      KIFMultiplayer.pump
      @wait_update.call if @wait_update
    end
    def disconnect
      @profile.account["connected"] = false
      @profile.save
    end

    def request(method, path, body = nil, timeout = 8.0, recovering = false)
      raise Error, "Invalid request path" unless path.is_a?(String) && path =~ /\A\/v1\/[A-Za-z0-9_\/.?=&-]+\z/
      method = method.to_s.upcase
      raise Error, "Unsupported HTTP method" unless ["GET", "POST"].include?(method)
      # Reject unavailable TLS/malformed addresses before creating a durable
      # mutation journal. No request has been sent at this point.
      @transport.validate_url(server + path) if @transport.respond_to?(:validate_url)
      read_post = method == "POST" && path =~ NON_JOURNALED_POST
      mutation = method == "POST" && !read_post && path !~ /\A\/v1\/identities(?:\/recover)?\z/
      raise Error.new("Request body must be a JSON object", "invalid_json") unless body.nil? || body.is_a?(Hash)
      # Validate before touching pending, and detach nested objects from the UI
      # which continues updating while the network worker sends the request.
      body = body ? WireJSON.parse(WireJSON.dump(body)) : {}
      # Downloads and presence updates must neither overwrite nor replay an
      # economic journal. Heartbeats remain usable while resolve is uncertain.
      body["request_id"] ||= KIFMultiplayer.operation_id if read_post && path !~ /\A\/v1\/(?:auth|cloud|world|chat)\//
      if mutation
        pending = @profile.account["pending"]
        if pending && !recovering
          recover_pending
        end
        body["request_id"] ||= KIFMultiplayer.operation_id
        persist_account do |account|
          account["pending"] = { "path" => path, "body" => body, "method" => method, "identity_id" => player_id }
        end
      end
      begin
        response = raw_request(method, path, body, timeout)
      rescue HTTPRejected
        clear_pending(body["request_id"]) if mutation
        raise
      end
      # Recovery records the response and removes pending in one atomic write.
      clear_pending(body["request_id"]) if mutation && !recovering
      response
    end

    def raw_request(method, path, body = {}, timeout = 8.0)
      @transport.validate_url(server + path) if @transport.respond_to?(:validate_url)
      @inflight_worker.poll if @inflight_worker && @inflight_worker.respond_to?(:poll)
      if @inflight_worker && @inflight_worker.alive?
        raise UncertainRequest.new("The previous network request is still stopping. Recover its operation after it finishes.", "network_busy")
      end
      endpoint, authorization = server + path, token
      result, failure, completed = nil, nil, false
      worker = KIFMultiplayer.network_worker do
        begin
          result = @transport.call(method, endpoint, body, authorization, timeout)
        rescue StandardError => e
          failure = e
        ensure
          completed = true
        end
      end
      @inflight_worker = worker
      KIFMultiplayer.register_worker(worker) if KIFMultiplayer.respond_to?(:register_worker)
      deadline = KIFMultiplayer.monotonic + timeout
      until completed
        worker.poll if worker.respond_to?(:poll)
        break if completed
        pump
        if KIFMultiplayer.monotonic >= deadline
          raise UncertainRequest.new("Network timeout. Query the saved operation before retrying.", "network_timeout")
        end
        Thread.pass
      end
      # A timed-out worker owns and closes its socket within its own deadline.
      # Asynchronous Thread#kill can interrupt native bindings/IO cleanup. Keep
      # the inflight guard until natural completion instead of killing it.
      worker.join
      if failure
        details = {"transport_code" => failure.respond_to?(:code) ? failure.code : failure.class.to_s}
        raise UncertainRequest.new("Server unreachable: #{failure.class}", "unreachable", details)
      end
      unless result.is_a?(Hash)
        raise UncertainRequest.new("Invalid HTTP response", "invalid_response")
      end
      status = result[:status] || result["status"]
      raise UncertainRequest.new("Server unreachable", "unreachable") unless status.to_i > 0
      if status.to_i >= 500 || [408, 425, 429].include?(status.to_i)
        raise UncertainRequest.new("Server response is uncertain. Query the saved operation before retrying.", "server_unavailable", {"http_status" => status.to_i})
      end
      parsed = WireJSON.parse((result[:body] || result["body"]).to_s)
      unless parsed.is_a?(Hash) && [true, false].include?(parsed["ok"])
        raise UncertainRequest.new("Unexpected server response", "invalid_response")
      end
      if status.to_i < 200 || status.to_i >= 300 || parsed["ok"] != true
        error = parsed["error"] || {}
        unless parsed["ok"] == false && error.is_a?(Hash) &&
               (error["message"].nil? || error["message"].is_a?(String)) &&
               (error["code"].nil? || error["code"].is_a?(String))
          raise UncertainRequest.new("Invalid HTTP rejection", "invalid_response")
        end
        rejection = status.to_i.between?(400, 499) ? HTTPRejected : UncertainRequest
        raise rejection.new(error["message"] || "HTTP #{status}", error["code"] || "http_error", error["details"])
      end
      parsed
    ensure
      if worker && !worker.alive? && KIFMultiplayer.respond_to?(:unregister_worker)
        KIFMultiplayer.unregister_worker(worker)
      end
      @inflight_worker = nil if @inflight_worker && !@inflight_worker.alive?
    end

    def persist_account(&block)
      # Retain the previous durable account if an atomic disk update fails.
      KIFMultiplayer.persist_account(@profile, &block)
    end

    def clear_pending(request_id)
      pending = @profile.account["pending"]
      return unless pending && pending["body"]["request_id"] == request_id
      persist_account { |account| account.delete("pending") }
    end

    def remember_recovered(pending, response)
      unless response.is_a?(Hash) && [true, false].include?(response["ok"])
        raise UncertainRequest.new("Invalid saved operation response", "invalid_response")
      end
      persist_account do |account|
        current = account["pending"]
        unless current && current.dig("body", "request_id") == pending.dig("body", "request_id")
          raise Error.new("Recovery journal changed unexpectedly", "operation_conflict")
        end
        account["last_recovered_operation"] = { "path" => pending["path"], "response" => response }
        account.delete("pending")
      end
      response
    end

    def recover_pending
      pending = @profile.account["pending"]
      return nil unless pending
      if pending["method"] == "POST" && pending["path"].to_s =~ NON_JOURNALED_POST
        # A legacy read/presence journal cannot commit an economic operation;
        # do not replay a damaged download or a stale authority heartbeat.
        persist_account { |account| account.delete("pending") }
        return nil
      end
      if pending["identity_id"] && pending["identity_id"] != player_id
        raise Error.new("This saved operation belongs to a different identity. Restore that identity before retrying.", "identity_switch_pending")
      end
      id = pending["body"]["request_id"]
      begin
        result = raw_request("GET", "/v1/operations/#{id}")
        status = result["http_status"]
        unless result["status"] == "completed" && status.is_a?(Integer) &&
               (status.between?(200, 299) || status.between?(400, 499))
          raise UncertainRequest.new("Operation is not confirmed complete", "invalid_response")
        end
        response = result["response"]
        if status.between?(400, 499)
          error = response.is_a?(Hash) && response["error"]
          unless response.is_a?(Hash) && response["ok"] == false && error.is_a?(Hash) &&
                 error["message"].is_a?(String) && error["code"].is_a?(String)
            raise UncertainRequest.new("Invalid saved operation rejection", "invalid_response")
          end
          remember_recovered(pending, response)
          raise HTTPRejected.new(error["message"], error["code"], error["details"])
        end
        unless response.is_a?(Hash) && response["ok"] == true
          raise UncertainRequest.new("Invalid saved operation success", "invalid_response")
        end
        return remember_recovered(pending, response)
      rescue Error => e
        raise unless e.code == "operation_not_found"
      end
      # The authoritative query says it was never committed. A retry reuses the
      # exact operation id and payload, so a racing original remains idempotent.
      response = request(pending["method"], pending["path"], pending["body"], 8.0, true)
      remember_recovered(pending, response)
    end

    def connect(nickname)
      health = request("GET", "/v1/health")
      unless health["protocol"] == PROTOCOL && health["rules_version"] == RULES_VERSION
        raise Error.new("Protocol or rules version is incompatible", "incompatible_version")
      end
      if token
        result = request("GET", "/v1/identity")
      else
        result = request("POST", "/v1/identities", { "nickname" => nickname, "protocol" => PROTOCOL })
        @profile.account["token"] = result["token"]
        @profile.account["recovery_code"] = result["recovery_code"]
      end
      @profile.account["identity"] = result["identity"]
      @profile.account["connected"] = true
      @profile.save
      recover_pending
      result
    end

    def recover_identity(code)
      body = { "recovery_code" => code, "protocol" => PROTOCOL }
      bound_identity = KIFMultiplayer.bound_identity_id(@profile)
      locked = @profile.account["pending"] || @profile.account["gym_session"] ||
        bound_identity || (KIFMultiplayer.respond_to?(:trade_identity_locked?) && KIFMultiplayer.trade_identity_locked?(@profile))
      expected_identity = bound_identity || player_id
      if locked
        raise Error.new("Cannot identify the owner of this pending operation. Restore its original profile/save first.", "identity_switch_pending") unless expected_identity
        body["expected_identity_id"] = expected_identity
      end
      result = request("POST", "/v1/identities/recover", body)
      if locked && result.dig("identity", "id") != expected_identity
        raise Error.new("The recovery identity does not own this pending operation.", "identity_switch_pending")
      end
      @profile.account["token"] = result["token"]
      @profile.account["identity"] = result["identity"]
      @profile.account["recovery_code"] = result["recovery_code"] if result["recovery_code"]
      @profile.save
      result
    end

    def compatibility
      # Packaging writes the digest of the actual battle code and database.
      # A missing manifest blocks play instead of treating all unknown builds as
      # compatible. The game may still connect and use showcases without it.
      KIFMultiplayer.ensure_supported_mods
      path = "Data/multiplayer-build.json"
      raise Error.new("Build multiplayer scripts first (missing Data/multiplayer-build.json).", "missing_build") unless File.file?(path)
      manifest = WireJSON.parse(File.binread(path))
      unless manifest["version"] == 1 && manifest["protocol"] == PROTOCOL && manifest["rules_version"] == RULES_VERSION
        raise Error.new("Build protocol or rules changed. Rebuild before joining.", "stale_build")
      end
      %w[data_hash mods_hash].each do |field|
        raise Error.new("Invalid multiplayer build manifest", "missing_build") unless manifest[field].is_a?(String) && manifest[field].length >= 8
      end
      files = manifest["files"]
      raise Error.new("Build manifest has no verified files", "missing_build") unless files.is_a?(Hash) && !files.empty?
      unless files.keys.sort == KIFMultiplayer.build_inputs
        raise Error.new("Scripts, Mods, or battle data were added or removed. Rebuild before joining.", "stale_build")
      end
      require "digest/sha2"
      files.each_with_index do |(relative, metadata), index|
        unless relative.is_a?(String) && relative =~ /\A(?:Data|Mods)\/[^\\:\x00-\x1f]+\z/ && !relative.split("/").include?("..") && metadata.is_a?(Hash)
          raise Error.new("Invalid build manifest file", "missing_build")
        end
        unless File.file?(relative) && File.size(relative) == metadata["size"] && KIFMultiplayer.file_digest(relative) == metadata["sha256"]
          raise Error.new("Code or battle data changed: #{relative}. Rebuild before joining.", "stale_build")
        end
        pump if index % 8 == 0
      end
      { "protocol" => PROTOCOL, "game_version" => Settings::GAME_VERSION.to_s,
        "data_hash" => manifest["data_hash"], "mods_hash" => manifest["mods_hash"],
        "rules_version" => RULES_VERSION }
    end
  end

  module Snapshot
    STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED]
    APPEARANCE_KEYS = %w[head_shiny body_shiny debug_shiny natural_shiny fakeshiny shinyValue shinyR shinyG shinyB shinyKRS head_shinyhue body_shinyhue head_shinyr head_shinyg head_shinyb body_shinyr body_shinyg body_shinyb head_shinykrs body_shinykrs shinyimprovpif head_shinyimprovpif body_shinyimprovpif spriteform_head spriteform_body sprite_scale size_category head_gender head_nickname kuraygender]
    KEYS = %w[version species level form name gender personal_id nature nature_for_stats ability ability_index ability2 ability2_index item moves iv iv_maxed ev happiness shiny appearance owner hidden_power_type]
    def self.check(condition, message)
      raise Error.new(message, "invalid_pokemon") unless condition
    end
    def self.number(value, low, high)
      value.is_a?(Integer) && value >= low && value <= high
    end
    def self.identifier(value)
      value.is_a?(String) && value =~ /\A[A-Za-z0-9_.:-]{1,80}\z/
    end
    def self.registry(type, value, optional = false)
      return if optional && value.nil?
      check(identifier(value), "Invalid #{type} identifier")
      klass = GameData.const_get(type)
      if type == :Species && klass.const_defined?(:DATA)
        # This game's Species.exists? delegates to get(), which silently returns
        # Pikachu for an unknown id. Network compatibility cannot use that path.
        fusion = /\AB([0-9]+)H([0-9]+)\z/.match(value)
        valid = if fusion
                  maximum = defined?(NB_POKEMON) ? NB_POKEMON : 0
                  fusion.captures.all? { |part| part.to_i.between?(1, maximum) }
                else
                  klass::DATA.key?(value.to_sym)
                end
        check(valid, "Unsupported Species: #{value}")
      else
        check(klass.exists?(value), "Unsupported #{type}: #{value}")
      end
    end
    def self.validate(data)
      check(data.is_a?(Hash) && (data.keys - KEYS).empty?, "Unknown Pokemon snapshot fields")
      check(data["version"] == 1, "Unsupported Pokemon snapshot version")
      registry(:Species, data["species"])
      check(data["form"] == 0, "Special forms are not supported in the first multiplayer ruleset")
      check(number(data["level"], 1, 100), "Invalid level")
      check(data["name"].is_a?(String) && data["name"].length <= 32 && data["name"] !~ /[\x00-\x1f]/, "Invalid nickname")
      check(number(data["gender"], 0, 2) && number(data["personal_id"], 0, 0xffffffff), "Invalid individual identity")
      registry(:Nature, data["nature"])
      registry(:Nature, data["nature_for_stats"], true)
      registry(:Ability, data["ability"])
      registry(:Ability, data["ability2"], true)
      registry(:Item, data["item"], true)
      check(!%w[REDORB BLUEORB ULTRANECROZIUMZ].include?(data["item"]), "Unsupported battle transformation item: #{data['item']}")
      registry(:Type, data["hidden_power_type"], true)
      check(number(data["ability_index"], 0, 5), "Invalid ability index")
      check(data["ability2_index"].nil? || number(data["ability2_index"], 0, 5), "Invalid second ability index")
      check(data["moves"].is_a?(Array) && data["moves"].length.between?(1, 4), "Select one to four supported moves")
      data["moves"].each do |move|
        check(move.is_a?(Hash) && (move.keys - %w[id pp ppup]).empty?, "Invalid move fields")
        registry(:Move, move["id"])
        check(number(move["pp"], 0, 99) && number(move["ppup"], 0, 3), "Invalid move PP")
      end
      [["iv", 31], ["ev", 252]].each do |field, max|
        values = data[field]
        check(values.is_a?(Hash) && values.keys.sort == STATS.sort, "Invalid #{field} fields")
        check(values.values.all? { |v| number(v, 0, max) }, "Invalid #{field} values")
      end
      check(data["ev"].values.inject(0, :+) <= 510, "EV total exceeds 510")
      maxed = data["iv_maxed"]
      check(maxed.is_a?(Hash) && maxed.keys.sort == STATS.sort && maxed.values.all? { |v| v == true || v == false }, "Invalid hyper training flags")
      check(number(data["happiness"], 0, 255) && [true, false].include?(data["shiny"]), "Invalid happiness or shiny flag")
      validate_appearance(data["appearance"])
      owner = data["owner"]
      check(owner.is_a?(Hash) && (owner.keys - %w[id name gender language]).empty?, "Invalid original trainer fields")
      check(number(owner["id"], 0, 0xffffffff) && number(owner["gender"], 0, 2) && number(owner["language"], 0, 10), "Invalid original trainer identity")
      check(owner["name"].is_a?(String) && owner["name"].length <= 32 && owner["name"] !~ /[\x00-\x1f]/, "Invalid original trainer name")
      data
    end

    def self.validate_appearance(appearance)
      check(appearance.is_a?(Hash) && (appearance.keys - APPEARANCE_KEYS).empty?, "Unknown appearance fields")
      appearance.each do |key, value|
        next if value.nil?
        valid = case key
                when "head_shiny", "body_shiny", "debug_shiny", "natural_shiny", "fakeshiny"
                  value == true || value == false
                when "shinyValue", "head_shinyhue", "body_shinyhue"
                  number(value, -360, 360)
                when "shinyR", "shinyG", "shinyB", "head_shinyr", "head_shinyg", "head_shinyb", "body_shinyr", "body_shinyg", "body_shinyb"
                  number(value, 0, 25)
                when "shinyKRS", "head_shinykrs", "body_shinykrs"
                  value.is_a?(Array) && value.length == 9 && value.each_with_index.all? do |part, i|
                    number(part, i < 3 ? -200 : 0, i < 3 ? 200 : (i < 6 ? 4 : 2))
                  end
                when "shinyimprovpif", "head_shinyimprovpif", "body_shinyimprovpif"
                  number(value, 0, 3)
                when "kuraygender" then number(value, 0, 65_535)
                when "head_gender" then number(value, 0, 2)
                when "sprite_scale" then value.is_a?(Numeric) && value.finite? && value >= 0.25 && value <= 3
                when "size_category" then %w[SMALL AVERAGE LARGE SUPER].include?(value)
                when "spriteform_head", "spriteform_body"
                  number(value, 0, 999) || (value.is_a?(String) && value =~ /\A[A-Za-z0-9_-]{1,12}\z/)
                when "head_nickname"
                  value.is_a?(String) && value.length <= 32 && value !~ /[\/\\\x00-\x1f]/
                else false
                end
        check(valid, "Invalid appearance type or range: #{key}")
      end
      appearance
    end

    def self.stat_values(values, default)
      STATS.each_with_object({}) { |name, result| result[name] = values.fetch(name.to_sym, default) }
    end

    def self.export_for_battle(original)
      # Freeze a standard-rule team before constructing the engine. The normal
      # getters also consult NO_LEVELS, level caps and local ability switches;
      # normalizing only after export is too late to undo those chosen values.
      previous = [$PokemonSystem, $game_switches, $game_variables]
      begin
        standard = PokemonSystem.new
        standard.download_sprites = 1 if standard.respond_to?(:download_sprites=)
        standard.shinyadvanced = 2 if standard.respond_to?(:shinyadvanced=)
        $PokemonSystem = standard
        $game_switches, $game_variables = previous[1].class.new, previous[2].class.new
        export(original)
      ensure
        $PokemonSystem, $game_switches, $game_variables = previous
      end
    end

    def self.export(original)
      pokemon = original.clone
      check(!pokemon.egg? && !pokemon.isShadow?, "Eggs and shadow Pokemon are not supported")
      check(pokemon.form == 0 && !pokemon.fused, "Special forms and stored fusion partners are not supported")
      override = pokemon.respond_to?(:typeoverwrite) ? pokemon.typeoverwrite : nil
      check(override.nil? || override == false || override == 0, "Custom type overrides are not supported")
      pokemon.nature # resolve lazy nature only on the clone
      shiny = !!pokemon.shiny?
      appearance = {}
      APPEARANCE_KEYS.each do |field|
        value = pokemon.instance_variable_get("@#{field}")
        value = value.to_s if value.is_a?(Symbol)
        appearance[field] = value.is_a?(Array) ? value.dup : value
      end
      owner = pokemon.owner
      data = { "version" => 1, "species" => pokemon.species.to_s,
        "level" => pokemon.level, "form" => pokemon.form,
        "name" => pokemon.name.to_s, "gender" => pokemon.gender,
        "personal_id" => pokemon.personalID, "nature" => pokemon.nature_id.to_s,
        "nature_for_stats" => pokemon.nature_for_stats_id && pokemon.nature_for_stats_id.to_s,
        "ability" => pokemon.ability_id.to_s, "ability_index" => pokemon.ability_index,
        "ability2" => (pokemon.respond_to?(:ability2_id) && pokemon.ability2_id) ? pokemon.ability2_id.to_s : nil,
        "ability2_index" => pokemon.respond_to?(:ability2_index) ? pokemon.ability2_index : nil,
        "item" => pokemon.item_id && pokemon.item_id.to_s,
        "moves" => pokemon.moves.map { |move| { "id" => move.id.to_s, "pp" => move.pp, "ppup" => move.ppup } },
        "iv" => stat_values(pokemon.iv, 0), "iv_maxed" => stat_values(pokemon.ivMaxed || {}, false).transform_values { |value| !!value },
        "ev" => stat_values(pokemon.ev, 0), "happiness" => pokemon.happiness,
        "shiny" => shiny, "appearance" => appearance,
        "hidden_power_type" => pokemon.hiddenPowerType && pokemon.hiddenPowerType.to_s,
        "owner" => { "id" => owner.id, "name" => owner.name, "gender" => owner.gender, "language" => owner.language } }
      validate(data)
    end

    def self.import(data, level = 50)
      validate(data)
      owner = data["owner"]
      owner_copy = Pokemon::Owner.new(owner["id"], owner["name"].dup, owner["gender"], owner["language"])
      pokemon = Pokemon.new(data["species"], level, owner_copy, false, false)
      pokemon.personalID = data["personal_id"]
      pokemon.name = data["name"].dup
      pokemon.gender = data["gender"]
      pokemon.nature = data["nature"]
      pokemon.nature_for_stats = data["nature_for_stats"]
      pokemon.ability_index = data["ability_index"]
      pokemon.ability = data["ability"]
      # Use explicit trusted fields; do not dispatch arbitrary network keys.
      pokemon.instance_variable_set(:@ability2, data["ability2"] && GameData::Ability.get(data["ability2"]).id)
      pokemon.instance_variable_set(:@ability2_index, data["ability2_index"])
      pokemon.item = data["item"]
      pokemon.moves = data["moves"].map do |value|
        move = Pokemon::Move.new(value["id"])
        move.ppup = value["ppup"]
        move.pp = move.total_pp
        move
      end
      STATS.each do |stat|
        pokemon.iv[stat.to_sym] = data["iv"][stat]
        pokemon.ev[stat.to_sym] = data["ev"][stat]
        pokemon.ivMaxed[stat.to_sym] = data["iv_maxed"][stat]
      end
      pokemon.happiness = data["happiness"]
      pokemon.shiny = data["shiny"]
      pokemon.hiddenPowerType = data["hidden_power_type"] && GameData::Type.get(data["hidden_power_type"]).id
      APPEARANCE_KEYS.each do |field|
        next unless data["appearance"].key?(field)
        value = data["appearance"][field]
        value = value.dup if value.is_a?(Array) || value.is_a?(String)
        if field == "size_category" && value
          check(%w[SMALL AVERAGE LARGE SUPER].include?(value), "Unsupported size category")
          value = value.to_sym
        end
        pokemon.instance_variable_set("@#{field}", value)
      end
      pokemon.calc_stats
      pokemon.heal
      pokemon
    end

    def self.public_snapshot(data, fields = [])
      validate(data)
      allowed = %w[version species level form gender shiny appearance ability ability2 moves] + (fields & %w[name owner iv ev])
      result = data.each_with_object({}) { |(key, value), output| output[key] = value if allowed.include?(key) }
      result["appearance"] = result["appearance"].dup
      result["appearance"].delete("head_nickname") unless fields.include?("name")
      result
    end
  end
end
