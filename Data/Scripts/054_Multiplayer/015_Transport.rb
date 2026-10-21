# mkxp's bundled HTTPLite creates Ruby objects without holding the GVL. It must
# never run concurrently with a multiplayer Ruby worker. Core Socket/IO keeps
# response parsing on Ruby's normal, GVL-protected execution path.
module KIFMultiplayer
  class << self
    def network_workers
      @network_workers ||= []
      @network_workers.select! { |worker| worker.alive? }
      @network_workers.dup
    end

    def register_worker(worker)
      @network_workers ||= []
      @network_workers << worker if worker && worker.alive? && !@network_workers.include?(worker)
      worker
    end

    def unregister_worker(worker)
      # A worker remains guarded through its final Ruby ensure/return path.
      # network_workers prunes it after natural termination. Direct main-thread
      # adapter calls may release their own guard once the call is complete.
      (@network_workers ||= []).delete(worker) if worker == Thread.main || !worker.alive?
      worker
    end

    def deferred_native_http
      {:status => 0, :body => "", :headers => {},
       :error => "Native HTTP deferred while multiplayer networking is active"}
    end
  end

  class SocketHTTP
    MAX_HEADER_BYTES = 16 * 1024
    MAX_HEADER_LINE = 4096
    MAX_HEADERS = 100
    MAX_TRAILER_BYTES = 8 * 1024
    MAX_CHUNKS = 32768
    MAX_WIRE_BYTES = MAX_RESPONSE_BYTES * 4 + MAX_HEADER_BYTES + MAX_TRAILER_BYTES
    TOKEN = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/

    def self.parse_url(url)
      unless url.is_a?(String) && url.bytesize <= 4096 && url.ascii_only?
        raise Error.new("Invalid HTTP endpoint", "invalid_server")
      end
      match = /\A(https?):\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(\/[^\x00-\x20\x7f#\\]*)?\z/.match(url)
      raise Error.new("Use an HTTP endpoint without credentials or a fragment", "invalid_server") unless match
      host = match[2]
      ipv6 = host.start_with?("[")
      host = host[1...-1] if ipv6
      unless host.bytesize <= 253 && (ipv6 || host.split(".", -1).all? { |part| part =~ /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/ })
        raise Error.new("Invalid HTTP host", "invalid_server")
      end
      port = (match[3] || (match[1] == "https" ? "443" : "80")).to_i
      raise Error.new("Invalid HTTP port", "invalid_server") unless port.between?(1, 65535)
      authority = ipv6 ? "[#{host}]" : host
      authority += ":#{port}" if match[3]
      {:scheme => match[1], :host => host, :port => port, :path => match[4] || "/", :authority => authority}
    end

    def self.ssl_available?
      return true if defined?(OpenSSL::SSL::SSLSocket)
      return @ssl_available unless @ssl_available.nil?
      begin
        require "openssl"
        @ssl_available = true
      rescue LoadError
        @ssl_available = false
      end
    end

    def initialize
      require "socket"
    rescue LoadError
      raise Error.new("This runtime has no safe Socket HTTP adapter", "network_unavailable")
    end

    def validate_url(url)
      endpoint = self.class.parse_url(url)
      if endpoint[:scheme] == "https" && !self.class.ssl_available?
        raise Error.new("This runtime has no verified HTTPS adapter. Use the configured local HTTP service or install a verified adapter.", "unsupported_https")
      end
      endpoint
    end

    def protocol_error(message)
      raise Error.new(message, "invalid_http_response")
    end

    def remaining(deadline)
      duration = deadline - KIFMultiplayer.monotonic
      raise Error.new("HTTP deadline exceeded", "network_timeout") unless duration > 0
      duration
    end

    def wait(io, direction, deadline, connect_error = false)
      if Thread.current[:kif_cooperative_network]
        loop do
          remaining(deadline)
          ready = IO.select(direction == :read ? [io] : nil,
                            direction == :write ? [io] : nil,
                            connect_error ? [io] : nil, 0)
          return ready if ready
          Fiber.yield
        end
      end
      ready = IO.select(direction == :read ? [io] : nil,
                        direction == :write ? [io] : nil,
                        connect_error ? [io] : nil, remaining(deadline))
      raise Error.new("HTTP deadline exceeded", "network_timeout") unless ready
    end

    def connect(endpoint, deadline)
      # Resolution is performed in the worker. The same deadline is checked
      # immediately after the OS resolver returns; Client also bounds its wait
      # and retains a still-running resolver instead of killing native code.
      addresses = Socket.getaddrinfo(endpoint[:host], endpoint[:port], Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      addresses = addresses.uniq { |entry| [entry[3], entry[4], entry[5], entry[6]] }.first(16)
      remaining(deadline)
      failure = nil
      addresses.each_with_index do |address, index|
        socket = nil
        begin
          remaining(deadline)
          # Reserve time for another resolved address when IPv6/one route is
          # unreachable. This never extends the one operation deadline.
          slots = addresses.length - index
          budget = slots == 1 ? remaining(deadline) : [remaining(deadline) / slots, 1.0].min
          attempt_deadline = [deadline, KIFMultiplayer.monotonic + budget].min
          socket = Socket.new(address[4], address[5], address[6])
          socket.binmode
          socket.close_on_exec = true if socket.respond_to?(:close_on_exec=)
          sockaddr = Socket.sockaddr_in(endpoint[:port], address[3])
          begin
            if socket.respond_to?(:connect_nonblock)
              socket.connect_nonblock(sockaddr)
            else
              # mkxp embeds socket.so without the socket.rb convenience method.
              socket.__send__(:__connect_nonblock, sockaddr, true)
            end
          rescue IO::WaitWritable
            wait(socket, :write, attempt_deadline, true)
            number = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
            raise SystemCallError.new("HTTP connect", number) unless number == 0
          end
          return socket
        rescue SystemCallError, IOError => error
          failure = error
          socket.close if socket && !socket.closed?
        rescue Error => error
          socket.close if socket && !socket.closed?
          raise unless error.code == "network_timeout"
          remaining(deadline)
          failure = error
        rescue Exception
          socket.close if socket && !socket.closed?
          raise
        end
      end
      raise(failure || Error.new("HTTP host has no usable address", "unreachable"))
    end

    def tls_context
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(:verify_mode => OpenSSL::SSL::VERIFY_PEER)
      if defined?(KIF::Platform) && KIF::Platform.android?
        # Android's system trust roots are not necessarily at OpenSSL's build
        # time default paths. Load only the OS-owned certificate directories.
        @android_cert_store ||= begin
          store = OpenSSL::X509::Store.new
          store.set_default_paths
          %w[/apex/com.android.conscrypt/cacerts /system/etc/security/cacerts].each do |directory|
            next unless File.directory?(directory)
            Dir.entries(directory).sort.each do |name|
              next unless name =~ /\A[0-9a-f]{8}\.[0-9]+\z/
              begin
                store.add_file(File.join(directory, name))
              rescue OpenSSL::X509::StoreError
                next
              end
            end
          end
          store
        end
        context.cert_store = @android_cert_store
      end
      context
    end

    def secure(socket, endpoint, deadline)
      context = tls_context
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.verify_hostname = true if context.respond_to?(:verify_hostname=)
      stream = OpenSSL::SSL::SSLSocket.new(socket, context)
      stream.sync_close = true
      stream.hostname = endpoint[:host] if stream.respond_to?(:hostname=)
      loop do
        remaining(deadline)
        begin
          stream.connect_nonblock
          break
        rescue IO::WaitReadable
          wait(stream, :read, deadline)
        rescue IO::WaitWritable
          wait(stream, :write, deadline)
        end
      end
      stream.post_connection_check(endpoint[:host])
      stream
    rescue Exception
      stream.close if defined?(stream) && stream && !stream.closed?
      raise
    end

    def write_all(stream, bytes, deadline)
      offset = 0
      while offset < bytes.bytesize
        remaining(deadline)
        begin
          written = stream.write_nonblock(bytes.byteslice(offset, bytes.bytesize - offset))
          raise IOError, "HTTP socket made no write progress" unless written && written > 0
          offset += written
        rescue IO::WaitReadable
          wait(stream, :read, deadline)
        rescue IO::WaitWritable
          wait(stream, :write, deadline)
        end
      end
    end

    class Reader
      attr_reader :buffer
      def initialize(owner, stream, deadline)
        @owner, @stream, @deadline = owner, stream, deadline
        @buffer, @wire_bytes, @eof = "".b, 0, false
      end

      def fill
        return false if @eof
        loop do
          @owner.remaining(@deadline)
          begin
            chunk = @stream.read_nonblock(16384)
            raise IOError, "HTTP socket made no read progress" if chunk.empty?
            @wire_bytes += chunk.bytesize
            @owner.protocol_error("HTTP wire response is too large") if @wire_bytes > MAX_WIRE_BYTES
            @buffer << chunk.b
            return true
          rescue IO::WaitReadable
            @owner.wait(@stream, :read, @deadline)
          rescue IO::WaitWritable
            @owner.wait(@stream, :write, @deadline)
          rescue EOFError
            @eof = true
            return false
          end
        end
      end

      def line(limit)
        loop do
          offset = @buffer.index("\r\n")
          if offset
            @owner.protocol_error("HTTP line is too long") if offset + 2 > limit
            value = @buffer.byteslice(0, offset)
            @buffer = @buffer.byteslice(offset + 2, @buffer.bytesize) || "".b
            return value
          end
          @owner.protocol_error("HTTP line is too long") if @buffer.bytesize >= limit
          @owner.protocol_error("Truncated HTTP headers") unless fill
        end
      end

      def exact(length)
        @owner.protocol_error("HTTP body is too large") if length > MAX_RESPONSE_BYTES
        while @buffer.bytesize < length
          @owner.protocol_error("Truncated HTTP body") unless fill
        end
        value = @buffer.byteslice(0, length)
        @buffer = @buffer.byteslice(length, @buffer.bytesize) || "".b
        value
      end

      def until_eof
        result = "".b
        loop do
          result << @buffer
          @buffer = "".b
          @owner.protocol_error("HTTP body is too large") if result.bytesize > MAX_RESPONSE_BYTES
          break unless fill
        end
        result
      end
    end

    def header(line)
      key, value = line.split(":", 2)
      protocol_error("Malformed HTTP header") unless key && key =~ TOKEN && value && value !~ /[^\x09\x20-\x7e]/
      [key.downcase, value.strip]
    end

    def read_response(stream, deadline, binary = false)
      reader = Reader.new(self, stream, deadline)
      first = reader.line(MAX_HEADER_LINE)
      match = /\AHTTP\/1\.[01] ([2-5][0-9]{2})(?: [\x20-\x7e]*)?\z/.match(first)
      protocol_error("Invalid or unsupported HTTP status") unless match
      status = match[1].to_i
      raise Error.new("HTTP redirects are forbidden", "redirect_forbidden") if status.between?(300, 399)
      values, size, count = {}, first.bytesize + 2, 0
      loop do
        line = reader.line(MAX_HEADER_LINE)
        size += line.bytesize + 2
        protocol_error("HTTP headers are too large") if size > MAX_HEADER_BYTES
        break if line.empty?
        count += 1
        protocol_error("Too many HTTP headers") if count > MAX_HEADERS
        key, value = header(line)
        (values[key] ||= []) << value
      end
      %w[content-length transfer-encoding content-type content-encoding].each do |key|
        protocol_error("Duplicate HTTP framing header") if values[key] && values[key].length != 1
      end
      length = values.dig("content-length", 0)
      transfer = values.dig("transfer-encoding", 0)
      protocol_error("Conflicting HTTP body framing") if length && transfer
      protocol_error("Unsupported HTTP content encoding") if values["content-encoding"] && values["content-encoding"][0].downcase != "identity"
      media = values.dig("content-type", 0).to_s
      unless binary || media =~ /\Aapplication\/(?:json|[A-Za-z0-9!#$&^_.+-]+\+json)(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?\z/i
        protocol_error("HTTP response must contain UTF-8 JSON")
      end
      if !binary && [204, 205].include?(status)
        protocol_error("JSON response cannot use a bodyless HTTP status")
      end
      if transfer
        protocol_error("Unsupported HTTP transfer encoding") unless transfer.downcase == "chunked"
        body, chunks = "".b, 0
        loop do
          chunk_line = reader.line(1024)
          hex, extension = chunk_line.split(";", 2)
          protocol_error("Invalid HTTP chunk size") unless hex =~ /\A[0-9a-fA-F]{1,8}\z/ && (!extension || extension !~ /[^\x20-\x7e]/)
          chunk_size = hex.to_i(16)
          break if chunk_size == 0
          chunks += 1
          protocol_error("Too many HTTP chunks") if chunks > MAX_CHUNKS
          protocol_error("HTTP body is too large") if body.bytesize + chunk_size > MAX_RESPONSE_BYTES
          body << reader.exact(chunk_size)
          protocol_error("Invalid HTTP chunk terminator") unless reader.exact(2) == "\r\n"
        end
        trailer_size, trailer_count = 0, 0
        loop do
          line = reader.line(MAX_HEADER_LINE)
          trailer_size += line.bytesize + 2
          protocol_error("HTTP trailers are too large") if trailer_size > MAX_TRAILER_BYTES
          break if line.empty?
          trailer_count += 1
          protocol_error("Too many HTTP trailers") if trailer_count > 32
          key, = header(line)
          protocol_error("Forbidden HTTP trailer") if %w[content-length transfer-encoding content-type content-encoding host trailer].include?(key)
        end
      elsif length
        protocol_error("Invalid HTTP Content-Length") unless length =~ /\A[0-9]{1,10}\z/
        body = reader.exact(length.to_i)
      else
        body = reader.until_eof
      end
      protocol_error("Unexpected bytes after HTTP response") unless reader.buffer.empty?
      body.force_encoding(binary ? Encoding::ASCII_8BIT : Encoding::UTF_8)
      protocol_error("Invalid UTF-8 HTTP body") unless binary || body.valid_encoding?
      {:status => status, :body => body, :headers => values.transform_values { |items| items.join(", ") }}
    end

    def call(method, url, body, token, timeout, raw_payload: nil, content_type: "application/json", headers: {}, binary: false)
      endpoint = validate_url(url)
      raise Error.new("Unsupported HTTP method", "invalid_request") unless %w[GET POST].include?(method)
      unless timeout.is_a?(Numeric) && timeout.to_f.finite? && timeout > 0 && timeout <= 120
        raise Error.new("Invalid HTTP timeout", "invalid_request")
      end
      unless token.nil? || (token.is_a?(String) && token =~ /\A[\x21-\x7e]{1,512}\z/)
        raise Error.new("Invalid HTTP authorization", "invalid_request")
      end
      registration_added = !KIFMultiplayer.network_workers.include?(Thread.current)
      KIFMultiplayer.register_worker(Thread.current) if registration_added
      deadline = KIFMultiplayer.monotonic + timeout.to_f
      socket = connect(endpoint, deadline)
      stream = endpoint[:scheme] == "https" ? secure(socket, endpoint, deadline) : socket
      payload = method == "GET" ? "" : (raw_payload || WireJSON.dump(body))
      raise Error.new("HTTP payload is too large", "invalid_request") unless payload.is_a?(String) && payload.bytesize <= MAX_RESPONSE_BYTES
      request = ["#{method} #{endpoint[:path]} HTTP/1.1", "Host: #{endpoint[:authority]}", "Connection: close", "Accept: application/json", "Accept-Encoding: identity", "Content-Type: #{content_type}", "Content-Length: #{payload.bytesize}"]
      raise Error.new("Invalid HTTP media type", "invalid_request") unless content_type.is_a?(String) && content_type =~ /\A[\x20-\x7e]{1,200}\z/
      raise Error.new("Invalid HTTP headers", "invalid_request") unless headers.is_a?(Hash) && headers.length <= 32
      headers.each do |key, value|
        unless key.is_a?(String) && key =~ TOKEN && value.is_a?(String) && value.bytesize <= 4096 && value =~ /\A[\x20-\x7e]*\z/ && !%w[host connection content-length transfer-encoding accept-encoding].include?(key.downcase)
          raise Error.new("Invalid HTTP header", "invalid_request")
        end
        request.reject! { |line| line.split(":", 2)[0].casecmp?(key) }
        request << "#{key}: #{value}"
      end
      request << "Authorization: Bearer #{token}" if token
      write_all(stream, (request.join("\r\n") + "\r\n\r\n" + payload).b, deadline)
      read_response(stream, deadline, binary)
    ensure
      stream.close if defined?(stream) && stream && !stream.closed?
      socket.close if defined?(socket) && socket && !socket.closed?
      KIFMultiplayer.unregister_worker(Thread.current) if defined?(registration_added) && registration_added
    end
  end

  class HTTPTransport
    def initialize
      if defined?(KIF::Platform) && KIF::Platform.respond_to?(:android?) && KIF::Platform.android?
        @backend, @socket_http = :platform, nil
      else
        @backend, @socket_http = :core_socket, SocketHTTP.new
      end
    end

    # Online mode explicitly opts into the same verified Ruby Socket path as
    # desktop when Android has no installed platform adapter. Missing Socket
    # or verified TLS remains a visible capability error, never native HTTP.
    def enable_online_network
      if defined?(KIF::Platform) && KIF::Platform.android? && KIFMultiplayer.respond_to?(:install_android_network)
        unless KIFMultiplayer.install_android_network
          raise Error.new("Android runtime requires the verified Socket network module for online play", "network_unavailable")
        end
      end
      if @backend == :platform && !KIF::Platform.network_available?
        @socket_http = SocketHTTP.new
        @backend = :core_socket
      end
      self
    end

    def validate_url(url)
      return @socket_http.validate_url(url) if @socket_http
      endpoint = SocketHTTP.parse_url(url)
      unless KIF::Platform.network_available?
        raise Error.new("Android network adapter is unavailable", "network_unavailable")
      end
      KIF::Platform.validate_http_url(url) if KIF::Platform.respond_to?(:validate_http_url)
      endpoint
    end

    def call(method, url, body, token, timeout)
      return @socket_http.call(method, url, body, token, timeout) if @socket_http
      validate_url(url)
      if KIF::Platform.respond_to?(:http_request)
        response = KIF::Platform.http_request(method, url, body, token, timeout)
        return response if response
      end
      headers = {"Accept" => "application/json", "Content-Type" => "application/json"}
      raise Error.new("Invalid HTTP authorization", "invalid_request") if token && (!token.is_a?(String) || token =~ /[^\x21-\x7e]/ || token.bytesize > 512)
      headers["Authorization"] = "Bearer #{token}" if token
      return KIF::Platform.http_get(url, headers) if method == "GET"
      raise Error.new("Unsupported HTTP method", "invalid_request") unless method == "POST"
      KIF::Platform.http_post_body(url, WireJSON.dump(body), "application/json", headers)
    end
  end

  module NativeHTTPWorkerGuard
    def http_get(*args)
      return KIFMultiplayer.deferred_native_http if !android? && !KIFMultiplayer.network_workers.empty?
      super
    end

    def http_post_body(*args)
      return KIFMultiplayer.deferred_native_http if !android? && !KIFMultiplayer.network_workers.empty?
      super
    end
  end
end

if defined?(KIF::Platform) && !KIF::Platform.singleton_class.ancestors.include?(KIFMultiplayer::NativeHTTPWorkerGuard)
  KIF::Platform.singleton_class.prepend(KIFMultiplayer::NativeHTTPWorkerGuard)
end
