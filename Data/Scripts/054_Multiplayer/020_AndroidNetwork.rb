# Android uses cooperative numeric-IP Socket IO for local development and the
# verified Android Java TLS bridge for HTTPS. Native HTTPLite is never used.
module KIFMultiplayer
  class AndroidNetworkAdapter
    def initialize
      @http = SocketHTTP.new
    end
    def validate_url(url)
      endpoint = SocketHTTP.parse_url(url)
      if endpoint[:scheme] == "https"
        unless defined?(KIFAndroidBridge) && KIFAndroidBridge.respond_to?(:request)
          raise Error.new("Android verified HTTPS bridge is missing. Update the Android network build.", "network_unavailable")
        end
      else
        host = endpoint[:host]
        numeric = host =~ /\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z/ && host.split(".").all? { |part| part.to_i <= 255 }
        numeric ||= host.include?(":") && host =~ /\A[0-9a-fA-F:]+\z/
        raise Error.new("Android development HTTP requires a numeric server IP. Use HTTPS for a hostname.", "invalid_server") unless numeric
      end
      endpoint
    end
    def request(method, url, body, token, timeout)
      endpoint = validate_url(url)
      return @http.call(method, url, body, token, timeout) if endpoint[:scheme] == "http"
      headers = {"Accept" => "application/json"}
      if token
        raise Error.new("Invalid HTTP token", "invalid_request") unless token.is_a?(String) && token =~ /\A[\x21-\x7e]{1,512}\z/
        headers["Authorization"] = "Bearer #{token}"
      end
      raw = method == "POST" ? WireJSON.dump(body) : nil
      deadline = KIFMultiplayer.monotonic + timeout
      if raw && raw.bytesize > 32768 && endpoint[:path] == "/v1/cloud/upload"
        return upload_chunks(url, body, raw, headers, deadline)
      end
      response = bridge(method, url, raw, "application/json", headers, false)
      raise Error.new("Android HTTP deadline exceeded", "network_timeout") if KIFMultiplayer.monotonic > deadline
      response
    end
    def get(url, headers = {}, follow_redirects = true)
      return bridge("GET", url, nil, nil, headers || {}, follow_redirects) if validate_url(url)[:scheme] == "https"
      @http.call("GET", url, {}, nil, 10.0, headers: headers || {}, binary: true)
    end
    def post_body(url, body, content_type = "application/json", headers = {})
      return bridge("POST", url, body, content_type, headers || {}, false) if validate_url(url)[:scheme] == "https"
      @http.call("POST", url, {}, nil, 10.0, raw_payload: body, content_type: content_type, headers: headers || {}, binary: true)
    end
    def bridge(method, url, body, media, headers, follow)
      validate_url(url)
      raise Error.new("Invalid HTTP headers", "invalid_request") unless headers.is_a?(Hash) && headers.length <= 64
      headers.each do |name, value|
        unless name.is_a?(String) && name =~ SocketHTTP::TOKEN && value.is_a?(String) && value.bytesize <= 8192 && value !~ /[\x00-\x1f\x7f]/ && !%w[host content-length connection transfer-encoding].include?(name.downcase)
          raise Error.new("Invalid HTTP header", "invalid_request")
        end
      end
      envelope = {"method" => method, "url" => url, "headers" => headers, "follow_redirects" => !!follow}
      if body
        raise Error.new("Android HTTPS request requires cloud chunking", "request_too_large") unless body.is_a?(String) && body.bytesize <= 32768
        envelope["body"], envelope["content_type"] = [body].pack("m0"), media
      end
      encoded = WireJSON.dump(envelope)
      raise Error.new("Android HTTPS envelope is too large", "request_too_large") if encoded.bytesize > 65536
      raw = KIFAndroidBridge.request(encoded)
      decoded = WireJSON.parse(raw, 12 * 1024 * 1024)
      unless decoded.is_a?(Hash) && decoded["status"].is_a?(Integer) && (decoded["status"] == 0 || decoded["status"].between?(100, 599)) && decoded["body"].is_a?(String) && decoded["body"].bytesize <= 12 * 1024 * 1024 && decoded["headers"].is_a?(Hash)
        raise Error.new("Invalid Android HTTPS response", "invalid_http_response")
      end
      bytes = decoded["body"].unpack1("m0")
      raise Error.new("Invalid Android HTTPS body", "invalid_http_response") unless bytes.bytesize <= 8 * 1024 * 1024 && [bytes].pack("m0") == decoded["body"]
      Fiber.yield if Thread.current[:kif_cooperative_network]
      {:status => decoded["status"], :body => bytes, :headers => decoded["headers"], :error => decoded["error"]}
    end
    def upload_chunks(url, original, raw, headers, deadline)
      require "digest/sha2"
      # A recovered game has a new lease/session but must replay the exact
      # durable upload ID and contents. Keep the lease out of the chunk hash.
      raw = WireJSON.dump(original.reject { |key, _value| key == "session_id" })
      checksum = Digest::SHA256.hexdigest(raw)
      total, index = (raw.bytesize + 16383) / 16384, 0
      while index < total
        raise Error.new("Android cloud upload deadline exceeded; retry resumes saved chunks", "network_timeout") if KIFMultiplayer.monotonic > deadline
        chunk = {"session_id" => original["session_id"], "upload_id" => original["upload_id"], "index" => index, "total" => total,
          "sha256" => checksum, "data" => [raw.byteslice(index * 16384, 16384)].pack("m0")}
        response = bridge("POST", url.sub(/\/upload\z/, "/chunk"), WireJSON.dump(chunk), "application/json", headers, false)
        return response unless response[:status].between?(200, 299)
        result = WireJSON.parse(response[:body])
        return response if result["revision"]
        next_index = result["next_index"]
        unless next_index.is_a?(Integer) && next_index > index && next_index <= total
          raise Error.new("Invalid Android cloud chunk acknowledgement", "invalid_http_response")
        end
        index = next_index
      end
      raise Error.new("Missing cloud commit receipt", "invalid_http_response")
    end
  end

  def self.install_android_network
    return false unless defined?(KIF::Platform) && KIF::Platform.android?
    return true if @android_online_adapter
    adapter = AndroidNetworkAdapter.new
    # Keep an already-installed JNI adapter for existing asset downloads. The
    # online client gets its own transport with the full cloud-save byte limit
    # and per-request deadline, instead of the older bridge's 64 KiB limit.
    KIF::Platform.instance_variable_set(:@multiplayer_http_adapter, adapter)
    KIF::Platform.install_http_adapter(adapter) unless KIF::Platform.network_available?
    @android_online_adapter = adapter
    true
  rescue Error => error
    @android_network_error = error
    false
  end
end

if defined?(KIF::Platform)
  module KIF::Platform
    class << self
      def validate_http_url(url)
        adapter = @multiplayer_http_adapter || @http_adapter
        adapter.validate_url(url) if adapter && adapter.respond_to?(:validate_url)
      end
      def http_request(method, url, body, token, timeout)
        adapter = @multiplayer_http_adapter || @http_adapter
        return nil unless adapter && adapter.respond_to?(:request)
        adapter.request(method, url, body, token, timeout)
      end
    end
  end
  KIFMultiplayer.install_android_network
end
