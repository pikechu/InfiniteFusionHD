# A published manifest pins every download. Only missing images may use the
# legacy on-demand path; background updates belong to the start menu.
module KIF
  module OfflineResources
    MANIFEST = "Data/offline-resources.json"
    CACHE = "Data/offline-resources"
    DATA_PATHS = ["Data/sprites/CUSTOM_SPRITES", "Data/sprites/BASE_SPRITES",
                  "Data/sprites/Sprite Credits.csv", "Data/pokedex/dex.json",
                  "Data/pokedex/all_entries.json", "Data/pokedex/dex_zh.json", "Data/pokedex/dex.json.gz"].freeze
    LIMIT = 8 * 1024 * 1024
    class Cancelled < StandardError; end

    class << self
      def parse(text)
        raise ArgumentError, "资源清单过大" unless text.is_a?(String) && text.bytesize <= LIMIT
        data = KIFMultiplayer::WireJSON.parse(text.dup.force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, ""), LIMIT)
        unless data.is_a?(Hash) && data["format"] == 1 && data["revision"].is_a?(String) &&
               data["revision"].match?(/\A[0-9a-f]{64}\z/) && data["files"].is_a?(Array) && data["files"].length.between?(1, 30000)
          raise ArgumentError, "无效资源清单"
        end
        seen = {}
        data["files"].each do |entry|
          raise ArgumentError, "无效资源条目" unless entry.is_a?(Hash)
          path, url, size = entry.values_at("path", "url", "size")
          image = path.is_a?(String) && path.match?(%r{\AGraphics/(?:CustomBattlers/spritesheets/(?:spritesheets_base|spritesheets_custom)|Battlers/(?:spritesheets_autogen|Eggs|Special))/[A-Za-z0-9_./ -]+\.png\z})
          image ||= path.is_a?(String) && path.match?(%r{\AGraphics/Battlers/substitute(?:_back)?\.png\z})
          unless (DATA_PATHS.include?(path) ? entry["kind"] == "data" : image && entry["kind"] == "image") && !path.split("/").any? { |part| part.empty? || part == "." || part == ".." } &&
                 !seen[path.downcase] && size.is_a?(Integer) && size.between?(1, LIMIT) &&
                 url.is_a?(String) && (url.match?(%r{\Ahttps://raw\.githubusercontent\.com/(?:pikechu/InfiniteFusionHD/(?:main|[0-9a-f]{40})|infinitefusion/infinitefusion-e18/[0-9a-f]{40})/[A-Za-z0-9_./% -]+\z}) ||
                 image && url.match?(%r{\Ahttps://infinitefusion\.net/customsprites/spritesheets/(?:spritesheets_base/[0-9]+|spritesheets_custom/[0-9]+/[0-9]+[a-z]{0,3})\.png\z})) &&
                 ((entry["sha256"].is_a?(String) && entry["sha256"].match?(/\A[0-9a-f]{64}\z/)) ||
                  (entry["sha1"].is_a?(String) && entry["sha1"].match?(/\A[0-9a-f]{40}\z/)))
            raise ArgumentError, "资源清单包含不支持的路径或校验值"
          end
          seen[path.downcase] = true
        end
        data
      end

      def json(value); KIFMultiplayer::WireJSON.dump(value); end
      def read_json(path)
        return {} unless File.file?(path) && File.size(path) <= LIMIT
        result = KIFMultiplayer::WireJSON.parse(File.binread(path).force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, ""), LIMIT)
        result.is_a?(Hash) ? result : {}
      rescue StandardError
        {}
      end
      def state
        @state ||= read_json(CACHE + "/state.json")
        @state["verified"] = {} unless @state["verified"].is_a?(Hash)
        @state
      end
      def installed?; state["installed"] == true; end
      def checksum(entry); entry["sha256"] || entry["sha1"]; end
      def bundled_manifest; @bundled_manifest ||= parse(File.binread(MANIFEST)); end
      def manifest
        return @manifest if @manifest
        @manifest = bundled_manifest
        if state["bundled_revision"] == @manifest["revision"] && File.file?(CACHE + "/manifest.json")
          begin
            @manifest = parse(File.binread(CACHE + "/manifest.json"))
          rescue StandardError
            # A damaged cache cannot hide the manifest shipped with the game.
          end
        end
        @manifest
      end
      def entries
        @entries ||= manifest["files"].each_with_object({}) { |entry, table| table[entry["path"]] = entry }
      end
      def complete?; state["complete_revision"] == manifest["revision"]; end
      def menu_label
        return _INTL("Offline resources (new)") if installed? && !complete?
        installed? ? _INTL("Offline resources") : _INTL("Download offline pack")
      rescue StandardError
        _INTL("Download offline pack")
      end

      def destination(path)
        # Android deliberately symlinks Graphics to its writable app directory.
        parts = path.split("/")
        parts.each_index do |index|
          next if index == 0 && parts[0] == "Graphics" && KIF::Platform.android?
          raise IOError, "资源目录包含符号链接" if File.symlink?(parts[0..index].join("/"))
        end
        KIF::SpriteImport.mkdir(File.dirname(path))
        KIF::Platform.android? ? KIF::Platform.send(:android_download_target, path) : path
      end
      def atomic(path, bytes)
        target = destination(path)
        pending = nil
        candidate = target + ".#{Process.pid}-#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000).to_i}.pending"
        File.open(candidate, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0600) do |file|
          pending = candidate
          raise IOError, "资源文件未完整写入" unless file.write(bytes) == bytes.bytesize
          file.flush; file.fsync
        end
        File.rename(pending, target)
      ensure
        File.delete(pending) if pending && File.file?(pending)
      end

      def valid_bytes?(entry, bytes)
        return false unless bytes.is_a?(String) && bytes.bytesize == entry["size"]
        require "digest/sha2"
        require "digest/sha1"
        hash = entry["sha256"] ? Digest::SHA256.hexdigest(bytes) : Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b)
        return false unless hash == checksum(entry)
        return true if entry["kind"] == "data"
        return false unless bytes.b.start_with?(KIF::SpriteImport::PNG) && bytes.byteslice(12, 4) == "IHDR"
        width, height = bytes.byteslice(16, 8).unpack("NN")
        width.between?(1, 4096) && height.between?(1, 8192) && width * height * 4 <= KIF::SpriteSheets.cache_budget
      end

      def file_path(entry)
        # Keep the verified source dex separately; the active file also contains
        # locally authored entries which an update must never remove.
        entry["path"] == "Data/pokedex/dex.json" ? CACHE + "/dex-source.json" : entry["path"]
      end
      def dex?(entry)
        ["Data/pokedex/dex.json", "Data/pokedex/dex.json.gz"].include?(entry["path"])
      end
      def dex_body(entry, bytes)
        return bytes unless entry["path"].end_with?(".gz")
        require "zlib"
        require "stringio"
        reader = Zlib::GzipReader.new(StringIO.new(bytes))
        result = "".b
        until reader.eof?
          result << reader.read(65536)
          raise IOError, "图鉴解压后超过容量限制" if result.bytesize > KIF::PokedexEntries::MAX_BYTES
        end
        result
      ensure
        reader.close if reader
      end
      def stamp(entry)
        path = file_path(entry)
        return nil unless File.file?(path)
        result = [checksum(entry), File.size(path), File.mtime(path).to_f.to_s]
        if dex?(entry) && File.file?(Settings::CUSTOM_DEX_ENTRIES_PATH)
          result += [File.size(Settings::CUSTOM_DEX_ENTRIES_PATH), File.mtime(Settings::CUSTOM_DEX_ENTRIES_PATH).to_f.to_s]
        end
        result
      end
      def valid_file?(entry, strict = false)
        path = file_path(entry)
        if !File.file?(path) && entry["path"] == "Data/pokedex/dex.json" && File.file?(entry["path"])
          bytes = File.binread(entry["path"])
          atomic(path, bytes) if valid_bytes?(entry, bytes)
        end
        return false unless File.file?(path) && !File.symlink?(path)
        known = (state["verified"] ||= {})
        return true if !strict && known[entry["path"]] == stamp(entry) && (!dex?(entry) || File.file?(Settings::CUSTOM_DEX_ENTRIES_PATH))
        known.delete(entry["path"])
        return false unless File.size(path) == entry["size"] && valid_bytes?(entry, File.binread(path))
        install(entry, File.binread(path)) if dex?(entry) && !File.file?(Settings::CUSTOM_DEX_ENTRIES_PATH)
        if dex?(entry)
          local = KIF::PokedexEntries.parse(File.binread(Settings::CUSTOM_DEX_ENTRIES_PATH))
          incoming = KIF::PokedexEntries.parse(dex_body(entry, File.binread(path)))
          return false unless KIF::PokedexEntries.merge(local, incoming)[:added] == 0
        end
        known[entry["path"]] = stamp(entry)
        true
      end
      def install(entry, bytes)
        raise IOError, "文件校验失败：#{entry['path']}" unless valid_bytes?(entry, bytes)
        if dex?(entry)
          target = Settings::CUSTOM_DEX_ENTRIES_PATH
          destination(target)
          incoming = KIF::PokedexEntries.parse(dex_body(entry, bytes))
          existing = File.file?(target) ? KIF::PokedexEntries.parse(File.binread(target)) : []
          merged = KIF::PokedexEntries.merge(existing, incoming)
          KIF::PokedexEntries.write(target, merged[:entries]) if merged[:added] > 0 || !File.file?(target)
        end
        atomic(file_path(entry), bytes)
        (state["verified"] ||= {})[entry["path"]] = stamp(entry)
      end

      # The embedded desktop native HTTP client is unsafe on Ruby workers. A
      # bundled, verified HTTPS child keeps both rendering and cancellation live.
      def fetch(url, limit = LIMIT)
        raise IOError, "网络功能不可用，请安装支持网络的游戏版本" unless KIF::Platform.network_available?
        if KIF::Platform.android? && ENV["KIF_ANDROID_NETWORK"] != "1"
          raise IOError, "请使用支持网络的 APK 下载资源"
        end
        executable = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32/WindowsPowerShell/v1.0/powershell.exe")
        if RUBY_PLATFORM.match?(/mswin|mingw/i) && File.file?(executable)
          KIF::SpriteImport.mkdir(CACHE)
          name = File.expand_path(CACHE + "/request-#{Process.pid}-#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000000).to_i}")
          status, output = name + ".json", name + ".bin"
          pid = Process.spawn(executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass", "-File", File.expand_path("Data/resource-download.ps1"),
            "-Url", url, "-Destination", output, "-Status", status, "-Limit", limit.to_s,
            :out => File::NULL, :err => File::NULL)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          loop do
            progress = read_json(status)
            yield(progress["received"].to_i) if block_given?
            finished = Process.waitpid2(pid, Process::WNOHANG)
            if finished
              pid = nil
              progress = read_json(status)
              raise IOError, "资源请求失败，请重试" unless finished[1].success? && progress["ok"] == true && File.file?(output)
              raise IOError, "资源响应过大" if File.size(output) > limit
              return File.binread(output)
            end
            raise IOError, "资源请求超时" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 35
            KIFMultiplayer.pump
            sleep(0.02)
          end
        else
          # Android's existing bridge yields from a cooperative Fiber while Java
          # performs TLS; it never creates a native-HTTP background Ruby thread.
          headers = url.start_with?("https://infinitefusion.net/") ? {"User-Agent" => "Mozilla/5.0 InfiniteFusionHD", "Range" => "bytes=0-#{limit - 1}"} : {}
          worker = KIFMultiplayer::FiberWorker.new { KIF::Platform.http_get(url, headers) }
          while worker.alive?
            worker.poll
            yield(0) if block_given?
            KIFMultiplayer.pump if worker.alive?
          end
          response = worker.value
          raise IOError, "资源请求失败，请重试" unless response.is_a?(Hash) && [200, 206].include?(response[:status]) && response[:body].is_a?(String) && response[:body].bytesize <= limit
          response[:body]
        end
      ensure
        if pid
          Process.kill("KILL", pid) rescue nil
          Process.waitpid(pid) rescue nil
        end
        worker.cancel if worker && worker.alive?
        [output, status, status && status + ".pending"].compact.each { |path| File.delete(path) if File.file?(path) }
      end

      def refresh
        text = fetch(Settings::OFFLINE_RESOURCES_URL) { |received| yield(received) if block_given? }
        incoming = parse(text)
        atomic(CACHE + "/manifest.json", text)
        @manifest, @entries = incoming, nil
        state["bundled_revision"] = bundled_manifest["revision"]
        atomic(CACHE + "/state.json", json(state))
        incoming
      end
      def startup
        return if @startup_checked
        @startup_checked = true
        begin
          refresh
        rescue StandardError
          # The bundled/last validated manifest and local game remain usable.
        end
        if installed? && !complete?
          KIFMultiplayer.with_ui_fonts { pbMessage("有新的离线资源可下载。请在开始菜单选择「离线资源（有更新）」，更新前仍可使用已下载的素材。") }
        end
      end

      def missing(path)
        entry = entries[path]
        return false unless entry && !File.file?(path)
        @missing_attempts ||= {}
        return false if @missing_attempts[path]
        @missing_attempts[path] = true
        install(entry, fetch(entry["url"]))
        true
      rescue StandardError
        false
      end

      def run(strict = false)
        view = Window_UnformattedTextPokemon.newWithSize("准备资源清单…", 0, 0, Graphics.width, 192)
        view.z = 99999
        current, done, total, count = "", 0, 0, 0
        pulse = lambda do |received = 0|
          raise Cancelled if Input.trigger?(Input::B)
          text = "#{strict ? '校验' : '下载'}离线资源 #{count}/#{manifest['files'].length}\n#{((done + received) / 1048576.0).round(1)} / #{(total / 1048576.0).round(1)} MB\n#{File.basename(current)}\n按返回键取消；已校验文件会保留。"
          view.text = text if view.text != text
        end
        begin
          refresh { |bytes| view.text = "正在检查资源更新… #{bytes / 1024} KB\n按返回键取消"; raise Cancelled if Input.trigger?(Input::B) } unless strict
        rescue Cancelled
          raise
        rescue StandardError
          pbMessage("暂时无法获取最新资源清单，将使用已缓存或游戏附带的清单。")
        end
        total = manifest["files"].sum { |entry| entry["size"] }
        state.delete("complete_revision")
        unless strict
          @missing_attempts = {}
          $kif_sprite_download_attempts = {}
          KIF::SpriteSheets.clear
        end
        failures = []
        manifest["files"].each do |entry|
          current = entry["path"]
          pulse.call
          KIFMultiplayer.pump
          begin
            unless valid_file?(entry, strict)
              raise IOError, "文件缺失或校验失败" if strict
              install(entry, fetch(entry["url"]) { |bytes| pulse.call(bytes) })
            end
          rescue Cancelled
            raise
          rescue StandardError => error
            failures << [entry["path"], error.message]
          end
          done += entry["size"]; count += 1
          atomic(CACHE + "/state.json", json(state)) if count % 25 == 0
        end
        pulse.call
        KIFMultiplayer.pump
        if failures.empty?
          state["installed"], state["complete_revision"] = true, manifest["revision"]
          $PokemonSystem.sprite_sheet_mode = 1
          $PokemonSystem.download_sprites = 0
          KIF::SpriteSheets.clear
          KIF::SpriteIndex.reset
        else
          state.delete("complete_revision")
        end
        atomic(CACHE + "/state.json", json(state))
        atomic(CACHE + "/failures.json", json({"files" => failures}))
        failures
      rescue Cancelled
        atomic(CACHE + "/state.json", json(state))
        nil
      ensure
        view.dispose if view && !view.disposed?
      end

      def open_menu
        loop do
          size = (manifest["files"].sum { |entry| entry["size"] } / 1_000_000_000.0).round(2)
          choice = pbMessage("离线资源管理\n完整包约 #{size} GB，校验通过的文件不会重复下载。新资源会在开始游戏前提示；缺失素材仍可按需下载。",
            ["一键下载 / 更新 / 重试失败项", "完整性校验", "检查资源更新", "返回"], 3)
          return if choice < 0 || choice == 3
          if choice == 2
            begin
              refresh
              pbMessage(complete? ? "资源版本已是最新。可使用完整性校验检查本地文件。" : "有尚未下载或更新的资源，请选择一键下载。")
            rescue StandardError
              pbMessage("检查失败，请确认网络后重试。本地资源仍可使用。")
            end
            next
          end
          failures = run(choice == 1)
          if failures.nil?
            pbMessage("已取消，已校验的资源已保留。下次下载会继续补齐。")
          elsif failures.empty?
            pbMessage("离线资源已全部通过校验。游玩优先使用本地素材，缺少新素材时仍可下载。")
          else
            retry_choice = pbMessage("有 #{failures.length} 个资源未通过校验或下载失败。已保留其他文件。\n#{failures.first[0]}", ["立即重试下载", "稍后再试"], 1)
            if retry_choice == 0
              failures = run(false)
              pbMessage(failures && failures.empty? ? "离线资源已全部通过校验。" : "尚未完成，可从资源菜单继续重试。")
            end
          end
        end
      rescue StandardError => error
        pbMessage("离线资源暂时不可用：#{error.message}")
      end
    end
  end
end
