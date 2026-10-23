module KIFMultiplayer
  class MainlineClient
    attr_reader :client, :trading
    def initialize(client)
      @client, @trading = client, TradingClient.new(client)
    end
    def check(value, message = "托管主线响应无效。")
      raise Error.new(message, "invalid_mainline_response") unless value
    end
    def identifier(value); @trading.identifier(value); end
    def config
      value = @client.request("GET", "/v1/mainline/config")["config"]
      check(value.is_a?(Hash) && [true, false].include?(value["enabled"]) && value["currency"] == "LINK" && value["max_party"] == 6)
      value
    end
    def validate_asset(asset)
      CollectionClient.new(@client).validate_asset(asset)
      check(asset["version"].nil? || asset["version"].is_a?(Integer) && asset["version"] > 0)
      TradeCodec.validate(asset["full"]) if asset["full"]
      asset
    end
    def validate_character(value)
      check(value.is_a?(Hash) && value["owner_id"] == @client.player_id)
      identifier(value["id"])
      check(value["name"].is_a?(String) && value["name"].length.between?(1, 20) && value["revision"].is_a?(Integer) && value["revision"] > 0)
      check(value["party"].is_a?(Array) && value["party"].length <= 6)
      value["party"].each { |asset| validate_asset(asset); check(!!asset["full"], "队伍精灵缺少服务器完整资料。") }
      check(value["party"].map { |asset| asset["id"] }.uniq.length == value["party"].length)
      wallet = value["wallet"]
      check(wallet.is_a?(Hash) && wallet["owner_id"] == @client.player_id && wallet["currency"] == "LINK")
      %w[balance available reserved version].each { |key| @trading.amount(wallet[key]) }
      check(wallet["available"] + wallet["reserved"] == wallet["balance"])
      value
    end
    def characters
      values = @client.request("GET", "/v1/mainline/characters")["characters"]
      check(values.is_a?(Array) && values.length <= 8)
      values.map { |value| validate_character(value) }
    end
    def character(id)
      validate_character(@client.request("GET", "/v1/mainline/characters/#{identifier(id)}")["character"])
    end
    def sync(id)
      value=@client.raw_request('POST',"/v1/mainline/characters/#{identifier(id)}/sync",{'compatibility'=>@client.compatibility})
      {'character'=>validate_character(value['character']),'inventory'=>@trading.validate_inventory(value['inventory'])}
    end
    def asset(id)
      validate_asset(@client.request("GET", "/v1/mainline/assets/#{identifier(id)}")["asset"])
    end
    def pc(character_id, cursor = nil)
      value = @client.raw_request("POST", "/v1/mainline/characters/#{identifier(character_id)}/pc/search", {"cursor" => cursor || ""})
      check(value["assets"].is_a?(Array) && value["assets"].length <= 50)
      value["assets"].each { |entry| validate_asset(entry) }
      check(value["next_cursor"].nil? || value["next_cursor"].is_a?(String))
      value
    end
    def set_party(character, asset_ids)
      check(asset_ids.is_a?(Array) && asset_ids.length <= 6 && asset_ids.uniq.length == asset_ids.length)
      asset_ids.each { |id| identifier(id) }
      validate_character(@client.request("POST", "/v1/mainline/characters/#{identifier(character['id'])}/party", {"revision" => character["revision"], "asset_ids" => asset_ids})["character"])
    end
    def validate_job(value)
      check(value.is_a?(Hash) && %w[queued running completed failed].include?(value["status"]))
      identifier(value["id"])
      identifier(value["character_id"])
      check(value["operation"].is_a?(String))
      value
    end
    def job(id)
      validate_job(@client.request("GET", "/v1/mainline/jobs/#{identifier(id)}")["job"])
    end
    def jobs
      values = @client.request("GET", "/v1/mainline/jobs")["jobs"]
      check(values.is_a?(Array) && values.length <= 100)
      values.each { |value| validate_job(value) }
      values
    end
    def intent; @client.profile.account["mainline_intent"]; end
    def save_intent(value)
      LocalJournal.change(@client.profile) do
        value ? @client.profile.account["mainline_intent"] = value : @client.profile.account.delete("mainline_intent")
      end
    end
    def submit(path, body)
      recover if intent
      body = WireJSON.parse(WireJSON.dump(body))
      body["request_id"] ||= KIFMultiplayer.operation_id
      record = {"owner_id" => @client.player_id, "server" => @client.server, "path" => path, "body" => body}
      save_intent(record)
      value = @client.request("POST", path, body)
      if value["job"]
        validate_job(value["job"])
        save_intent(record.merge("job_id" => value["job"]["id"]))
      else
        save_intent(nil)
      end
      value
    rescue HTTPRejected
      save_intent(nil) if intent && intent["body"]["request_id"] == body["request_id"]
      raise
    end
    def create(name, gender, species)
      value = submit("/v1/mainline/characters", {"name" => name, "gender" => gender, "starter" => species, "compatibility" => @client.compatibility})
      character = validate_character(value["character"])
      wait(value["job"]["id"]) if value["job"]
      self.character(character["id"])
    end
    def operate(character_id, operation, asset_ids, params = {})
      value = submit("/v1/mainline/characters/#{identifier(character_id)}/jobs", {"operation" => operation, "asset_ids" => asset_ids, "params" => params, "compatibility" => @client.compatibility})
      wait(value["job"]["id"])
    end
    def wait(id, seconds = 120)
      deadline = KIFMultiplayer.monotonic + seconds
      loop do
        value = job(id)
        if %w[completed failed].include?(value["status"])
          save_intent(nil) if intent && intent["job_id"] == id
          raise Error.new("服务器未接受这次操作，资源预留已释放。", value["error_code"] || "native_failed") if value["status"] == "failed"
          return value
        end
        raise Error.new("服务器仍在处理，请从托管主线恢复原操作。", "mainline_pending") if KIFMultiplayer.monotonic >= deadline
        until_time = KIFMultiplayer.monotonic + 0.25
        @client.pump while KIFMultiplayer.monotonic < until_time
      end
    end
    def recover
      @client.recover_pending
      record = intent
      return jobs unless record
      check(record["owner_id"] == @client.player_id && record["server"] == @client.server, "请使用发起托管操作的原服务器和身份恢复。")
      unless record["job_id"]
        begin
          receipt = @client.request("GET", "/v1/operations/#{identifier(record['body']['request_id'])}")
          value = receipt["response"]
        rescue HTTPRejected => error
          raise unless error.code == "operation_not_found"
          value = @client.request("POST", record["path"], record["body"])
        end
        if value["job"]
          validate_job(value["job"])
          record = record.merge("job_id" => value["job"]["id"])
          save_intent(record)
        else
          save_intent(nil)
          return value
        end
      end
      current = job(record["job_id"])
      if current["operation"] == "battle" && defined?(MainlineBattleUI)
        MainlineBattleUI.new(@client).run(record["job_id"])
      else
        wait(record["job_id"])
      end
    end
  end

  previous_mainline_identity_guard = identity_change_guard
  self.identity_change_guard = lambda do |profile|
    previous_mainline_identity_guard.call(profile) if previous_mainline_identity_guard
    if (profile.data["servers"] || {}).values.any? { |account| account.is_a?(Hash) && account["mainline_intent"] }
      raise Error.new("请先恢复托管主线操作，再更换服务器或身份。", "mainline_identity_locked")
    end
  end
end
