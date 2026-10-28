# Android-only transport adapter. JSON comes from mkxp, not an unavailable stdlib.
# Native HTTPLite networking is deliberately never called here.
module KIF
  class AndroidHTTPAdapter
    MAX_REQUEST_JSON = 65_536
    MAX_REQUEST_BODY = 65_536
    MAX_RESPONSE_BODY = 32 * 1024 * 1024
    MAX_RESPONSE_BASE64 = ((MAX_RESPONSE_BODY + 2) / 3) * 4
    MAX_RESPONSE_JSON = MAX_RESPONSE_BASE64 + 512 * 1024
    MAX_HEADER_BYTES = 65_536
    HEADER_NAME = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/

    def get(url, headers = nil, follow_redirects = true)
      request("GET", url, nil, nil, headers, follow_redirects)
    end

    def post_body(url, body, content_type, headers = nil)
      request("POST", url, body, content_type, headers, false)
    end

    def available?
      ENV["KIF_ANDROID_NETWORK"] == "1" && defined?(KIFAndroidBridge) &&
        KIFAndroidBridge.respond_to?(:request) && defined?(HTTPLite::JSON) &&
        HTTPLite::JSON.respond_to?(:stringify) && HTTPLite::JSON.respond_to?(:parse)
    end

    private

    def failure(message)
      { :status => 0, :headers => {}, :body => "".b, :error => message }
    end

    def text(value, limit)
      raise ArgumentError, "Invalid text field" unless value.is_a?(String) && value.bytesize <= limit
      result = value.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "Invalid text encoding" unless result.valid_encoding?
      raise ArgumentError, "Control character in text field" if result.match?(/[\x00-\x1f\x7f]/)
      result
    end

    def checked_headers(value, maximum)
      value = {} if value.nil?
      raise ArgumentError, "Headers must be a Hash" unless value.is_a?(Hash) && value.length <= maximum
      result, names, total = {}, {}, 0
      value.each do |name, content|
        name = text(name, 256)
        content = text(content, 8192)
        raise ArgumentError, "Invalid header name" unless name.match?(HEADER_NAME)
        folded = name.downcase
        raise ArgumentError, "Duplicate header name" if names[folded]
        names[folded] = true
        total += name.bytesize + content.bytesize
        raise ArgumentError, "Header size limit" if total > MAX_HEADER_BYTES
        result[name] = content
      end
      result
    end

    def request(method, url, body, content_type, headers, follow_redirects)
      return failure("Android HTTPS bridge unavailable") unless available?
      url = text(url, 8192)
      raise ArgumentError, "HTTPS required" unless url.match?(/\Ahttps:\/\//i)
      authority = url[/\Ahttps:\/\/([^\/?#]*)/i, 1]
      unless authority && !authority.empty? && !authority.include?("@") && !url.include?(" ")
        raise ArgumentError, "Invalid HTTPS URL"
      end
      unless follow_redirects.nil? || follow_redirects == true || follow_redirects == false
        raise ArgumentError, "Invalid redirect option"
      end
      # mkxp's JSON writer requires string keys; symbols are not serializable.
      payload = { "method" => method, "url" => url,
                  "headers" => checked_headers(headers, 64),
                  "follow_redirects" => !!follow_redirects }
      if method == "POST"
        unless body.is_a?(String) && body.bytesize <= MAX_REQUEST_BODY
          raise ArgumentError, "Request body limit"
        end
        payload["body"] = [body].pack("m0")
        payload["content_type"] = text(content_type, 256)
      end
      encoded = HTTPLite::JSON.stringify(payload)
      unless encoded.is_a?(String) && encoded.bytesize <= MAX_REQUEST_JSON
        raise ArgumentError, "Request JSON limit"
      end
      raw = KIFAndroidBridge.request(encoded)
      unless raw.is_a?(String) && raw.bytesize <= MAX_RESPONSE_JSON
        raise ArgumentError, "Response JSON limit"
      end
      decoded_response(HTTPLite::JSON.parse(raw))
    rescue Exception => error
      # mkxp defines MKXPError directly under Exception, not StandardError.
      # Preserve Interrupt/SystemExit/RGSS reset instead of swallowing them.
      expected = error.is_a?(StandardError) || error.is_a?(LoadError) ||
        (defined?(::MKXPError) && error.is_a?(::MKXPError))
      raise unless expected
      # No URL, headers, body or arbitrary exception message crosses into logs.
      failure("Android HTTPS request failed (#{error.class})")
    end

    def decoded_response(response)
      raise ArgumentError, "Invalid response object" unless response.is_a?(Hash)
      status = response["status"]
      # This runtime's json2rb returns Float even for JSON integer values.
      valid_status = status.is_a?(Integer) || (status.is_a?(Float) && status.finite? && status == status.to_i)
      raise ArgumentError, "Invalid response status" unless valid_status
      status = status.to_i
      raise ArgumentError, "Invalid HTTP status" unless status == 0 || (100..599).include?(status)
      raise ArgumentError, "Missing response headers" unless response["headers"].is_a?(Hash)
      headers = checked_headers(response["headers"], 256)
      encoded_body = response["body"]
      unless encoded_body.is_a?(String) && encoded_body.bytesize <= MAX_RESPONSE_BASE64
        raise ArgumentError, "Response body limit"
      end
      body = encoded_body.unpack1("m0")
      unless body.bytesize <= MAX_RESPONSE_BODY && [body].pack("m0") == encoded_body
        raise ArgumentError, "Invalid response Base64"
      end
      if status == 0
        reason = response["error"]
        reason = "Android HTTPS request failed" unless reason.is_a?(String) && reason.match?(/\A[A-Za-z0-9_. -]{1,160}\z/)
        return failure(reason) # Never expose a partial body from a failed transfer.
      end
      raise ArgumentError, "Contradictory response error" if response.key?("error")
      body.force_encoding(Encoding::ASCII_8BIT)
      content_type = headers.find { |name, _value| name.downcase == "content-type" }
      if content_type && content_type[1].match?(/\A(?:text\/|application\/(?:json|xml|javascript)|image\/svg\+xml)/i)
        utf8 = body.dup.force_encoding(Encoding::UTF_8)
        body = utf8 if utf8.valid_encoding?
      end
      { :status => status, :headers => headers, :body => body }
    end
  end
end
