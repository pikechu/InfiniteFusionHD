# Local casual trades deliberately do not claim server-authoritative provenance.
# Network data is restricted JSON. Marshal below only WRITES the existing trusted
# local SaveData hash; no network data is deserialized as Ruby objects.
module KIFMultiplayer
  # Profile writes can fail independently of an already committed game save.
  # Keep the in-memory journal in agreement with its last durable version so a
  # retry cannot silently replace a transaction/draft that is still on disk.
  module LocalJournal
    def self.copy(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), result| result[key.dup] = copy(item) }
      when Array then value.map { |item| copy(item) }
      when String then value.dup
      else value
      end
    end
    def self.change(profile)
      previous = copy(profile.data)
      begin
        yield
        profile.save
      rescue StandardError
        profile.data.replace(previous)
        raise
      end
    end
  end
  def self.trade_identity_locked?(profile)
    saved_escrow = defined?($Trainer) && $Trainer && $Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow)
    accounts = profile.data["servers"] || {}
    !!saved_escrow || accounts.values.any? { |account| account.is_a?(Hash) && account["trade_pending"] }
  end

  module TradeCodec
    VERSION = 1
    INTEGER_FIELDS = {
      "exp" => [0, 20_000_000], "hp" => [0, 65_535], "status_count" => [0, 65_535],
      "cool" => [0, 255], "beauty" => [0, 255], "cute" => [0, 255],
      "smart" => [0, 255], "tough" => [0, 255], "sheen" => [0, 255],
      "pokerus" => [0, 255], "markings" => [0, 65_535],
      "obtain_method" => [0, 4], "obtain_map" => [0, 1_000_000],
      "hatched_map" => [0, 1_000_000], "obtain_level" => [1, 100],
      "kuray_no_evo" => [0, 1], "hat_x" => [-1_000, 1_000], "hat_y" => [-1_000, 1_000]
    }
    OPTIONAL_INTEGER_FIELDS = {
      "time_form_set" => [0, 0xffffffff], "time_received" => [0, 0xffffffff],
      "time_egg_hatched" => [0, 0xffffffff],
      "exp_when_fused_head" => [0, 20_000_000], "exp_when_fused_body" => [0, 20_000_000],
      "exp_gained_since_fused" => [0, 20_000_000],
      "body_original_ability_index" => [0, 5], "head_original_ability_index" => [0, 5]
    }
    SPECIAL_FIELDS = %w[status poke_ball first_moves ribbons obtain_text veryunique glitter force_disobey imported type1kuray type2kuray sprite_asset old_sprite_asset]
    FIELDS = (INTEGER_FIELDS.keys + OPTIONAL_INTEGER_FIELDS.keys + SPECIAL_FIELDS).freeze
    IVARS = { "status_count" => "statusCount", "time_received" => "timeReceived", "time_egg_hatched" => "timeEggHatched", "sprite_asset" => "kuraycustomfile", "old_sprite_asset" => "oldkuraycustomfile" }.freeze
    CACHE_IVARS = %w[species_data level totalhp attack defense spatk spdef speed].freeze
    BASE_IVARS = %w[species form forced_form steps_to_hatch name gender personalID nature nature_for_stats ability ability_index ability2 ability2_index item moves iv ivMaxed ev happiness shiny owner hiddenPowerType].freeze
    REJECTED_IVARS = %w[mail fused hat kuraycustomfile oldkuraycustomfile typeoverwrite shadow heart_gauge hyper_mode saved_exp saved_ev shadow_moves].freeze

    def self.copy(data); WireJSON.parse(WireJSON.dump(data)); end
    def self.natural_ability(pokemon)
      species = pokemon.species_data
      index = pokemon.ability_index
      ability = index >= 2 ? species.hidden_abilities[index - 2] : nil
      index = pokemon.personalID & 1 if index >= 2 && !ability
      ability || species.abilities[index] || species.abilities[0]
    end
    def self.entry_matches?(entry)
      current = export(entry["pokemon"])
      return true if current == entry["snapshot"]
      # Before codec_version=2, Snapshot.export could lazily fill an unset
      # ability in its internal clone using DoubleAbilities/NO_LEVELS. Accept
      # only exact outputs of those old getters for trusted old escrow, with
      # every other field exact. New entries cannot use this allowance.
      return false if entry.key?("codec_version")
      pokemon = entry["pokemon"].clone
      return false unless pokemon.respond_to?(:species_data)
      species = pokemon.species_data
      natural = natural_ability(pokemon)
      stored = pokemon.instance_variable_get(:@ability)
      second = pokemon.instance_variable_get(:@ability2)
      second_index = pokemon.instance_variable_get(:@ability2_index)
      hidden = pokemon.ability_index >= 2 && species.hidden_abilities[pokemon.ability_index - 2]
      [false, true].any? do |no_levels|
        populated = no_levels && !stored && !hidden
        primary = stored || (populated ? species.abilities[0] : natural)
        [false, true].any? do |double|
          secondary = second || (double ? (populated ? species.abilities[1] || species.abilities[0] : natural) : nil)
          migrated = copy(current)
          migrated["pokemon"]["ability"] = primary.to_s
          migrated["pokemon"]["ability2"] = secondary && secondary.to_s
          migrated["pokemon"]["ability2_index"] = second_index || (double ? pokemon.personalID & 1 : nil)
          migrated == entry["snapshot"]
        end
      end
    end
    def self.check(condition, message); Snapshot.check(condition, "交换不兼容：#{message}"); end
    def self.safe_string(value, maximum)
      value.is_a?(String) && value.length <= maximum && value !~ /[\x00-\x1f]/
    end
    def self.validate(data)
      check(data.is_a?(Hash) && data.keys.sort == %w[pokemon preserved version], "报价结构或字段版本不支持")
      check(data["version"] == VERSION, "交换字段版本不支持")
      Snapshot.validate(data["pokemon"])
      values = data["preserved"]
      check(values.is_a?(Hash) && values.keys.sort == FIELDS.sort, "个体保留字段缺失或未支持")
      INTEGER_FIELDS.each { |key, bounds| check(Snapshot.number(values[key], *bounds), "#{key} 超出支持范围") }
      OPTIONAL_INTEGER_FIELDS.each do |key, bounds|
        check(values[key].nil? || Snapshot.number(values[key], *bounds), "#{key} 超出支持范围")
      end
      check(%w[NONE SLEEP POISON BURN PARALYSIS FROZEN].include?(values["status"]), "异常状态不支持")
      Snapshot.registry(:Item, values["poke_ball"])
      [["first_moves", :Move, 256], ["ribbons", :Ribbon, 128]].each do |key, registry, limit|
        check(values[key].is_a?(Array) && values[key].length <= limit, "#{key} 列表不支持")
        values[key].each { |id| Snapshot.registry(registry, id) }
      end
      check(values["obtain_text"].nil? || safe_string(values["obtain_text"], 256), "获得说明不支持")
      check(values["veryunique"].nil? || (values["veryunique"].is_a?(String) && values["veryunique"] =~ /\A[A-Za-z0-9_-]{1,80}\z/), "本地个体标记不支持")
      %w[glitter force_disobey].each { |key| check([nil, true, false].include?(values[key]), "#{key} 不支持") }
      check([true, false].include?(values["imported"]), "导入标记不支持")
      %w[type1kuray type2kuray].each { |key| Snapshot.registry(:Type, values[key], true) }
      %w[sprite_asset old_sprite_asset].each do |key|
        value = values[key]
        check(value.nil? || value == "default" || (value.is_a?(String) && value =~ /\A(?:base:[1-9][0-9]{0,2}[A-Za-z_-]{0,12}|fusion:[1-9][0-9]{0,2}\.[1-9][0-9]{0,2}[A-Za-z_-]{0,12})\z/), "#{key} 素材标识不支持")
      end
      data
    end

    def self.asset_key(path)
      return nil if path.nil? || path == ""
      return "default" if path == "none"
      if defined?(KIF::SpriteSheets) && (entry = KIF::SpriteSheets.request(path))
        return "default" if entry[0] == :autogen
        path = KIF::SpriteSheets.logical_path(path)
      end
      base = /\AGraphics\/BaseSprites\/([1-9][0-9]{0,2}[A-Za-z_-]{0,12})\.png\z/.match(path.to_s)
      return "base:#{base[1]}" if base
      prefix = Settings::CUSTOM_BATTLERS_FOLDER_INDEXED
      fusion = /\A#{Regexp.escape(prefix)}([1-9][0-9]{0,2})\/([1-9][0-9]{0,2}\.[1-9][0-9]{0,2}[A-Za-z_-]{0,12})\.png\z/.match(path.to_s)
      return "fusion:#{fusion[2]}" if fusion && fusion[2].split(".").first == fusion[1]
      check(false, "自定义文件不支持；只接受已安装的标准素材变体")
    end
    def self.asset_path(key, species)
      return nil unless key
      return "none" if key == "default"
      if key.start_with?("base:")
        stem = key.sub(/\Abase:/, "")
        check(GameData::Species.get(species).id_number == stem.to_i, "立绘素材与物种不一致")
        path = "Graphics/BaseSprites/#{stem}.png"
      else
        stem = key.sub(/\Afusion:/, "")
        ids = /\A([0-9]+)\.([0-9]+)/.match(stem)
        check(species == "B#{ids[2]}H#{ids[1]}", "融合立绘素材与组成不一致")
        path = Settings::CUSTOM_BATTLERS_FOLDER_INDEXED + "#{ids[1]}/#{stem}.png"
      end
      if !File.file?(path) && defined?(KIF::SpriteSheets)
        entry = KIF::SpriteIndex.parse_name(File.basename(path))
        if entry
          path = KIF::SpriteSheets.resolve(entry[:body] ? :custom : :base, entry[:head], entry[:body], entry[:alt], false) || path
        end
      end
      check(File.file?(path), "缺少已安装素材 #{key}，请先安装相同素材再交换")
      path
    end

    def self.export(original)
      # Only the clone resolves lazy ability/gender/nature/shiny values.
      pokemon = original.clone
      check(pokemon.instance_variable_get(:@forced_form).nil? || pokemon.instance_variable_get(:@forced_form) == 0, "强制形态暂不支持")
      %w[mail fused hat].each do |field|
        value = pokemon.instance_variable_get("@#{field}")
        check(value.nil? || value == "", "#{field} 暂不支持；请先移除邮件、饰帽或自定义文件")
      end
      allowed = CACHE_IVARS + BASE_IVARS + Snapshot::APPEARANCE_KEYS + REJECTED_IVARS + FIELDS.map { |key| IVARS[key] || key }
      pokemon.instance_variables.each do |variable|
        next if allowed.include?(variable.to_s.sub(/\A@/, ""))
        value = pokemon.instance_variable_get(variable)
        check(value.nil? || value == false || value == 0 || value == [], "未知个体字段 #{variable}，禁止静默丢失")
      end
      # Lazy primary resolution in DoubleAbilities also depends on the local
      # NO_LEVELS switch. Freeze the ordinary inherited ability on this private
      # clone, leaving the original's raw lazy fields untouched.
      pokemon.instance_variable_set(:@ability, natural_ability(pokemon)) unless pokemon.instance_variable_get(:@ability)
      data = Snapshot.export(pokemon)
      # DoubleAbilities getters hide an existing ability when the local switch
      # is disabled. A trade must preserve the stored individual in that case.
      second = pokemon.instance_variable_get(:@ability2)
      second_index = pokemon.instance_variable_get(:@ability2_index)
      data["ability2"] = second && second.to_s
      data["ability2_index"] = second_index
      values = {}
      FIELDS.each do |field|
        value = pokemon.instance_variable_get("@#{IVARS[field] || field}")
        value = asset_key(value) if %w[sprite_asset old_sprite_asset].include?(field)
        value = value.to_s if value.is_a?(Symbol)
        value = value.map { |id| id.to_s } if %w[first_moves ribbons].include?(field)
        value = !!value if field == "imported"
        values[field] = value
      end
      values["status"] ||= "NONE"
      values["status_count"] ||= 0
      result = { "version" => VERSION, "pokemon" => data, "preserved" => values }
      copy(validate(result))
    end

    def self.import(data)
      validate(data)
      snapshot = data["pokemon"]
      values = data["preserved"]
      pokemon = Snapshot.import(snapshot, snapshot["level"])
      FIELDS.each do |field|
        value = values[field]
        value = asset_path(value, snapshot["species"]) if %w[sprite_asset old_sprite_asset].include?(field)
        value = value.to_sym if value && %w[status poke_ball type1kuray type2kuray].include?(field)
        value = value.map(&:to_sym) if %w[first_moves ribbons].include?(field)
        value = value.dup if value.is_a?(String)
        pokemon.instance_variable_set("@#{IVARS[field] || field}", value)
      end
      pokemon.instance_variable_set(:@level, nil)
      pokemon.calc_stats
      check(pokemon.level == snapshot["level"] && pokemon.exp == values["exp"], "经验与等级不一致，或本地等级选项不兼容")
      check(values["hp"] <= pokemon.totalhp, "HP 超出能力值")
      pokemon.instance_variable_set(:@hp, values["hp"])
      pokemon.instance_variable_set(:@status, values["status"].to_sym)
      pokemon.instance_variable_set(:@statusCount, values["status_count"])
      snapshot["moves"].each_with_index do |move, index|
        check(move["pp"] <= pokemon.moves[index].total_pp, "招式 PP 超出本地上限")
        pokemon.moves[index].pp = move["pp"]
      end
      check(export(pokemon) == data, "本地导入不能完整保留约定字段，已阻止确认")
      pokemon
    end

    def self.digest(data)
      require "digest/sha2"
      # The server uses recursively sorted UTF-8 JSON keys without whitespace.
      canonical = lambda do |value|
        case value
        when Hash then value.keys.sort.each_with_object({}) { |key, hash| hash[key] = canonical.call(value[key]) }
        when Array then value.map { |item| canonical.call(item) }
        else value
        end
      end
      Digest::SHA256.hexdigest(WireJSON.dump(canonical.call(data)))
    end
  end

  # A trade save includes the full registered vanilla/modded SaveData values,
  # original escrow and applied transaction marker in the SAME atomic rename.
  # Game.save currently truncates its destination and is therefore unsuitable.
  class TradeSave
    def path
      raise Error, "请先选择并保存一个正式存档槽，再进行交换。" unless $Trainer && $Trainer.respond_to?(:save_slot) && $Trainer.save_slot
      File.expand_path(SaveData.get_full_path($Trainer.save_slot))
    end
    def persist
      destination = path
      temporary = destination + ".mp-trade-#{KIFMultiplayer.operation_id}.tmp"
      File.open(temporary, "wb") do |file|
        Marshal.dump(SaveData.compile_save_hash, file)
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
      true
    ensure
      File.delete(temporary) if temporary && File.file?(temporary)
    end
    def read_player
      data = SaveData.get_data_from_file(path)
      data[:kuray_player] || data[:player]
    end
  end

  class TradeSession
    attr_reader :client, :store
    def initialize(client, store = nil)
      @client, @store = client, store || TradeSave.new
    end
    def pending; @client.profile.account["trade_pending"]; end
    def escrow; $Trainer.instance_variable_get(:@kif_multiplayer_trade_escrow); end
    def applied; $Trainer.instance_variable_get(:@kif_multiplayer_trade_applied) || {}; end
    def active_path; File.expand_path(@store.path); end
    def change_profile(&block); LocalJournal.change(@client.profile, &block); end
    def escrow_proof(value)
      return nil unless value.is_a?(Hash) && value["entries"].is_a?(Array) && !value["entries"].empty?
      entries = value["entries"].map do |entry|
        return nil unless entry["pokemon"]
        # Both objects come from this user's trusted local save, never from
        # the network. Compare their raw state rather than calling a formatter
        # whose result can depend on later single-player options/registries.
        [entry.reject { |key, _| key == "pokemon" }, Digest::SHA256.hexdigest(Marshal.dump(entry["pokemon"]))]
      end
      value.reject { |key, _| %w[entries save_path stage].include?(key) }.merge("entries" => entries)
    end
    def matching_context?(value, record)
      value && %w[code server player_id save_id].all? { |key| value[key] == record[key] } && value["kind"] == record["kind"]
    end
    def migrate_binding(record)
      # A normal SaveAs copies this save lineage, escrow and markers. Prove
      # those values are durable in the NEW slot before changing only the
      # profile path. Never overwrite the old slot or regenerate its Pokemon.
      saved_player = @store.read_player
      save_id = saved_player && saved_player.instance_variable_get(:@kif_multiplayer_trade_save_id)
      durable_escrow = saved_player && saved_player.instance_variable_get(:@kif_multiplayer_trade_escrow)
      durable_markers = saved_player && saved_player.instance_variable_get(:@kif_multiplayer_trade_applied) || {}
      escrow_matches = matching_context?(escrow, record) && matching_context?(durable_escrow, record) &&
        escrow_proof(escrow) && escrow_proof(escrow) == escrow_proof(durable_escrow)
      marker_matches = !escrow && applied.any? do |transaction_id, marker|
        marker["code"] == record["code"] && marker["server"] == record["server"] &&
          marker["player_id"] == record["player_id"] && marker["kind"] == record["kind"] && durable_markers[transaction_id] == marker
      end
      unless save_id == record["save_id"] && (escrow_matches || marker_matches)
        raise Error.new("新存档尚未安全保存相同交换锁或领取标记。请先保存当前谱系，再恢复交换。", "trade_save_mismatch")
      end
      change_profile { pending["save_path"] = active_path }
    rescue IOError, SystemCallError, TypeError, ArgumentError
      raise Error.new("无法核实当前存档的持久交换记录，请先保存当前存档后重试。", "trade_save_mismatch")
    end
    def check_binding(record = pending)
      raise Error, "没有待恢复的本地交换。" unless record
      unless record["server"] == @client.server && record["player_id"] == @client.player_id
        raise Error.new("此交换属于其他服务器、身份或存档槽。请返回原身份与原存档恢复。", "trade_save_mismatch")
      end
      binding = $Trainer.instance_variable_get(:@kif_multiplayer_trade_save_id)
      raise Error.new("当前存档不是发起交换的存档，禁止自动复制领取。", "trade_save_mismatch") unless record["save_id"] == binding
      if escrow && !matching_context?(escrow, record)
        raise Error.new("存档内锁定个体属于另一笔交易，禁止混用。", "trade_save_mismatch")
      end
      migrate_binding(record) unless record["save_path"] == active_path
      true
    end
    def create
      raise Error, "请先恢复或取消现有交换。" if pending || escrow
      @client.request("POST", "/v1/trades", { "compatibility" => @client.compatibility, "source" => "local_casual" })["trade"]
    end
    def join(code)
      raise Error, "请先恢复或取消现有交换。" if pending || escrow
      @client.request("POST", "/v1/trades/#{safe_code(code)}/join", { "compatibility" => @client.compatibility })["trade"]
    end
    def safe_code(code)
      raise Error, "交换码格式无效。" unless code.is_a?(String) && code =~ /\A[A-Z0-9]{4,16}\z/
      code
    end
    def get(code)
      @client.request("GET", "/v1/trades/#{safe_code(code)}")["trade"]
    end
    def list
      @client.request("GET", "/v1/trades")["trades"]
    end
    def location_of(pokemon)
      $Trainer.party.each_with_index { |item, i| return ["party", i] if item.equal?(pokemon) }
      if defined?($PokemonStorage) && $PokemonStorage
        $PokemonStorage.maxBoxes.times do |box|
          $PokemonStorage.maxPokemon(box).times { |slot| return ["box", box, slot] if $PokemonStorage[box, slot].equal?(pokemon) }
        end
      end
      raise Error, "精灵已不在当前队伍或电脑中，请重新选择。"
    end
    def remove_at(location)
      if location[0] == "party"
        $Trainer.party.delete_at(location[1])
      else
        pokemon = $PokemonStorage[location[1], location[2]]
        $PokemonStorage[location[1], location[2]] = nil
        pokemon
      end
    end
    def insert(pokemon, preferred)
      if preferred[0] == "party" && $Trainer.party.length < 6
        $Trainer.party.insert([preferred[1], $Trainer.party.length].min, pokemon)
        return
      elsif preferred[0] == "box" && !$PokemonStorage[preferred[1], preferred[2]]
        $PokemonStorage[preferred[1], preferred[2]] = pokemon
        return
      end
      if $Trainer.party.length < 6
        $Trainer.party << pokemon
        return
      end
      if defined?($PokemonStorage) && $PokemonStorage
        $PokemonStorage.maxBoxes.times do |box|
          $PokemonStorage.maxPokemon(box).times do |slot|
            next if $PokemonStorage[box, slot]
            $PokemonStorage[box, slot] = pokemon
            return
          end
        end
      end
      raise Error.new("队伍与电脑已满。请先腾出位置再恢复领取；原个体仍安全锁定。", "trade_storage_full")
    end

    def mutate_save
      old_party = $Trainer.party.dup
      old_boxes = []
      if defined?($PokemonStorage) && $PokemonStorage
        $PokemonStorage.maxBoxes.times do |box|
          old_boxes[box] = (0...$PokemonStorage.maxPokemon(box)).map { |slot| $PokemonStorage[box, slot] }
        end
      end
      old_escrow, old_applied = escrow, applied
      begin
        yield
        raise Error, "交换存档写入失败。" unless @store.persist
      rescue StandardError
        $Trainer.party.replace(old_party)
        old_boxes.each_with_index { |slots, box| slots.each_with_index { |pokemon, slot| $PokemonStorage[box, slot] = pokemon } }
        $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, old_escrow)
        $Trainer.instance_variable_set(:@kif_multiplayer_trade_applied, old_applied)
        raise
      end
      true
    end

    def offer(code, pokemon)
      code = safe_code(code)
      @client.recover_pending
      trade = get(code)
      raise Error, "此交易已经提交或结束，不能再报价。" unless %w[waiting offering].include?(trade["status"])
      snapshot = TradeCodec.export(pokemon)
      TradeCodec.import(snapshot) # all local identifiers and lossless conversion before escrow
      location = location_of(pokemon)
      if location[0] == "party" && !pokemon.egg? && pokemon.hp > 0
        usable = $Trainer.party.count { |entry| !entry.egg? && entry.hp > 0 }
        raise Error, "请至少保留一只可战斗精灵。可从电脑选择报价。" if usable <= 1
      end
      if pending
        check_binding
        raise Error, "请先恢复原来的交换。" unless pending["code"] == code
      elsif escrow
        raise Error, "存档内有其他待处理交换。请使用原身份与服务器恢复。"
      end
      save_id = $Trainer.instance_variable_get(:@kif_multiplayer_trade_save_id) || KIFMultiplayer.operation_id
      $Trainer.instance_variable_set(:@kif_multiplayer_trade_save_id, save_id)
      offer_id, request_id = KIFMultiplayer.operation_id, KIFMultiplayer.operation_id
      record = pending || { "code" => code, "server" => @client.server, "player_id" => @client.player_id,
        "save_path" => active_path, "save_id" => save_id }
      change_profile { @client.profile.account["trade_pending"] = record.merge("stage" => "preparing", "offer_id" => offer_id, "request_id" => request_id) }
      entry = { "pokemon" => pokemon, "snapshot" => snapshot, "hash" => TradeCodec.digest(snapshot), "location" => location, "offer_id" => offer_id, "request_id" => request_id, "codec_version" => 2 }
      old_entries = escrow ? escrow["entries"] : []
      mutate_save do
        remove_at(location)
        $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, record.merge("entries" => old_entries + [entry]))
      end
      change_profile { pending["stage"] = "locked" }
      result = submit_offer(code, entry)
      reconcile(result)
    end
    def submit_offer(code, entry)
      raise Error, "锁定个体内容发生变化，禁止报价。" unless TradeCodec.entry_matches?(entry)
      request_id = entry["request_id"] || pending["request_id"]
      unless request_id
        request_id = KIFMultiplayer.operation_id
        change_profile { pending["request_id"] = request_id }
      end
      @client.request("POST", "/v1/trades/#{safe_code(code)}/offer", { "snapshot" => entry["snapshot"], "offer_id" => entry["offer_id"], "request_id" => request_id })["trade"]
    end

    def confirmations(trade)
      offers = trade["offers"] || {}
      raise Error, "双方都需要先报价。" unless offers.length == 2
      offers.each_value { |offer| TradeCodec.import(offer["snapshot"]) }
      offers.each_with_object({}) { |(owner, offer), hashes| hashes[owner] = offer["hash"] }
    end
    def confirm(trade)
      check_binding
      raise Error, "请先恢复当前交换状态。" unless trade["code"] == pending["code"]
      hashes = confirmations(trade)
      own = trade["offers"][@client.player_id]
      locked = escrow && escrow["entries"].find { |entry| entry["offer_id"] == own["offer_id"] && entry["snapshot"] == own["snapshot"] }
      unless locked && TradeCodec.entry_matches?(locked)
        raise Error, "当前报价缺少完整锁定原个体，已阻止确认。请恢复交换。"
      end
      @client.request("POST", "/v1/trades/#{safe_code(trade['code'])}/confirm", { "revision" => trade["revision"], "offer_hashes" => hashes })["trade"].tap { |result| reconcile(result) }
    end
    def cancel(code)
      @client.recover_pending
      trade = get(code)
      # Query first: lack of a prior response never means the commit failed.
      return reconcile(trade) if %w[committed completed].include?(trade["status"])
      unless %w[cancelled expired].include?(trade["status"])
        begin
          trade = @client.request("POST", "/v1/trades/#{safe_code(code)}/cancel")["trade"]
        rescue Error => error
          raise unless error.code == "trade_closed"
          trade = get(code)
        end
      end
      reconcile(trade)
    end
    def recover
      @client.recover_pending
      # The trusted save escrow also recovers a lost/older profile journal.
      if !pending && escrow
        record = escrow.reject { |key, _value| key == "entries" }
        change_profile { @client.profile.account["trade_pending"] = record }
      end
      if !pending && !applied.empty?
        # If a profile journal was removed after the atomic save but before ack,
        # the saved applied marker can still finish the original receipt. No
        # Pokemon is generated from a mere server record without this marker.
        interrupted = list.find do |trade|
          marker = applied[trade["transaction_id"]]
          marker && marker["code"] == trade["code"] && marker["server"] == @client.server &&
            marker["player_id"] == @client.player_id && !(trade["acked"] || []).include?(@client.player_id)
        end
        if interrupted
          change_profile { @client.profile.account["trade_pending"] = { "code" => interrupted["code"], "server" => @client.server,
            "player_id" => @client.player_id, "save_path" => active_path,
            "save_id" => $Trainer.instance_variable_get(:@kif_multiplayer_trade_save_id), "stage" => "applied" } }
        end
      end
      return nil unless pending
      # A crash (or disk error) before the first rename leaves only a preparing
      # profile journal. It cannot have uploaded an offer, since offer follows
      # the durable escrow save. Check the service before discarding that case.
      if !escrow && pending["stage"] == "preparing" && pending["server"] == @client.server && pending["player_id"] == @client.player_id && pending["save_path"] == active_path
        trade = get(pending["code"])
        unless (trade["offers"] || {}).key?(@client.player_id)
          clear_local_journal
          return trade
        end
      end
      check_binding
      reconcile(get(pending["code"]))
    end

    def clear_local_journal
      change_profile { @client.profile.account.delete("trade_pending") }
    end
    def reconcile(trade)
      return trade unless pending
      check_binding
      raise Error, "收到其他交换结果，已阻止领取。" unless trade["code"] == pending["code"]
      case trade["status"]
      when "cancelled", "expired"
        release_all
        clear_local_journal
      when "committed", "completed"
        receive(trade)
      when "waiting", "offering"
        own = (trade["offers"] || {})[@client.player_id]
        if escrow && own
          kept = escrow["entries"].find { |entry| entry["offer_id"] == own["offer_id"] && entry["snapshot"] == own["snapshot"] }
          raise Error, "报价与本地锁定个体不一致，已停止交换。" unless kept
          extras = escrow["entries"] - [kept]
          unless extras.empty?
            mutate_save do
              extras.each { |entry| insert(entry["pokemon"], entry["location"]) }
              $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, escrow.merge("entries" => [kept]))
            end
          end
        elsif escrow && !own
          entry = escrow["entries"].find { |item| item["offer_id"] == pending["offer_id"] } || escrow["entries"].last
          return reconcile(submit_offer(trade["code"], entry))
        elsif !escrow && !own
          # Crash before the first durable save: nothing was offered remotely.
          clear_local_journal
        elsif own && !escrow
          raise Error, "服务器存在报价但当前存档缺少锁定个体。请恢复原存档，不会从网络自动复制原个体。"
        end
      else
        raise Error, "未知交换状态。请更新客户端后恢复。"
      end
      trade
    end
    def release_all
      return unless escrow
      entries = escrow["entries"]
      mutate_save do
        entries.each { |entry| insert(entry["pokemon"], entry["location"]) }
        $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, nil)
      end
    end
    def receive(trade)
      receipt = trade["receipt"]
      raise Error, "服务器未提供本身份的交易凭据。" unless receipt.is_a?(Hash) && receipt["source"] == "local_casual"
      transaction_id = receipt["transaction_id"]
      raise Error, "交易编号无效。" unless transaction_id.is_a?(String) && transaction_id =~ /\A[A-Za-z0-9_-]{1,100}\z/ && transaction_id == trade["transaction_id"]
      received = receipt["snapshot"] || receipt["received_snapshot"]
      offers = trade["offers"] || {}
      other_id = (offers.keys - [@client.player_id]).first
      other = offers[other_id]
      unless offers.length == 2 && receipt["owner_id"] == @client.player_id && other &&
             received == other["snapshot"] && receipt["received_hash"] == other["hash"]
        raise Error, "交易凭据与对方锁定报价或领取身份不一致，已阻止领取。"
      end
      incoming_hash = TradeCodec.digest(received)
      if applied.key?(transaction_id)
        marker = applied[transaction_id]
        unless marker["code"] == trade["code"] && marker["server"] == @client.server && marker["player_id"] == @client.player_id && marker["received_hash"] == incoming_hash && marker["offered_hash"] == receipt["offered_hash"]
          raise Error, "已领取交易的内容不一致，禁止重复应用。"
        end
      else
        pokemon = TradeCodec.import(received)
        raise Error, "当前存档缺少待交换个体。请加载原存档恢复。" unless escrow
        entries = escrow["entries"]
        own = (trade["offers"] || {})[@client.player_id]
        outgoing = own && entries.find { |entry| entry["offer_id"] == own["offer_id"] && entry["snapshot"] == own["snapshot"] && own["hash"] == receipt["offered_hash"] }
        raise Error, "交易凭据与锁定个体不一致。" unless outgoing
        # Validate escrow before replacing anything, including on restart.
        raise Error, "锁定个体内容发生变化，禁止交换。" unless TradeCodec.entry_matches?(outgoing)
        mutate_save do
          (entries - [outgoing]).each { |entry| insert(entry["pokemon"], entry["location"]) }
          insert(pokemon, outgoing["location"])
          markers = applied.dup
          markers[transaction_id] = { "code" => trade["code"], "server" => @client.server, "player_id" => @client.player_id,
            "offered_hash" => receipt["offered_hash"], "received_hash" => incoming_hash }
          $Trainer.instance_variable_set(:@kif_multiplayer_trade_applied, markers)
          $Trainer.instance_variable_set(:@kif_multiplayer_trade_escrow, nil)
        end
      end
      # An ack is sent ONLY after the durable save contains the received Pokemon
      # AND its applied marker. A lost ack response safely repeats this branch.
      change_profile { pending["stage"] = "applied" }
      @client.request("POST", "/v1/trades/#{safe_code(trade['code'])}/ack", { "transaction_id" => transaction_id })
      clear_local_journal
      trade
    end
  end

  def self.open_trade_menu(client)
    TradeUI.new(client).main
  end
  class TradeUI
    def initialize(client)
      @client, @ui, @session = client, UI.new(client), TradeSession.new(client)
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def main
      @ui.perform { @session.recover }
      loop do
        command = @ui.choose("好友休闲交换\n来源：本地存档。备份、导入与回滚仍可能复制个体。\n报价精灵会安全存档并锁定，提交后必须恢复领取。", ["创建交换", "输入交换码", "恢复待处理交换", "我的交换会话", "返回"])
        return if command < 0 || command == 4
        @ui.perform do
          case command
          when 0 then trade_menu(@session.create)
          when 1
            code = @ui.enter("输入交换码", "", 16).upcase
            trade_menu(@session.join(code)) unless code.empty?
          when 2
            trade = @session.recover
            raise Error, "当前没有待处理的本地交换。" unless trade
            trade_menu(trade)
          when 3
            trades = @session.list
            raise Error, "没有交换会话。" if trades.empty?
            selected = @ui.choose("我的交换会话", trades.map { |trade| "#{text(trade['code'])} #{text(trade['status'])}" } + ["返回"])
            trade_menu(trades[selected]) if selected >= 0 && selected < trades.length
          end
        end
      end
    end
    def trade_menu(trade)
      code = trade["code"]
      loop do
        command = @ui.choose("交换码 #{text(code)} · #{text(trade['status'])}\n报价版本 #{trade['revision'].to_i}\n#{(trade['confirmations'] || []).length} / 2 已确认", ["刷新与恢复领取", "选择 / 更换报价精灵", "查看双方完整报价", "确认当前两份报价", "取消本次交换", "返回（保留待处理记录）"])
        return if command < 0 || command == 5
        @ui.perform do
          case command
          when 0 then trade = @session.pending ? @session.recover : @session.get(code)
          when 1
            pokemon = @ui.choose_pokemon
            if pokemon && pbConfirmMessage("将安全保存当前游戏，并锁定 #{text(pokemon.name)}。\n在取消或领取之前不能使用该精灵。继续？")
              trade = @session.offer(code, pokemon)
            end
          when 2 then inspect_offers(trade)
          when 3
            @session.confirmations(trade)
            inspect_offers(trade)
            if pbConfirmMessage("确认当前报价版本 #{trade['revision']}？双方确认后不可撤销。\n来源：本地休闲，不能保证无复制。")
              trade = @session.confirm(trade)
              pbMessage(%w[committed completed].include?(trade["status"]) ? "交换已提交，收到的个体和交易标记已经安全保存。" : "已确认；请刷新等待另一方确认。")
            end
          when 4
            trade = @session.cancel(code) if pbConfirmMessage("取消尚未提交的交换？已提交时将恢复领取。")
          end
        end
      end
    end
    def inspect_offers(trade)
      offers = trade["offers"] || {}
      raise Error, "尚无报价。" if offers.empty?
      offers.each do |owner, offer|
        snapshot = TradeCodec.validate(offer["snapshot"])
        data, preserved = snapshot["pokemon"], snapshot["preserved"]
        lines = [owner == @client.player_id ? "你的报价（本地休闲）" : "对方报价（本地休闲）",
          "#{text(data['name'])} · #{text(data['species'])} Lv.#{data['level']} · 性别 #{data['gender']} · 形态 #{data['form']}",
          "特性 #{text(data['ability'])} / #{text(data['ability2'])} · 性格 #{text(data['nature'])} / 修正 #{text(data['nature_for_stats'])}",
          "携带 #{text(data['item'])} · OT #{text(data['owner']['name'])} / #{data['owner']['id']}",
          "招式 " + data["moves"].map { |move| "#{text(move['id'])} PP #{move['pp']} / PPUp #{move['ppup']}" }.join("，"),
          "IV #{text(WireJSON.dump(data['iv']))}", "EV #{text(WireJSON.dump(data['ev']))}",
          "闪光 #{data['shiny']} · HP #{preserved['hp']} · #{text(preserved['status'])}"]
        pbMessage(lines.join("\n"))
        pbMessage("完整外观与个体保留资料：\n#{text(WireJSON.dump(data['appearance']))}\n#{text(WireJSON.dump(preserved))}")
      end
    end
  end
end

# Identity credentials alone must never carry a different player's saved escrow
# to a second server. The profile check is supplemented by the trusted save, so
# deleting a profile journal cannot remove this lock.
class << KIFMultiplayer
  attr_accessor :identity_change_guard unless method_defined?(:identity_change_guard)
end
previous_trade_identity_guard = KIFMultiplayer.identity_change_guard
KIFMultiplayer.identity_change_guard = lambda do |profile|
  previous_trade_identity_guard.call(profile) if previous_trade_identity_guard
  if KIFMultiplayer.trade_identity_locked?(profile)
    raise KIFMultiplayer::Error.new("当前存档或身份存在未完成交换。请先恢复或取消，才能更换服务器或身份。", "trade_identity_locked")
  end
end
