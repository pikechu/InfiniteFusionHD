# Test-only feasibility transport for the socket extension embedded in mkxp.
# Production transport policy/HTTPS support remains owned by 001_Client.rb.
require "socket"
class NativeSocketDiagnosticTransport
  MAX_BYTES = 2 * 1024 * 1024
  def call(method, url, body, token, timeout)
    match = /\Ahttp:\/\/([A-Za-z0-9.-]+)(?::([0-9]+))?(\/[^\r\n]*)\z/.match(url)
    raise "Diagnostic supports explicit HTTP only" unless match
    host, port, path = match[1], (match[2] || "80").to_i, match[3]
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    wait = lambda do |socket, writing|
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "Diagnostic socket deadline" if remaining <= 0
      ready = IO.select(writing ? nil : [socket], writing ? [socket] : nil, nil, remaining)
      raise "Diagnostic socket deadline" unless ready
    end
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    begin
      address = Socket.sockaddr_in(port, host)
      if socket.respond_to?(:connect_nonblock)
        socket.connect_nonblock(address)
      else
        socket.__send__(:__connect_nonblock, address, true)
      end
    rescue IO::WaitWritable
      wait.call(socket, true)
      error = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
      raise SystemCallError.new("Diagnostic connect", error) unless error == 0
    end
    request_body = method == "GET" ? "" : KIFMultiplayer::WireJSON.dump(body)
    lines = ["#{method} #{path} HTTP/1.1", "Host: #{host}:#{port}", "Connection: close", "Accept: application/json", "Content-Type: application/json", "Content-Length: #{request_body.bytesize}"]
    lines << "Authorization: Bearer #{token}" if token
    request = (lines.join("\r\n") + "\r\n\r\n" + request_body).b
    offset = 0
    while offset < request.bytesize
      begin
        offset += socket.write_nonblock(request.byteslice(offset, request.bytesize - offset))
      rescue IO::WaitWritable
        wait.call(socket, true)
      end
    end
    response, header_end, length, status = "".b, nil, nil, nil
    loop do
      begin
        response << socket.read_nonblock(16384)
      rescue IO::WaitReadable
        wait.call(socket, false)
        next
      rescue EOFError
        break
      end
      unless header_end
        header_end = response.index("\r\n\r\n")
        raise "Diagnostic oversized headers" if !header_end && response.bytesize > 16384
        if header_end
          headers = response.byteslice(0, header_end).split("\r\n")
          status = headers.shift[/\AHTTP\/1\.[01] ([0-9]{3}) /, 1]
          raise "Diagnostic invalid status" unless status
          values = headers.map { |line| line.split(":", 2) }
          lengths = values.select { |key, _| key.downcase == "content-length" }.map { |_, value| value.to_s.strip }
          raise "Diagnostic requires one bounded Content-Length" unless lengths.length == 1 && lengths[0] =~ /\A[0-9]+\z/
          length = lengths[0].to_i
          raise "Diagnostic oversized body" if length > MAX_BYTES
          raise "Diagnostic transfer encoding unsupported" if values.any? { |key, _| key.downcase == "transfer-encoding" }
          header_end += 4
        end
      end
      raise "Diagnostic oversized response" if response.bytesize > MAX_BYTES + 16384
      break if header_end && response.bytesize - header_end >= length
    end
    raise "Diagnostic truncated response" unless header_end && response.bytesize - header_end == length
    {:status => status.to_i, :body => response.byteslice(header_end, length).force_encoding(Encoding::UTF_8)}
  rescue StandardError => error
    STDERR.puts("DIAGNOSTIC_SOCKET_FAILURE #{error.class}: #{error.message}\n#{(error.backtrace || []).first(3).join("\n")}")
    STDERR.flush
    raise
  ensure
    socket.close if defined?(socket) && socket && !socket.closed?
  end
end
