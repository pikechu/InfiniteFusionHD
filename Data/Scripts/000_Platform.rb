# Shared platform capabilities. This root script loads before Settings and all
# game class definitions. Android-specific setup lives in the runtime preload.
module KIF
  module Platform
    class << self
      def android?
        defined?(System) && System.respond_to?(:is_android?) && System.is_android?
      end

      def desktop_tools?
        !android?
      end

      # Runtime releases disagree on System.delta's units. Use Ruby's monotonic
      # seconds for host-independent UI timeouts without changing native delta.
      def monotonic_seconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Ruby File/Dir calls do not use mkxp's case-insensitive asset lookup.
      # Resolve only reads, without caching misses that later downloads can fill.
      def read_path(path)
        return path unless android? && path.is_a?(String)
        normalized = path.tr("\\", "/")
        return normalized if File.exist?(normalized)

        if normalized.start_with?("/")
          current = resolved = "/"
          parts = normalized.split("/").reject(&:empty?)
        elsif normalized =~ /\A[A-Za-z]:\//
          current = resolved = normalized[0, 3]
          parts = normalized[3..-1].split("/").reject(&:empty?)
        else
          current = "."
          resolved = ""
          parts = normalized.split("/").reject(&:empty?)
        end
        parts.each do |part|
          return normalized unless File.directory?(current)
          entries = Dir.entries(current)
          actual = part if entries.include?(part)
          unless actual
            matches = entries.select { |entry| entry.casecmp?(part) }
            return normalized unless matches.length == 1
            actual = matches.first
          end
          current = File.join(current, actual)
          resolved = resolved.empty? ? actual : File.join(resolved, actual)
          actual = nil
        end
        return normalized unless File.exist?(current)
        resolved += "/" if normalized.end_with?("/") && !resolved.end_with?("/")
        resolved
      rescue SystemCallError, IOError
        normalized
      end

      # An Android adapter must use certificate and hostname verification.
      # Do not fall back to the bundled runtime's unverified HTTPS client.
      def install_http_adapter(adapter)
        unless adapter.respond_to?(:get) && adapter.respond_to?(:post_body)
          raise ArgumentError, "HTTP adapter must implement get and post_body"
        end
        @http_adapter = adapter
      end

      def network_available?
        !android? || !@http_adapter.nil?
      end

      def http_get(*args)
        return HTTPLite.get(*args) unless android?
        return @http_adapter.get(*args) if @http_adapter
        offline_response
      end

      def http_post_body(*args)
        return HTTPLite.post_body(*args) unless android?
        return @http_adapter.post_body(*args) if @http_adapter
        offline_response
      end

      def install_url_opener(opener)
        raise ArgumentError, "URL opener must be callable" unless opener.respond_to?(:call)
        @url_opener = opener
      end

      def open_android_url(url)
        return false unless android? && @url_opener
        !!@url_opener.call(url)
      end

      private

      def offline_response
        { :status => 0, :body => "", :headers => {},
          :error => "Android network adapter is unavailable" }
      end
    end
  end
end
