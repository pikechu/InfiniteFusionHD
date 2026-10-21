# Explicit diagnostic intent only. Uses public fixtures and separate probe files;
# never opens player saves and never calls native HTTPLite HTTP methods.
module KIFNetworkSmoke
  PNG_URL = "https://raw.githubusercontent.com/pikechu/kurayshinyrevamp/main/Graphics/BaseSprites/1.png"
  ECHO_URL = "https://httpbingo.org/post"

  class << self
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def assert(condition, message)
      raise message unless condition
    end

    def draw(message)
      @bitmap.clear
      @bitmap.fill_rect(0, 0, 512, 384, Color.new(22, 34, 48))
      @bitmap.font.size = 21
      @bitmap.draw_text(8, 8, 496, 36, "KIF Android HTTPS probe", 1)
      @bitmap.font.size = 16
      @bitmap.draw_text(8, 48, 496, 28, message, 1)
      @results.last(11).each_with_index do |entry, index|
        @bitmap.draw_text(12, 84 + index * 23, 488, 23, "#{entry['status']} #{entry['name']}")
      end
      3.times { Graphics.update; Input.update }
    end

    def check(name)
      draw(name)
      System.puts("KIF_NETWORK_CASE_BEGIN #{name}")
      started = monotonic
      details = yield
      elapsed = (monotonic - started).round(3)
      @results << {"name" => name, "status" => "PASS", "elapsed" => elapsed, "details" => details.to_s}
      System.puts("KIF_NETWORK_CASE_PASS #{name} elapsed=#{elapsed} #{details}")
    rescue Exception => error
      raise if error.is_a?(Interrupt) || error.is_a?(SystemExit)
      elapsed = (monotonic - started).round(3)
      details = "#{error.class}: #{error.message.to_s.byteslice(0, 220)}"
      @results << {"name" => name, "status" => "FAIL", "elapsed" => elapsed, "details" => details}
      System.puts("KIF_NETWORK_CASE_FAIL #{name} elapsed=#{elapsed} #{details}")
    ensure
      draw(name)
    end

    def run
      @results = []
      Graphics.resize_screen(512, 384)
      @bitmap = Bitmap.new(512, 384)
      @sprite = Sprite.new
      @sprite.bitmap = @bitmap
      System.puts("KIF_NETWORK_SMOKE_BEGIN ruby=#{RUBY_VERSION} runtime=#{System::VERSION} platform=#{System.platform}")
      # customScript bypasses the engine's preloadScript branch.
      load "kif_android_preload.rb"
      load "kif_android_http.rb"
      adapter = KIF::AndroidHTTPAdapter.new
      assert(adapter.available?, "Configured Ruby/JNI HTTPS adapter unavailable")

      check("bridge_json_utf8_and_request_limit") do
        encoded = HTTPLite::JSON.stringify({"method" => "TRACE", "url" => PNG_URL, "label" => "KIF测试🌈"})
        raw = KIFAndroidBridge.request(encoded)
        assert(raw.encoding == Encoding::UTF_8 && raw.valid_encoding?, "Bridge response is not valid UTF-8")
        response = HTTPLite::JSON.parse(raw)
        assert(response["status"].to_i == 0 && response["error"] == "ProtocolException", "Java JSON request/reply failed")
        rejected = false
        begin
          KIFAndroidBridge.request("x" * 65_537)
        rescue RuntimeError
          rejected = true
        end
        assert(rejected, "Native request size limit did not reject")
        "UTF8 JSON, invalid method and 64KiB native request limit"
      end

      check("trusted_https_png_binary") do
        response = adapter.get(PNG_URL)
        assert(response[:status] == 200, "PNG status=#{response[:status]} error=#{response[:error]}")
        bytes = response[:body]
        assert(bytes.encoding == Encoding::ASCII_8BIT, "PNG body encoding changed")
        assert(bytes.start_with?("\x89PNG\r\n\x1a\n".b), "PNG signature corrupt")
        width, height = bytes.byteslice(16, 8).unpack("N2")
        assert(width > 0 && height > 0, "Invalid PNG IHDR dimensions")
        File.binwrite("android-network-probe.png", bytes)
        bitmap = Bitmap.new("android-network-probe.png")
        assert(bitmap.width == width && bitmap.height == height, "Decoded bitmap differs from downloaded PNG")
        bitmap.dispose
        "bytes=#{bytes.bytesize} PNG=#{width}x#{height} saved=android-network-probe.png"
      end

      check("trusted_https_utf8_post_echo") do
        original = "KIF-UTF8-测试-🌈"
        response = adapter.post_body(ECHO_URL, original, "text/plain; charset=utf-8")
        assert(response[:status] == 200, "Echo status=#{response[:status]} error=#{response[:error]}")
        echo = HTTPLite::JSON.parse(response[:body])
        assert(echo["data"].is_a?(String) && echo["data"].b == original.b, "UTF-8 POST echo bytes differ")
        "UTF8 request and response bytes round-tripped over trusted HTTPS"
      end

      check("https_404_preserved") do
        response = adapter.get("https://raw.githubusercontent.com/pikechu/kurayshinyrevamp/main/kif-network-probe-not-found-20261016")
        assert(response[:status] == 404, "Missing status=#{response[:status]} error=#{response[:error]}")
        "HTTP 404 returned without treating transport as successful 200"
      end

      check("http_rejected_in_java") do
        raw = KIFAndroidBridge.request(HTTPLite::JSON.stringify({"method" => "GET", "url" => "http://10.0.2.2:8445/should-not-be-hit"}))
        response = HTTPLite::JSON.parse(raw)
        assert(response["status"].to_i == 0 && response["error"] == "ProtocolException", "Java accepted insecure HTTP")
        "Java rejects HTTP before sending; fixture request log must remain empty"
      end

      check("self_signed_certificate_rejected") do
        response = adapter.get("https://10.0.2.2:8443/ok")
        assert(response[:status] == 0 && response[:error].to_s.start_with?("SSL"), "Self-signed failure=#{response[:status]} #{response[:error]}")
        "#{response[:error]}; correlate host TLS handshake alert"
      end

      check("get_redirect_followed") do
        response = adapter.get("https://httpbingo.org/redirect/1")
        assert(response[:status] == 200, "Redirect status=#{response[:status]} error=#{response[:error]}")
        object = HTTPLite::JSON.parse(response[:body])
        assert(object["url"].is_a?(String) && object["url"].end_with?("/get"), "GET did not reach redirect destination")
        "One real HTTPS redirect reached /get"
      end

      check("post_307_not_replayed") do
        response = adapter.post_body("https://httpbingo.org/redirect-to?url=%2Fpost&status_code=307", "KIF-probe-only", "text/plain")
        assert(response[:status] == 307, "POST followed redirect or failed: #{response[:status]} #{response[:error]}")
        "307 preserved instead of replaying POST to /post"
      end

      check("invalid_host_bounded") do
        started = monotonic
        response = adapter.get("https://kif-network-probe.invalid/")
        elapsed = monotonic - started
        assert(response[:status] == 0 && elapsed <= 25.0, "DNS failure not bounded: #{elapsed}s #{response[:status]}")
        "#{response[:error]} elapsed=#{elapsed.round(3)}s"
      end

      check("real_stalled_tls_timeout_bounded") do
        started = monotonic
        response = adapter.get("https://10.0.2.2:8444/stall")
        elapsed = monotonic - started
        assert(response[:status] == 0 && elapsed >= 3.0 && elapsed <= 25.0, "Stall not exercised/bounded: #{elapsed}s #{response[:error]}")
        assert(response[:error].to_s.match?(/Timeout|Interrupted|SSL/), "Unexpected timeout failure #{response[:error]}")
        "#{response[:error]} elapsed=#{elapsed.round(3)}s; correlate host accepted socket"
      end

      check("https_recovers_after_timeout") do
        response = adapter.get(PNG_URL)
        assert(response[:status] == 200 && response[:body].start_with?("\x89PNG".b), "Networking did not recover: #{response[:status]} #{response[:error]}")
        "Trusted HTTPS succeeded after real cancellation/timeout"
      end

      failed = @results.count { |entry| entry["status"] == "FAIL" }
      result = {"ruby" => RUBY_VERSION, "runtime" => System::VERSION.to_s, "checks" => @results,
                "passed" => @results.length - failed, "failed" => failed}
      File.binwrite(File.join(ENV.fetch("KIF_ANDROID_FILES"), "android-network-smoke.json"), HTTPLite::JSON.stringify(result))
      System.puts("KIF_NETWORK_SMOKE_#{failed == 0 ? 'PASS' : 'FAIL'} checks=#{@results.length} passed=#{@results.length - failed} failed=#{failed}")
      draw("Completed: #{@results.length - failed} PASS / #{failed} FAIL")
      loop { Graphics.update; Input.update }
    end
  end
end

begin
  KIFNetworkSmoke.run
rescue Exception => error
  System.puts("KIF_NETWORK_SMOKE_FATAL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
  raise
end
