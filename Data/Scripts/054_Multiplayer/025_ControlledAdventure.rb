# This controller submits intents and renders server state. It never runs the
# legacy battle engine, imports a local Pokemon, or writes a legacy save asset.
module KIFMultiplayer
  class ControlledAdventureClient
    attr_reader :catalog, :state, :character, :last_result
    def initialize(client, character_id)
      @client, @id = client, character_id
      @assets = ControlledClient.new(client)
    end
    def integer?(value, low, high); value.is_a?(Integer) && value.between?(low, high); end
    def refresh
      @assets.refresh
      @catalog = @client.request("GET", "/v1/controlled/adventure-catalog")["catalog"]
      raise Error, "受控主线目录不兼容。" unless @catalog.is_a?(Hash) && @catalog["rules"] == "controlled-adventure-v1" && @catalog["hash"].to_s =~ /\A[a-f0-9]{64}\z/
      raise Error, "受控主线招式目录无效。" unless @catalog["moves"].is_a?(Hash) && @catalog["moves"].length.between?(1, 1000)
      @catalog["moves"].each do |id, move|
        raise Error, "受控主线招式无效。" unless id =~ /\A[A-Z0-9_]{1,64}\z/ && move.is_a?(Hash) && integer?(move["total_pp"], 1, 100) && integer?(move["base_damage"], 0, 1000)
      end
      raise Error, "受控章节或区域目录无效。" unless @catalog["stages"].is_a?(Array) && @catalog["stages"].length.between?(1, 100) && @catalog["regions"].is_a?(Array) && @catalog["regions"].length.between?(1, 500)
      accept(@client.request("GET", "/v1/controlled/characters/#{@id}/adventure"))
      self
    end
    def accept(result)
      @character = @assets.validate(result["character"])
      raise Error, "受控角色响应串号。" unless @character["id"] == @id
      @state = result["adventure"]
      raise Error, "受控主线状态无效。" unless @state.is_a?(Hash) && @state["progress"].is_a?(Hash) && integer?(@state["progress"]["chapter"], 0, @catalog["stages"].length) && @state["monsters"].is_a?(Array) && @state["monsters"].length <= 180
      ids = @state["monsters"].map { |monster| validate_monster(monster); monster["id"] }
      party = @state["progress"]["party"]
      raise Error, "受控队伍无效。" unless ids.uniq.length == ids.length && party.is_a?(Array) && party.length <= 6 && party.uniq.length == party.length && party.all? { |id| ids.include?(id) }
      if @state["battle"]
        battle = @state["battle"]
        raise Error, "服务端战斗状态无效。" unless battle.is_a?(Hash) && battle["id"].to_s =~ /\Acb_[a-f0-9]{32}\z/ && integer?(battle["round"], 0, 100) && battle["status"] == "active" && battle["catalog_hash"].to_s =~ /\A[a-f0-9]{64}\z/ && !battle.key?("random_key")
        raise Error, "服务端战斗队伍无效。" unless battle["party"].is_a?(Array) && battle["party"].length.between?(1, 6) && battle["enemies"].is_a?(Array) && battle["enemies"].length.between?(1, 6) && integer?(battle["active"], 0, battle["party"].length - 1) && integer?(battle["enemy_active"], 0, battle["enemies"].length - 1)
      end
      result
    end
    def validate_monster(monster)
      raise Error, "服务端精灵资料无效。" unless monster.is_a?(Hash) && monster["id"].to_s =~ /\Acm_[a-f0-9]{32}\z/ && monster["species"].to_s =~ /\A[A-Z0-9_]{1,64}\z/ && integer?(monster["level"], 1, 100) && monster["stats"].is_a?(Hash) && integer?(monster["stats"]["HP"], 1, 10000) && integer?(monster["hp"], 0, monster["stats"]["HP"]) && [true, false].include?(monster["egg"])
      stats = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED]
      raise Error, "服务端努力值无效。" unless monster["ev"].is_a?(Hash) && monster["ev"].keys.sort == stats.sort && monster["ev"].values.all? { |value| integer?(value, 0, 252) } && monster["ev"].values.inject(0, :+) <= 510
      raise Error, "服务端个体值无效。" unless monster["iv"].is_a?(Hash) && monster["iv"].keys.sort == stats.sort && monster["iv"].values.all? { |value| integer?(value, 0, 31) }
      raise Error, "服务端招式资料无效。" unless monster["moves"].is_a?(Array) && monster["moves"].length <= 4 && monster["moves"].all? { |entry| entry.is_a?(Hash) && @catalog["moves"].key?(entry["id"]) && integer?(entry["pp"], 0, @catalog["moves"][entry["id"]]["total_pp"]) }
      monster
    end
    def act(action, fields = {})
      raise Error, "请先刷新受控主线。" unless @character && @state
      rules = action == "turn" && @state["battle"] ? @state["battle"]["catalog_hash"] : @catalog["hash"]
      result = @client.request("POST", "/v1/controlled/characters/#{@id}/adventure", fields.merge(
        "action" => action, "expected_revision" => @character["revision"], "expected_wallet_revision" => @character["wallet"]["revision"], "rules_hash" => rules))
      accept(result)
      @last_result = result
      refresh
      result
    end
    def turn(command)
      battle = @state["battle"]
      raise Error, "没有进行中的受控战斗。" unless battle
      act("turn", {"battle_id" => battle["id"], "expected_round" => battle["round"], "command" => command})
    end
  end

  class ControlledAdventureUI < UI
    def finish_historical(id)
      @model = ControlledAdventureClient.new(@client, id)
      return unless perform { @model.refresh }
      battle_menu if @model.state["battle"]
    end
    STATS = {"HP" => "体力", "ATTACK" => "攻击", "DEFENSE" => "防御", "SPECIAL_ATTACK" => "特攻", "SPECIAL_DEFENSE" => "特防", "SPEED" => "速度"}
    def main(id)
      @model = ControlledAdventureClient.new(@client, id)
      loop do
        return unless perform { @model.refresh }
        if @model.state["battle"]
          battle_menu
          return if @leave_active
          next
        end
        unless @model.state["progress"]["starter_claimed"]
          starters = @model.catalog["starters"]
          choice = choose("选择服务端初始精灵\n特性、携带物与天气关闭；仅公布招式可用，旧存档不导入。", starters.map { |species| species_name(species) } + ["返回"])
          return unless choice.is_a?(Integer) && choice.between?(0, starters.length - 1)
          perform { @model.act("starter", {"species" => starters[choice]}) }
          next
        end
        chapter = @model.state["progress"]["chapter"]
        title = chapter < @model.catalog["stages"].length ? "下一章：#{text(@model.catalog['stages'][chapter]['name'])}" : "受控主线已通关"
        choice = choose("#{title}\n等级上限 #{@model.state['level_cap']} · GOLD #{@model.character['wallet']['balance']}", ["挑战下一章节", "野外遭遇与捕获", "队伍与精灵", "培养中心", "精灵中心免费恢复", "规则说明", "返回"])
        case choice
        when 0
          stage = @model.catalog["stages"][chapter]
          if stage && pbConfirmMessage("挑战 #{text(stage['name'])}？\n首次完整战胜奖励 #{stage['gold']} GOLD；结果由服务器裁定。")
            perform { @model.act("start", {"kind" => "trainer", "entry" => stage["id"]}) }
          end
        when 1
          regions = @model.catalog["regions"].select { |row| row["min_level"] <= @model.state["level_cap"] }
          index = choose("选择已解锁的野外区域", regions.map { |row| "#{text(row['name'])} · Lv.#{row['min_level']} 起" } + ["返回"])
          perform { @model.act("start", {"kind" => "wild", "entry" => regions[index]["id"]}) } if index.is_a?(Integer) && index.between?(0, regions.length - 1)
        when 2; creature_menu
        when 3; cultivate_menu
        when 4; perform { @model.act("heal") }
        when 5
          pbMessage("受控主线规则 v1：服务器保存 HP、PP、经验与所有权。开启属性、状态、换人、道具和捕获；关闭特性、携带物、天气与未发布招式。剧情按已安装训练师目录的章节推进，原主线剧情继续独立运行。")
        else; return
        end
      end
    end
    def species_name(species)
      return text(GameData::Species.get(species.to_sym).name) if defined?(GameData::Species) && GameData::Species.exists?(species.to_sym)
      text(species)
    end
    def select_monster(title, rows = @model.state["monsters"].reject { |row| row["egg"] })
      return nil if rows.empty?
      index = choose(title, rows.map { |row| "#{text(row['name'])} Lv.#{row['level']} #{ {'male' => '♂', 'female' => '♀', 'none' => '无性别'}[row['gender']] } HP #{row['hp']}/#{row['stats']['HP']}#{row['egg'] ? '（蛋）' : ''}" } + ["返回"])
      index.is_a?(Integer) && index.between?(0, rows.length - 1) ? rows[index] : nil
    end
    def creature_menu
      monster = select_monster("受控精灵与队伍", @model.state["monsters"])
      return unless monster
      return pbMessage("这是一枚受控蛋，请在培养中心等待孵化。") if monster["egg"]
      choice = choose("#{text(monster['name'])}\n编号 #{monster['id']}\n经验 #{monster['exp']} · 状态 #{text(monster['status'])}\n努力值 #{text(STATS.map { |key, label| "#{label}#{monster['ev'][key]}" }.join(' '))}", ["设为队首 / 加入队伍", "移出队伍", "查看招式", "放生", "返回"])
      party = @model.state["progress"]["party"].dup
      case choice
      when 0
        party.delete(monster["id"])
        party.unshift(monster["id"])
        perform { @model.act("party", {"party" => party[0, 6]}) }
      when 1
        party.delete(monster["id"])
        perform { @model.act("party", {"party" => party}) }
      when 2
        pbMessage(monster["moves"].map { |move| "#{text(@model.catalog['moves'][move['id']]['real_name'])} PP #{move['pp']}" }.join("\n"))
      when 3
        perform { @model.act("release", {"monster_id" => monster["id"]}) } if pbConfirmMessage("永久放生 #{text(monster['name'])}？此操作不能撤销。")
      end
    end
    def battle_menu
      @leave_active = false
      loop do
        battle = @model.state["battle"]
        return unless battle
        active, enemy = battle["party"][battle["active"]], battle["enemies"][battle["enemy_active"]]
        choice = choose("服务端回合 #{battle['round'] + 1}\n#{text(active['name'])} HP #{active['hp']}/#{active['max_hp']}\n对手 #{text(enemy['name'])} Lv.#{enemy['level']} HP #{enemy['hp']}/#{enemy['max_hp']}", ["招式", "换人", "药品", "精灵球", "逃离 / 放弃", "稍后继续"])
        command = nil
        case choice
        when 0
          moves = active["moves"].each_with_index.select { |move, _| move["pp"] > 0 }
          if moves.empty?
            command = {"kind" => "move", "slot" => -1}
          else
            index = choose("选择招式", moves.map { |move, _| "#{text(@model.catalog['moves'][move['id']]['real_name'])} PP #{move['pp']}" } + ["返回"])
            command = {"kind" => "move", "slot" => moves[index][1]} if index.is_a?(Integer) && index.between?(0, moves.length - 1)
          end
        when 1
          rows = @model.state["monsters"].select { |row| @model.state["progress"]["party"].include?(row["id"]) && row["hp"] > 0 && row["id"] != active["id"] }
          target = select_monster("换上哪只精灵？", rows)
          command = {"kind" => "switch", "monster_id" => target["id"]} if target
        when 2
          rows = @model.state["monsters"].select { |row| @model.state["progress"]["party"].include?(row["id"]) && row["hp"] > 0 && row["hp"] < row["stats"]["HP"] }
          target = select_monster("使用一份受控伤药（恢复 20 HP）", rows)
          command = {"kind" => "item", "item" => "POTION", "monster_id" => target["id"]} if target
        when 3
          command = {"kind" => "catch", "item" => "POKEBALL"} if pbConfirmMessage("使用一颗受控精灵球？仅能捕获野生精灵。")
        when 4
          command = {"kind" => "flee"} if pbConfirmMessage("离开当前战斗？本场不发放通关奖励，已消耗的道具与 HP 不返还。")
        else
          @leave_active = true
          return
        end
        next unless command
        result = perform { @model.turn(command) }
        unless result
          return unless perform { @model.refresh }
          next
        end
        settled = result["settled_battle"]
        lines = settled["log"].map do |event|
          case event["event"]
          when "move"; "使用 #{text(@model.catalog['moves'][event['move']]['real_name'])}"
          when "damage"; "造成 #{event['damage']} 伤害"
          when "miss"; "招式没有命中"
          when "capture"; "精灵球摇晃 #{event['shakes']} 次"
          when "experience"; "获得 #{event['amount']} 经验，当前 Lv.#{event['level']}"
          when "status"; "进入 #{text(event['status'])} 状态"
          else; nil
          end
        end.compact
        if settled["status"] != "active"
          names = {"win" => "战斗胜利", "loss" => "战斗失败", "captured" => "捕获成功", "escaped" => "成功离开", "abandoned" => "已放弃挑战", "turn_limit" => "达到回合上限"}
          lines << (names[settled["outcome"]] || text(settled["outcome"]))
          lines << "服务端奖励 #{settled['result']['gold']} GOLD"
        end
        pbMessage(lines.join("\n")) unless lines.empty?
      end
    end
    def cultivate_menu
      action = choose("受控培养中心", ["努力值训练", "回忆已解锁招式", "进化", "繁殖", "孵化", "融合", "分离", "返回"])
      return unless action.is_a?(Integer) && action.between?(0, 6)
      if [3, 5].include?(action)
        rows = @model.state["monsters"].reject { |row| row["egg"] || row["components"] }
        first = select_monster(action == 3 ? "选择亲代一" : "选择身体精灵", rows)
        return unless first
        second = select_monster(action == 3 ? "选择亲代二" : "选择头部精灵", rows.reject { |row| row["id"] == first["id"] })
        return unless second
        kind = action == 3 ? "breed" : "fuse"
        cost = @model.catalog[action == 3 ? "breed_cost" : "fusion_cost"]
        return unless pbConfirmMessage("#{action == 3 ? '繁殖产生服务端蛋，等待五分钟后可孵化' : '融合会占用两只原精灵；分离需另付费用，保留原编号'}。\n费用 #{cost} GOLD，是否确认？")
        perform { @model.act(kind, {"parents" => [first["id"], second["id"]]}) }
        return
      end
      rows = @model.state["monsters"].select { |row| action == 4 ? row["egg"] : !row["egg"] }
      rows = rows.select { |row| row["components"] } if action == 6
      monster = select_monster("选择培养对象", rows)
      return unless monster
      case action
      when 0
        stat = choose("每点努力值 #{@model.catalog['training_cost_per_ev']} GOLD；单项最多 252，总计最多 510。", STATS.values + ["返回"])
        return unless stat.is_a?(Integer) && stat.between?(0, 5)
        amount = enter("增加多少点努力值？", "1", 3)
        return unless amount =~ /\A[1-9][0-9]{0,2}\z/
        perform { @model.act("train", {"monster_id" => monster["id"], "stat" => STATS.keys[stat], "amount" => amount.to_i}) } if pbConfirmMessage("费用 #{amount.to_i * @model.catalog['training_cost_per_ev']} GOLD，是否确认？")
      when 1
        moves = monster["learnable_moves"] - monster["moves"].map { |move| move["id"] }
        return pbMessage("没有可以回忆的新招式。") if moves.empty?
        index = choose("回忆招式 · #{@model.catalog['relearn_cost']} GOLD", moves.map { |id| text(@model.catalog["moves"][id]["real_name"]) } + ["返回"])
        return unless index.is_a?(Integer) && index.between?(0, moves.length - 1)
        slot = monster["moves"].length
        slot = choose("替换哪个招式？", monster["moves"].map { |move| text(@model.catalog["moves"][move["id"]]["real_name"]) } + ["返回"]) if slot >= 4
        return unless slot.is_a?(Integer) && slot.between?(0, 3)
        perform { @model.act("learn", {"monster_id" => monster["id"], "move" => moves[index], "slot" => slot}) }
      when 2
        evolutions = monster["evolutions"].select { |entry| !entry[3] && %w[Level Item].include?(entry[1]) }
        return pbMessage("当前规则没有可用的等级或道具进化。") if evolutions.empty?
        index = choose("进化 · #{@model.catalog['evolution_cost']} GOLD", evolutions.map { |entry| "#{species_name(entry[0])} · #{text(entry[1])} #{text(entry[2])}" } + ["返回"])
        perform { @model.act("evolve", {"monster_id" => monster["id"], "species" => evolutions[index][0]}) } if index.is_a?(Integer) && index.between?(0, evolutions.length - 1)
      when 4
        perform { @model.act("hatch", {"monster_id" => monster["id"]}) }
      when 6
        perform { @model.act("split", {"monster_id" => monster["id"]}) } if pbConfirmMessage("费用 #{@model.catalog['fusion_cost']} GOLD；融合后所得经验分配回原精灵，融合期间训练的努力值不会复制到两只原精灵。是否分离？")
      end
    end
  end
end
