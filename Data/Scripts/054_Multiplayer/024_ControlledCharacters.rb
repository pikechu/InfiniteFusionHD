# Server-owned assets are separate from local story saves and imported Pokemon.
module KIFMultiplayer
  class ControlledClient
    attr_reader :catalog, :characters, :client
    def initialize(client = KIFMultiplayer.client)
      @client = client
    end
    def integer?(value, low, high); value.is_a?(Integer) && value.between?(low, high); end
    def refresh
      pending = @client.profile.account["pending"]
      @client.recover_pending if pending && pending["path"].to_s.start_with?("/v1/controlled/")
      @catalog = @client.request("GET", "/v1/controlled/catalog")["catalog"]
      raise Error, "受控角色目录不兼容。" unless @catalog.is_a?(Hash) && @catalog["version"] == 1 && @catalog["rules"] == "controlled-assets-v1" && @catalog["hash"].to_s =~ /\A[a-f0-9]{64}\z/
      raise Error, "受控角色数量上限无效。" unless integer?(@catalog["max_characters"], 1, 10)
      items = @catalog["items"]
      raise Error, "受控道具目录无效。" unless items.is_a?(Array) && items.length.between?(1, 100) && items.all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) && item["id"] =~ /\A[A-Z0-9_]{1,64}\z/ && item["name"].is_a?(String) && item["name"].length.between?(1, 80) && integer?(item["buy_price"], 1, 1_000_000_000) && integer?(item["sell_price"], 0, item["buy_price"]) && integer?(item["max_stack"], 1, 999) }
      raise Error, "受控道具目录重复。" unless items.map { |item| item["id"] }.uniq.length == items.length
      @characters = @client.request("GET", "/v1/controlled/characters")["characters"]
      raise Error, "受控角色列表无效。" unless @characters.is_a?(Array) && @characters.length <= @catalog["max_characters"]
      @characters.each { |character| validate(character) }
      raise Error, "受控角色编号重复。" unless @characters.map { |character| character["id"] }.uniq.length == @characters.length
      self
    end
    def validate(character)
      raise Error, "受控角色响应无效。" unless character.is_a?(Hash) && character["id"].to_s =~ /\Acc_[a-f0-9]{32}\z/ && character["owner"] == @client.player_id && character["source"] == "server_managed" && character["name"].is_a?(String) && character["name"].length.between?(1, 20) && character["status"] == "active" && integer?(character["revision"], 1, 9_007_199_254_740_991)
      wallet = character["wallet"]
      raise Error, "受控金币响应无效。" unless wallet.is_a?(Hash) && wallet["currency"] == "GOLD" && integer?(wallet["balance"], 0, 1_000_000_000) && integer?(wallet["revision"], 0, 9_007_199_254_740_991)
      inventory = character["inventory"]
      if character["rules_mode"] == "original"
        raise Error, "原版规则标识无效。" unless character["rules_hash"].to_s =~ /\A[a-f0-9]{64}\z/
        raise Error, "原版背包响应无效。" unless inventory.is_a?(Array) && inventory.length <= 1024 && inventory.all? { |row| row.is_a?(Hash) && row["item"].to_s =~ /\A[A-Z0-9_]{1,64}\z/ && integer?(row["quantity"], 1, 9_007_199_254_740_991) }
        raise Error, "原版背包道具重复。" unless inventory.map { |row| row["item"] }.uniq.length == inventory.length
        return character
      end
      raise Error, "未知的受控角色规则。" unless character["rules_mode"].nil? || character["rules_mode"] == "v1"
      raise Error, "受控背包响应无效。" unless inventory.is_a?(Array) && inventory.length <= @catalog["items"].length
      inventory.each do |row|
        item = row.is_a?(Hash) && @catalog["items"].find { |entry| entry["id"] == row["item"] }
        raise Error, "受控背包道具无效。" unless item && integer?(row["quantity"], 1, item["max_stack"])
      end
      raise Error, "受控背包道具重复。" unless inventory.map { |row| row["item"] }.uniq.length == inventory.length
      character
    end
    def character(id)
      raise Error, "受控角色编号无效。" unless id.is_a?(String) && id =~ /\Acc_[a-f0-9]{32}\z/
      validate(@client.request("GET", "/v1/controlled/characters/#{id}")["character"])
    end
    def create(name)
      raise Error, "请先刷新受控角色。" unless @catalog
      raise Error, "角色名无效。" unless name.is_a?(String) && name.length.between?(1, 20)
      result = @client.request("POST", "/v1/controlled/characters", {"name" => name, "catalog_hash" => @catalog["hash"]})
      created = validate(result["character"])
      refresh
      created
    end
    def daily(character)
      validate(character)
      result = @client.request("POST", "/v1/controlled/characters/#{character['id']}/daily", {"expected_revision" => character["revision"]})
      raise Error, "签到回执无效。" unless integer?(result["reward_amount"], 0, 1000)
      validate(result["character"])
      result["reward_amount"]
    end
    def trade(character, action, item, quantity)
      validate(character)
      raise Error, "受控商店操作无效。" unless %w[buy sell].include?(action) && @catalog["items"].include?(item) && integer?(quantity, 1, item["max_stack"])
      result = @client.request("POST", "/v1/controlled/characters/#{character['id']}/#{action}",
                              {"expected_revision" => character["revision"], "expected_wallet_revision" => character["wallet"]["revision"],
                               "catalog_hash" => @catalog["hash"], "item" => item["id"], "quantity" => quantity,
                               "expected_unit_price" => item[action == "buy" ? "buy_price" : "sell_price"]})
      validate(result["character"])
      # A receipt can describe an earlier committed revision after recovery.
      # Read the latest server state instead of copying a balance into a save.
      self.character(character["id"])
    end
  end

  class ControlledUI < UI
    def initialize(client = KIFMultiplayer.client)
      super(client)
      @controlled = ControlledClient.new(client)
    end
    def main
      loop do
        return unless perform { @controlled.refresh }
        characters = @controlled.characters
        choices = characters.map { |character| "#{text(character['name'])} · GOLD #{character['wallet']['balance']}" } + ["新建受控角色", "返回"]
        index = choose("受控在线角色\n独立金币和背包，旧存档资产不导入。", choices)
        break unless index.is_a?(Integer) && index.between?(0, characters.length)
        if index == characters.length
          next unless pbConfirmMessage("受控角色与旧存档分开。初始金币每账号一次，主线战斗、捕获与培养由服务器结算，使用受控规则。是否创建？")
          name = enter("受控角色名称", @client.identity && @client.identity["nickname"].to_s[0, 20], 20)
          perform { @controlled.create(name) } unless name.empty?
        else
          character_menu(characters[index]["id"])
        end
      end
    end
    def character_menu(id)
      OriginalUI.new(@client).main(id)
    end
  end

  def self.open_controlled_characters
    previous_scene = $scene
    $scene = Object.new
    with_ui_fonts { ControlledUI.new.main }
  rescue Error => error
    pbMessage("受控角色：#{display_text(error.message)}")
  rescue StandardError => error
    KIFMultiplayer.log_error(error)
    pbMessage("受控角色暂时不可用，请查看联机日志。")
  ensure
    $scene = previous_scene
  end

  module ControlledPauseEntry
    def pbShowCommands(commands)
      return super unless defined?(OnlineMode) && OnlineMode.active?
      choices = commands + ["受控在线角色"]
      loop do
        result = super(choices)
        return result unless result == commands.length
        pbHideMenu
        KIFMultiplayer.open_controlled_characters
        pbShowMenu
      end
    end
  end
  PokemonPauseMenu_Scene.prepend(ControlledPauseEntry) if defined?(PokemonPauseMenu_Scene)
end
