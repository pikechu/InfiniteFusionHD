module KIFMultiplayer
  # All game/profile/disk work happens on the main thread. A worker owns only
  # immutable request data and bounded network IO, and is never Thread#killed.
  class AsyncRequest
    def initialize(client); @client = client; end
    def busy?
      @worker.poll if @worker && @worker.respond_to?(:poll)
      @worker && @worker.alive?
    end
    def pending?; !!@worker; end
    def start(path, body, timeout = 5.0)
      raise Error.new("网络请求仍在执行。", "network_busy") if @worker
      transport, token, url = @client.transport, @client.token, @client.server + path
      transport.validate_url(url) if transport.respond_to?(:validate_url)
      detached = WireJSON.parse(WireJSON.dump(body))
      @worker = KIFMultiplayer.network_worker do
        begin
          response = transport.call("POST", url, detached, token, timeout)
          status = (response[:status] || response["status"]).to_i
          parsed = WireJSON.parse((response[:body] || response["body"]).to_s)
          unless status.between?(200, 299) && parsed.is_a?(Hash) && parsed["ok"] == true
            error = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
            raise Error.new(error["message"] || "网络暂时不可用。", error["code"] || "unreachable")
          end
          parsed
        rescue StandardError => error
          error
        end
      end
      KIFMultiplayer.register_worker(@worker)
      self
    end
    def take
      return nil unless @worker && !@worker.alive?
      worker, @worker = @worker, nil
      value = worker.value
      KIFMultiplayer.unregister_worker(worker)
      raise value if value.is_a?(Exception)
      value
    end
  end

  module AccountClient
    def authenticate(action, username, password, nickname = nil)
      raise Error, "无效登录操作。" unless %w[login register].include?(action)
      KIFMultiplayer.assert_identity_change_safe!(@profile)
      body = {"username" => username, "password" => password, "protocol" => PROTOCOL}
      body["nickname"] = nickname if nickname
      response = request("POST", "/v1/auth/#{action}", body, 15.0)
      adopt_account(response)
    end
    def adopt_account(response)
      identity, username = response["identity"], response["username"]
      raise Error, "登录响应无效。" unless identity.is_a?(Hash) && identity["id"].is_a?(String) && identity["id"] =~ /\Ap_[a-f0-9]{24}\z/ &&
        identity["nickname"].is_a?(String) && identity["nickname"].length.between?(1, 32) &&
        identity["friend_code"].is_a?(String) && identity["friend_code"] =~ /\A[A-F0-9]{8}\z/ &&
        username.is_a?(String) && username =~ /\A[a-z0-9_.-]{3,32}\z/ &&
        response["token"].is_a?(String) && response["token"] =~ /\A[\x21-\x7e]{20,512}\z/
      previous_id = player_id
      if previous_id && previous_id != identity["id"]
        @profile.data["archived_accounts"] ||= {}
        @profile.data["archived_accounts"][server] ||= {}
        @profile.data["archived_accounts"][server][previous_id] = WireJSON.parse(WireJSON.dump(@profile.account))
      end
      persist_account do |account|
        account.clear if previous_id != identity["id"]
        account.merge!("identity" => identity, "token" => response["token"], "username" => username, "connected" => true)
      end
      response
    end
  end
  Client.prepend(AccountClient)

  module OnlineFiles
    SLOT_IDS = {"File A" => "file-a", "File B" => "file-b", "File C" => "file-c", "File D" => "file-d",
      "File E" => "file-e", "File F" => "file-f", "File G" => "file-g", "File H" => "file-h", "Auto 1" => "auto-1", "Auto 2" => "auto-2"}.freeze
    def self.atomic(path, bytes)
      temporary = path + ".pending"
      File.open(temporary, "wb") { |f| f.write(bytes); f.flush; f.fsync rescue nil }
      File.rename(temporary, path)
    end
    def self.directory(path)
      missing, current = [], path
      until File.directory?(current)
        missing.unshift(current)
        parent = File.dirname(current)
        raise Error, "无法建立在线存档目录。" if parent == current
        current = parent
      end
      missing.each { |value| Dir.mkdir(value) }
      path
    end
  end

  class CloudSession
    INTERVAL = 60.0
    attr_reader :directory, :client, :session_id, :error, :last_uploaded, :fatal, :compatibility
    def initialize(client, compatibility = nil)
      require "digest/sha2"
      @client, @compatibility = client, compatibility || client.compatibility
      @server, @owner, @token = client.server, client.player_id, client.token
      raise Error, "在线模式需要账号登录。" unless client.profile.account["username"] && @owner.is_a?(String) && @owner =~ /\Ap_[a-f0-9]{24}\z/
      @session_id = KIFMultiplayer.operation_id
      @directory = OnlineFiles.directory(File.join(File.dirname(client.profile.path), "OnlineSaves", Digest::SHA256.hexdigest(@server)[0, 20], @owner))
      @state_path = File.join(@directory, "cloud-state.json")
      @state = File.file?(@state_path) ? WireJSON.parse(File.binread(@state_path), CloudCodec::MAX_JSON, 2_000_000) : {"slots" => {}}
      raise Error, "本地云存档索引损坏。" unless @state.is_a?(Hash) && @state["slots"].is_a?(Hash)
      @io = AsyncRequest.new(client)
      @next_poll, @next_save = 0, KIFMultiplayer.monotonic + INTERVAL
      @error, @fatal, @last_uploaded, @closed = nil, false, nil, false
    end
    def persist; OnlineFiles.atomic(@state_path, WireJSON.encode(@state, 0)); end
    def slot_state(slot); @state["slots"][slot] ||= {"revision" => 0}; end
    def file(slot); File.join(@directory, "#{OnlineFiles::SLOT_IDS.key(slot)}.rxdata"); end
    def pending?; @state["slots"].values.any? { |state| state["pending"] || state["deferred"] || state["unencoded"] }; end
    def bound?; @client.server == @server && @client.player_id == @owner && @client.token == @token; end

    def open
      opened = @client.request("POST", "/v1/cloud/open", {"session_id" => @session_id, "compatibility" => @compatibility})
      raise Error, "云存档列表无效。" unless opened["saves"].is_a?(Array) && opened["saves"].length <= 10
      # Retry durable, uncertain uploads first. Never overwrite a local pending
      # save with a downloaded older version after a crash or a lost response.
      @state["slots"].each do |slot, state|
        validate_slot(slot)
        queue_save(OnlineFiles::SLOT_IDS.key(slot), SaveData.read_from_file(file(slot))) if state["unencoded"] && !state["deferred"]
        while state["pending"]
          body = state["pending"].merge("session_id" => @session_id)
          response = @client.request("POST", "/v1/cloud/upload", body, 15.0)
          acknowledge(slot, response)
        end
      end
      opened = @client.request("POST", "/v1/cloud/open", {"session_id" => @session_id, "compatibility" => @compatibility})
      opened["saves"].each do |item|
        raise Error, "云存档槽位无效。" unless item.is_a?(Hash)
        slot = validate_slot(item["slot"])
        if slot_state(slot)["deferred"]
          raise Error.new("云端进度与本机待恢复事件不同，已保留本机记录。", "cloud_revision_conflict") unless slot_state(slot)["revision"] == item["revision"]
          next
        end
        response = @client.request("POST", "/v1/cloud/download", {"session_id" => @session_id, "slot" => slot}, 15.0)
        decoded = CloudCodec.unpack(response["save"])
        local = file(slot)
        state = slot_state(slot)
        if File.file?(local) && state["local_sha"] && KIFMultiplayer.file_digest(local) != state["local_sha"]
          # Preserve a newer local file if a crash prevented its queue metadata
          # from being committed. It must never disappear under a cloud pull.
          recovery = local + ".recovery-" + KIFMultiplayer.operation_id
          OnlineFiles.atomic(recovery, File.binread(local))
        end
        # Marshal is used only for this locally constructed cache, as required
        # by the original local save UI. It is never received from the network.
        OnlineFiles.atomic(file(slot), Marshal.dump(decoded))
        slot_state(slot)["revision"] = response["revision"]
        slot_state(slot)["local_sha"] = KIFMultiplayer.file_digest(file(slot))
        slot_state(slot).delete("dirty")
      end
      # Cache files absent from the server are retained as local recovery
      # copies but are not offered as online characters or uploaded implicitly.
      @available = (opened["saves"].map { |item| item["slot"] } + @state["slots"].select { |_slot, state| state["deferred"] }.keys).uniq
      persist
      @next_poll = KIFMultiplayer.monotonic + 10
      true
    rescue Exception
      begin
        @client.request("POST", "/v1/cloud/close", {"session_id" => @session_id}, 3.0)
      rescue Error
        nil
      end
      raise
    end

    def validate_slot(slot)
      raise Error, "不支持的云存档槽位。" unless OnlineFiles::SLOT_IDS.value?(slot)
      slot
    end
    def available?(name)
      slot = OnlineFiles::SLOT_IDS[name]
      slot && ((@available || []).include?(slot) || slot_state(slot)["pending"] || slot_state(slot)["dirty"])
    end

    def queue_save(name, data)
      return unless (slot = OnlineFiles::SLOT_IDS[name])
      raise Error, "在线身份发生变化，请返回登录界面。" unless bound?
      state = slot_state(slot)
      document = CloudCodec.pack(data)
      OnlineFiles.atomic(File.join(@directory, slot + ".upload.json"), WireJSON.dump(document))
      state["dirty"] = true
      state.delete("unencoded")
      state.delete("deferred")
      state["local_sha"] = KIFMultiplayer.file_digest(file(slot)) if File.file?(file(slot))
      prepare_upload(slot) unless state["pending"]
      persist
      @next_poll = 0
      @last_queued = KIFMultiplayer.monotonic
      (@available ||= []) << slot unless (@available || []).include?(slot)
    rescue StandardError => error
      if state
        state["unencoded"] = true
        persist
      end
      @error = error
      raise
    end
    def prepare_upload(slot)
      state = slot_state(slot)
      document = WireJSON.parse(File.binread(File.join(@directory, slot + ".upload.json")))
      state["pending"] = {"slot" => slot, "revision" => state["revision"], "upload_id" => KIFMultiplayer.operation_id, "save" => document}
      state.delete("dirty")
    end
    def acknowledge(slot, response)
      state = slot_state(slot)
      pending = state["pending"]
      raise Error, "云存档上传回执无效。" unless pending && response["slot"] == slot && response["upload_id"] == pending["upload_id"] && response["revision"] == pending["revision"] + 1
      state["revision"] = response["revision"]
      state.delete("pending")
      prepare_upload(slot) if state["dirty"]
      persist
      @last_uploaded = Time.now
    end

    def capture(force = false)
      return false unless defined?(OnlineMode) && OnlineMode.safe_to_save?(force)
      return true if force && @last_queued && KIFMultiplayer.monotonic - @last_queued < 1
      name = $Trainer.save_slot || SaveData::MANUAL_SLOTS.find { |slot| !available?(slot) }
      unless name
        @error = Error.new("在线角色槽位已满，请手动选择保存槽位。", "cloud_slots_full")
        return false
      end
      # Game.save writes the local recovery cache first; the hook queues JSON.
      Game.save(name)
    end
    def finalize_deferred
      return if $game_temp.in_battle || $game_temp.player_transferring || pbMapInterpreterRunning?
      @state["slots"].each do |slot, state|
        next unless state["deferred"]
        queue_save(OnlineFiles::SLOT_IDS.key(slot), SaveData.read_from_file(file(slot)))
      end
    rescue StandardError => error
      @error = error
    end
    def record_error(error); @error = error; end
    def defer_save(name)
      return unless (slot = OnlineFiles::SLOT_IDS[name])
      state = slot_state(slot)
      state["deferred"] = true
      persist
      (@available ||= []) << slot unless (@available || []).include?(slot)
      @next_save = KIFMultiplayer.monotonic + 1
    end
    def tick
      return if @closed || @fatal
      unless bound?
        @fatal, @error = true, Error.new("在线身份已改变，请重新登录。", "online_identity_changed")
        return
      end
      if @io.pending?
        return if @io.busy?
        begin
          result = @io.take
          acknowledge(@upload_slot, result) if @upload_slot
          @error = nil
        rescue StandardError => error
          @error = error
          @fatal = error.respond_to?(:code) && %w[cloud_revision_conflict account_in_use identity_invalid].include?(error.code)
          @needs_open = true if error.respond_to?(:code) && error.code == "cloud_session_lost"
          @next_poll = KIFMultiplayer.monotonic + 5
        ensure
          @upload_slot = nil
        end
      end
      now = KIFMultiplayer.monotonic
      if now >= @next_save
        captured = capture
        @next_save = now + (captured ? INTERVAL : 1)
      end
      return if @fatal || @io.pending? || now < @next_poll
      slot, state = @state["slots"].find { |_name, value| value["pending"] }
      if @needs_open
        @io.start("/v1/cloud/open", {"session_id" => @session_id, "compatibility" => @compatibility})
        @needs_open = false
      elsif slot
        @upload_slot = slot
        @io.start("/v1/cloud/upload", state["pending"].merge("session_id" => @session_id), 15.0)
      else
        @io.start("/v1/cloud/heartbeat", {"session_id" => @session_id})
      end
      @next_poll = now + (slot ? 0.3 : 10)
    rescue StandardError => error
      @error = error
      @next_poll = KIFMultiplayer.monotonic + 5
    end

    def flush(seconds = 20)
      deadline = KIFMultiplayer.monotonic + seconds
      @next_poll = 0
      while (pending? || @io.pending?) && KIFMultiplayer.monotonic < deadline && !@fatal
        tick
        @client.pump
        Thread.pass
      end
      !pending? && !@io.pending? && !@fatal
    end
    def close
      @closed = true
      @client.request("POST", "/v1/cloud/close", {"session_id" => @session_id}, 3.0) unless @io.busy?
    rescue Error
      nil
    end
  end
end
