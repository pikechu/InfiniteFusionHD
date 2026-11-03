# Original controlled realms send intents and public projections only. No local
# save, victory, encounter specification or asset blob is uploaded by this model.
module KIFMultiplayer
  class OriginalClient
    attr_reader :client, :character, :original, :catalog, :move_ready_at
    def initialize(client = KIFMultiplayer.client)
      @client = client
      @controlled = ControlledClient.new(client)
    end
    def integer?(value, minimum, maximum)
      value.is_a?(Integer) && value.between?(minimum, maximum)
    end
    def refresh(id = @id)
      raise Error, "原版角色编号无效。" unless id.is_a?(String) && id =~ /\Acc_[a-f0-9]{32}\z/
      pending = @client.profile.account["pending"]
      @client.recover_pending if pending && pending["path"].to_s.start_with?("/v1/controlled/")
      @controlled.refresh unless @controlled.catalog
      @id = id
      accept(@client.request("GET", "/v1/controlled/characters/#{@id}/original"))
      self
    end
    def load_catalog
      result = @client.request("GET", "/v1/controlled/original-catalog", nil, 30.0)
      raise Error, "原版规则目录无效。" unless result["rules_hash"].to_s =~ /\A[a-f0-9]{64}\z/ && result["catalog"].is_a?(Hash)
      @catalog = result
    end
    def validate_monster(value)
      valid = value.is_a?(Hash) && value["id"].to_s =~ /\Acm_[a-f0-9]{32}\z/ &&
        value["species"].is_a?(String) && value["species"] =~ /\A[A-Za-z0-9_]{1,64}\z/ &&
        value["name"].is_a?(String) && value["name"].length <= 32 &&
        integer?(value["level"], 1, 1000) && integer?(value["exp"], 0, 9_007_199_254_740_991) &&
        integer?(value["max_hp"], 1, 1_000_000_000) && integer?(value["hp"], 0, value["max_hp"]) &&
        value["status"].is_a?(String) && value["moves"].is_a?(Array) && value["moves"].length <= 4
      raise Error, "原版精灵摘要无效。" unless valid
      value["moves"].each do |move|
        raise Error, "原版招式摘要无效。" unless move.is_a?(Hash) && move["id"].to_s =~ /\A[A-Z0-9_]{1,64}\z/ && integer?(move["total_pp"], 1, 1000) && integer?(move["pp"], 0, move["total_pp"])
      end
      value
    end
    def validate_world(world)
      raise Error, "原版地图摘要无效。" unless world.is_a?(Hash) && integer?(world["map_id"], 1, 100_000) &&
        integer?(world["x"], -4096, 4096) && integer?(world["y"], -4096, 4096) && [2,4,6,8].include?(world["direction"]) &&
        world["maps"].is_a?(Array) && world["maps"].length.between?(1, 128) && world["events"].is_a?(Array) && world["events"].length <= 10_000
      world["maps"].each do |map|
        raise Error, "原版图块摘要无效。" unless map.is_a?(Hash) && integer?(map["id"], 1, 100_000) &&
          integer?(map["width"], 1, 2000) && integer?(map["height"], 1, 2000) && integer?(map["layers"], 1, 3) &&
          integer?(map["tileset"], 1, 100_000) && map["origin"].is_a?(Array) && map["origin"].length == 2 && map["origin"].all? { |v| integer?(v, -4096, 4096) } &&
          [true, false].include?(map["full"]) && map["tiles"].is_a?(Array) && map["tiles"].length <= map["width"] * map["height"] * map["layers"]
        map["tiles"].each do |tile|
          raise Error, "原版图块变更无效。" unless tile.is_a?(Array) && tile.length == 2 && integer?(tile[0], 0, map["width"] * map["height"] * map["layers"] - 1) && integer?(tile[1], 0, 32767)
        end
      end
      world["events"].each do |event|
        raise Error, "原版事件摘要无效。" unless event.is_a?(Hash) && integer?(event["id"], 0, 100_000) &&
          integer?(event["x"], -4096, 4096) && integer?(event["y"], -4096, 4096) && event["graphic"].is_a?(String) && safe_asset?(event["graphic"]) &&
          [2,4,6,8].include?(event["direction"]) && integer?(event["tile"], 0, 32767) && integer?(event["width"], 1, 20) && integer?(event["height"], 1, 20)
      end
      pictures = world["pictures"]
      raise Error, "原版剧情图片无效。" unless pictures.is_a?(Array) && pictures.length <= 100 && pictures.all? { |picture| picture.is_a?(Hash) && safe_asset?(picture["name"]) && integer?(picture["id"], 1, 100) }
      world
    end
    def safe_asset?(name)
      name.is_a?(String) && name.length <= 240 && name !~ /[\\:\x00-\x1f]/ && !name.start_with?("/") && !name.split("/").include?("..")
    end
    def accept(response)
      character = @controlled.validate(response["character"])
      value = response["original"]
      raise Error, "原版角色响应无效。" unless character["id"] == @id && value.is_a?(Hash) && [true, false].include?(value["active"]) && (value.keys & %w[state seed document]).empty?
      if value["active"]
        view = value["view"]
        raise Error, "原版世界响应无效。" unless value["rules_hash"].to_s =~ /\A[a-f0-9]{64}\z/ && character["rules_hash"] == value["rules_hash"] && view.is_a?(Hash) && view["party"].is_a?(Array) && view["party"].length <= 6 && view["monsters"].is_a?(Array) && view["monsters"].length <= 10_000
        view["monsters"].each { |monster| validate_monster(monster) }
        validate_world(view["world"]) if view["world"]
        view["party"].each { |monster| validate_monster(monster) }
        ids = view["monsters"].map { |monster| monster["id"] }
        raise Error, "原版精灵归属重复。" unless ids.uniq.length == ids.length && view["party"].map { |monster| monster["id"] }.uniq.length == view["party"].length && view["party"].all? { |monster| ids.include?(monster["id"]) }
        prompt = value["prompt"]
        if prompt
          raise Error, "原版交互响应无效。" unless prompt.is_a?(Hash) && %w[confirm command safari_command move switch target choice forget_move pokemon name item number storage region_map gallery fishing movie credits slot voltorb].include?(prompt["kind"]) && integer?(value["prompt_index"], 0, 8191)
          raise Error, "原版选项无效。" if prompt["kind"] == "choice" && (!prompt["choices"].is_a?(Array) || prompt["choices"].length > 10_000 || !prompt["choices"].all? { |choice| choice.is_a?(String) })
        end
      end
      @character, @original = character, value
      remaining = value["active"] ? value["view"].fetch("next_move_at", 0) - response.fetch("as_of", 0) : 0
      @move_ready_at = KIFMultiplayer.monotonic + [remaining, 0].max
      response
    end
    def act(kind, arguments = {})
      raise Error, "请先刷新原版角色。" unless @id && @original
      fields = {"activate" => [], "migrate" => ["policy"], "wait" => [], "move" => ["direction"], "turn" => ["direction"], "interact" => [],
        "choose" => ["prompt_index", "value"], "use_item" => ["monster_id", "item"],
        "give_item" => ["monster_id", "item"], "take_item" => ["monster_id"]}
      fields.update("field_move" => ["monster_id", "move"], "field_item" => ["item"], "reorder" => ["party"], "save" => [])
      raise Error, "原版操作无效。" unless fields[kind] && arguments.is_a?(Hash) && arguments.keys.sort == fields[kind].sort
      load_catalog unless @original["active"] || @catalog
      rule = @original["active"] ? @original["rules_hash"] : @catalog["rules_hash"]
      accept(@client.request("POST", "/v1/controlled/characters/#{@id}/original", {
        "expected_revision" => @character["revision"], "expected_wallet_revision" => @character["wallet"]["revision"],
        "rules_hash" => rule, "intent" => arguments.merge("kind" => kind)}, 30.0))
    end
    def choose(value)
      raise Error, "没有等待回复的原版交互。" unless @original && @original["prompt"]
      act("choose", {"prompt_index" => @original["prompt_index"], "value" => value})
    end
    def heartbeat
      return unless @original && @original["active"]
      worker = @client.instance_variable_get(:@inflight_worker)
      return if worker && worker.alive?
      now = KIFMultiplayer.monotonic
      return if @heartbeat_at && now - @heartbeat_at < 5
      @heartbeat_at = now
      @client.request("POST", "/v1/controlled/characters/#{@id}/original/presence", {})
    rescue UncertainRequest
      false
    end
  end
end
