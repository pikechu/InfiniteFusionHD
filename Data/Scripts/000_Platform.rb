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

      # Android's virtual keys are owned by the input bridge. Ruby's save root
      # is also separate from SDL's native preferences/keybinding directory.
      def desktop_keybinding_bootstrap?
        !android?
      end

      # Desktop save settings can request a small window after startup. Android
      # always uses the full surface; Android's display preference controls
      # whether mkxp preserves 4:3 or stretches to fill that surface.
      # Do not rewrite the saved desktop preference or apply a window scale.
      def screen_resize_factor(requested_factor)
        android? ? 4 : requested_factor
      end

      # Android can commit the final IME text in the same frame as Return/Esc.
      # Finish that single-line edit before pbFreeText returns or drops its window.
      def finish_text_entry(window, accepted)
        return unless android?
        pending = Input.gets
        return unless accepted
        pending.each_char do |character|
          # An IME Return can also commit a newline; it is the submit key here.
          next if character == "\r" || character == "\n"
          window.insert(character)
        end
      end

      # An imported/renamed slot can still name its original save target inside
      # Marshal data. Bind manual loads before Game.load can run map callbacks
      # or autosave. Auto slots keep their original manual save destination.
      def prepare_loaded_save(data, selected_slot)
        return data unless android? && data.is_a?(Hash) && defined?(SaveData::MANUAL_SLOTS) &&
          SaveData::MANUAL_SLOTS.include?(selected_slot)
        [:player, :kuray_player].each do |key|
          player = data[key]
          player.save_slot = selected_slot if player && player.respond_to?(:save_slot=)
        end
        data
      end

      # The desktop download survey's honest "Other" path quits the game.
      # Replace only this verified startup notice for the independent test APK;
      # leave the parent intro, story switches and all other events intact.
      def common_event_commands(id, event)
        list = event.list
        return list unless android? && id == 108 && event.name == "gameDownload Warning" &&
          event.trigger == 0 && list.length == 91
        signature = {
          4 => [355, 0, ['options=["The game\'s official Discord",']],
          8 => [655, 0, ['"Other"]']],
          9 => [655, 0, ['selected= optionsMenu(options,nil,4)']],
          10 => [655, 0, ['pbSet(5,selected)']],
          50 => [115, 0, []],
          82 => [355, 2, ['openUrlInBrowser(Settings::DISCORD_URL)']],
          83 => [355, 2, ['#Quit game']],
          84 => [655, 2, ['$scene = nil']],
          90 => [0, 0, []]
        }
        return list unless signature.all? do |index, expected|
          command = list[index]
          [command.code, command.indent, command.parameters] == expected
        end
        [
          RPG::EventCommand.new(101, 0, ["KIF Android Test is an independent test port."]),
          RPG::EventCommand.new(401, 0, ["This APK is not an official upstream release."]),
          RPG::EventCommand.new(101, 0, ["Obtain builds from a source you trust."]),
          RPG::EventCommand.new(401, 0, ["Your adventure will now continue."]),
          RPG::EventCommand.new(355, 0, ["pbSet(5,4)"]),
          RPG::EventCommand.new(115, 0, []),
          RPG::EventCommand.new(0, 0, [])
        ]
      end

      # Runtime releases disagree on System.delta's units. Use Ruby's monotonic
      # seconds for host-independent UI timeouts without changing native delta.
      def monotonic_seconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Install after the game's Input wrapper has captured its original update.
      # This capability is independent of networking and never installs on Windows.
      def install_input_bridge
        return @android_input_backend if @android_input_backend
        return false unless android? && ENV["KIF_ANDROID_INPUT"] == "1" &&
          @android_input_bridge_loaded && defined?(KIFAndroidBridge) &&
          KIFAndroidBridge.respond_to?(:input_poll) && defined?(Input)
        path = File.expand_path("kif_android_input.rb")
        unless File.file?(path)
          System.puts("KIF Android input adapter missing; native input remains active") if System.respond_to?(:puts)
          return false
        end
        load path unless defined?(KIF::AndroidInputBackend)
        @android_input_backend = KIF::AndroidInputBackend.install(Input, KIFAndroidBridge)
        System.puts("KIF_ANDROID_INPUT_READY") if System.respond_to?(:puts)
        @android_input_backend
      rescue LoadError, StandardError => error
        System.puts("KIF Android input adapter unavailable (#{error.class}); native input remains active") if System.respond_to?(:puts)
        false
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

      # Native Bitmap lookup is case-sensitive when mkxp pathCache is disabled.
      # Resolve extensionless RPG::Cache/BitmapWrapper paths at the native boundary.
      def read_bitmap_path(path)
        return path unless android? && path.is_a?(String)
        normalized = path.tr("\\", "/")
        resolved = read_path(normalized)
        return resolved if File.file?(resolved)
        [".png", ".gif", ".jpg", ".jpeg", ".bmp", ".webp"].each do |extension|
          candidate = read_path(normalized + extension)
          return candidate if File.file?(candidate)
        end
        normalized
      rescue SystemCallError, IOError, ArgumentError
        normalized
      end

      # A failed Android download must never truncate a cached asset. Windows
      # retains the existing direct File.open behavior and exception handling.
      def write_download(path, body)
        unless android?
          File.open(path, "wb") { |file| file.write(body) }
          return true
        end
        pending = nil
        begin
          raise ArgumentError, "Invalid download body" unless body.is_a?(String) && body.bytesize <= 8 * 1024 * 1024
          destination = android_download_target(path)
          case File.extname(destination).downcase
          when ".png"
            raise ArgumentError, "Expected PNG" unless body.b.start_with?("\x89PNG\r\n\x1a\n".b)
          when ".gif"
            raise ArgumentError, "Expected GIF" unless body.b.start_with?("GIF87a", "GIF89a")
          end
          flags = File::WRONLY | File::CREAT | File::EXCL | File::BINARY
          8.times do |attempt|
            stamp = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000_000).to_i
            candidate = File.join(File.dirname(destination), ".#{File.basename(destination)}.kif-download-#{Process.pid}-#{Thread.current.object_id}-#{stamp}-#{attempt}.partial")
            begin
              File.open(candidate, flags, 0600) do |file|
                pending = candidate # Only remove a file this call created with EXCL.
                file.binmode
                offset = 0
                while offset < body.bytesize
                  chunk = body.byteslice(offset, 65_536)
                  count = file.write(chunk)
                  raise IOError, "Short download write" unless count.is_a?(Integer) && count > 0 && count <= chunk.bytesize
                  offset += count
                end
                file.flush
                file.fsync
              end
              break
            rescue Errno::EEXIST
              raise if pending
            end
          end
          raise IOError, "Cannot stage download" unless pending
          File.rename(pending, destination) # Same-directory atomic replacement; never delete the old file.
          pending = nil
          true
        rescue StandardError => error
          System.puts("KIF Android download write failed (#{error.class})") if System.respond_to?(:puts)
          false
        ensure
          begin
            File.delete(pending) if pending && File.file?(pending)
          rescue SystemCallError, IOError => cleanup_error
            System.puts("KIF Android download staging cleanup failed (#{cleanup_error.class})") if System.respond_to?(:puts)
          end
        end
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

      def android_download_target(path)
        raise ArgumentError, "Invalid download path" unless path.is_a?(String) && !path.empty? && !path.match?(/[\x00-\x1f\x7f]/)
        normalized = path.tr("\\", "/")
        raise ArgumentError, "Download traversal" if normalized.split("/").include?("..")
        files = ENV["KIF_ANDROID_FILES"]
        unless files.is_a?(String) && (files.start_with?("/") || files.match?(/\A[A-Za-z]:[\\\/]/))
          raise ArgumentError, "Private files directory unavailable"
        end
        root = File.realpath(files).tr("\\", "/").sub(%r{/+\z}, "")
        raise ArgumentError, "Invalid private root" if root.empty? || root.match?(/\A[A-Za-z]:\z/)
        expanded = File.expand_path(normalized)
        parent = File.realpath(read_path(File.dirname(expanded))).tr("\\", "/")
        # Windows host contract tests use drive paths; Android uses case-sensitive POSIX paths.
        compared_parent = root.match?(/\A[A-Za-z]:\//) ? parent.downcase : parent
        compared_root = root.match?(/\A[A-Za-z]:\//) ? root.downcase : root
        unless compared_parent == compared_root || compared_parent.start_with?(compared_root + "/")
          raise ArgumentError, "Download outside app storage"
        end
        ["saves", "backups"].each do |protected_name|
          protected_path = compared_root + "/" + protected_name
          if compared_parent == protected_path || compared_parent.start_with?(protected_path + "/")
            raise ArgumentError, "Download into save storage"
          end
        end
        # This game's loader reads every file in Scripts, including interrupted
        # temporary files. Remote code updates are not an Android download path.
        raise ArgumentError, "Download into script loader" if parent.downcase.match?(%r{(?:\A|/)data/scripts(?:/|\z)})
        name = File.basename(expanded)
        raise ArgumentError, "Invalid download filename" if name == "." || name == ".." || name.empty?
        destination = read_path(File.join(parent, name))
        raise ArgumentError, "Download destination symlink" if File.symlink?(destination)
        raise ArgumentError, "Invalid download destination" if File.exist?(destination) && !File.file?(destination)
        destination
      end

      def offline_response
        { :status => 0, :body => "", :headers => {},
          :error => "Android network adapter is unavailable" }
      end
    end
  end
end

# The preload runs before this file and may only mark a native bridge as loaded.
# The adapter lives beside mkxp.json in the packaged game root, outside Scripts.
if KIF::Platform.android? && ENV["KIF_ANDROID_NETWORK"] == "1" &&
   KIF::Platform.instance_variable_get(:@android_network_bridge_loaded) &&
   defined?(KIFAndroidBridge) && KIFAndroidBridge.respond_to?(:request)
  adapter_path = File.expand_path("kif_android_http.rb")
  if File.file?(adapter_path)
    begin
      load adapter_path unless defined?(KIF::AndroidHTTPAdapter)
      adapter = KIF::AndroidHTTPAdapter.new
      KIF::Platform.install_http_adapter(adapter) if adapter.available?
    rescue LoadError, StandardError => error
      System.puts("KIF Android HTTPS adapter unavailable (#{error.class}); continuing offline") if System.respond_to?(:puts)
    end
  end
end
