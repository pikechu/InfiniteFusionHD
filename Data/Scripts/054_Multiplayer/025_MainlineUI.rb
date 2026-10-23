module KIFMultiplayer
  def self.open_mainline_menu(client = self.client)
    raise Error, "请先登录在线账号。" unless client.profile.account["username"]
    with_trading_scene { MainlineUI.new(client).main }
  end

  class MainlineUI
    def initialize(client)
      @client, @ui, @sdk, @trading_ui = client, UI.new(client), MainlineClient.new(client), TradingUI.new(client)
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def choose(title, choices); @ui.choose(title, choices); end
    def label(asset); @trading_ui.label(asset); end
    def number(title, initial = 1); @trading_ui.number(title, initial, 1); end
    def main
      config = @sdk.config
      raise Error, "服务器尚未启用托管角色服务。" unless config["enabled"]
      @sdk.recover
      loop do
        characters = @sdk.characters
        selected = choose("托管角色\n队伍与联机库存由服务器保存。", ["创建角色"] + characters.map { |character| "#{text(character['name'])} · #{character['party'].length} 只队伍精灵" } + ["恢复原操作", "联机补给", "孵化记录", "领取待收款", "返回"])
        return if selected < 0 || selected >= characters.length + 5
        @ui.perform do
          if selected == 0
            create
          elsif selected == characters.length + 1
            @sdk.recover
            pbMessage("已核实原生操作与当前角色状态。")
          elsif selected == characters.length + 2
            shop
          elsif selected == characters.length + 3
            eggs
          elsif selected == characters.length + 4
            value=@client.request("POST","/v1/mainline/credits/claim")
            pbMessage("已领取 #{value['claimed']} 联机币。")
          else
            character_menu(characters[selected - 1]["id"])
          end
        end
      end
    end
    def create
      name = @ui.enter("角色名称（最多20字）", defined?($Trainer) && $Trainer ? $Trainer.name.to_s[0, 20] : "训练师", 20)
      return if name.empty?
      chosen = choose("初始精灵 · 等级5", ["妙蛙种子", "小火龙", "杰尼龟", "返回"])
      return if chosen < 0 || chosen >= 3
      return unless pbConfirmMessage("创建 #{text(name)}？\n账号首次发放初始精灵与补给；其他角色共享已有资产。")
      character = @sdk.create(name, 0, %w[BULBASAUR CHARMANDER SQUIRTLE][chosen])
      pbMessage("角色已建立，队伍现有 #{character['party'].length} 只精灵。")
      character_menu(character["id"])
    end
    def pick_asset(character, prompt = "选择联机精灵", excluded = [])
      cursor = nil
      loop do
        page = @sdk.pc(character["id"], cursor)
        assets = page["assets"].reject { |asset| excluded.include?(asset["id"]) }
        selected = choose(prompt, assets.map { |asset| "#{label(asset)}#{asset['assigned_character'] ? ' · 队伍中' : ''}#{asset['locked'] ? ' · 占用中' : ''}" } + ["下一页", "第一页", "返回"])
        return nil if selected < 0 || selected >= assets.length + 2
        return @sdk.asset(assets[selected]["id"]) if selected < assets.length
        if selected == assets.length
          page["next_cursor"] ? cursor = page["next_cursor"] : pbMessage("已是最后一页。")
        else
          cursor = nil
        end
      end
    end
    def character_menu(id)
      loop do
        character = @sdk.character(id)
        choices = ["队伍与联机 PC", "培养与回复", "学习招式", "进化", "融合", "拆分", "恢复原操作", "繁育", "释放联机 PC 精灵",'剧情活动']
        can_mount = @sdk.config["battle_authority"] && defined?(Mainline) && Mainline.respond_to?(:mount)
        choices << "进入主线角色" if can_mount
        choices << "联机徽章挑战" if can_mount
        choices << "返回"
        selected = choose("#{text(character['name'])}\n队伍 #{character['party'].length}/6 · 联机币 #{character['wallet']['available']}", choices)
        return if selected < 0 || selected >= choices.length - 1
        @ui.perform do
          case selected
          when 0 then party(character)
          when 1 then cultivate(character)
          when 2 then learn(character)
          when 3 then evolve(character)
          when 4 then fusion(character)
          when 5 then split(character)
          when 6 then @sdk.recover
          when 7 then breed(character)
          when 8 then release(character)
          when 9 then story_activities(character)
          when 10 then Mainline.mount(@client, character) if can_mount
          when 11
            raise Error,"请先进入这个托管角色。" unless Mainline.active? && Mainline.character_id==character['id']
            count=(character['badges'] || []).length
            raise Error,"八枚联机徽章已完成。" if count>=8
            Mainline.battle({"kind"=>"boss","boss_index"=>count}) if pbConfirmMessage("挑战第 #{count+1} 枚联机徽章？\n队伍等级上限由已验证徽章决定。")
          end
        end
      end
    end
    def party(character)
      loop do
        character = @sdk.character(character["id"])
        assets = character["party"]
        selected = choose("托管队伍\n存入 PC 后才可上架或交换。", assets.map { |asset| label(asset) } + ["从联机 PC 加入", "返回"])
        return if selected < 0 || selected >= assets.length + 1
        if selected == assets.length
          raise Error, "队伍最多六只。" if assets.length >= 6
          value = pick_asset(character)
          next unless value
          @sdk.operate(character["id"], "inspect", [value["id"]]) unless value["full"]
          character = @sdk.character(character["id"])
          @sdk.set_party(character, character["party"].map { |asset| asset["id"] } + [value["id"]])
        else
          value = assets[selected]
          action = choose(label(value), ["查看资料", "存入联机 PC", "上移", "下移", "返回"])
          if action == 0
            @trading_ui.inspect_asset(value)
          elsif action >= 1 && action <= 3
            ids = assets.map { |asset| asset["id"] }
            ids.delete_at(selected) if action == 1
            ids[selected], ids[selected - 1] = ids[selected - 1], ids[selected] if action == 2 && selected > 0
            ids[selected], ids[selected + 1] = ids[selected + 1], ids[selected] if action == 3 && selected < ids.length - 1
            @sdk.set_party(character, ids)
          end
        end
      end
    end
    def cultivate(character)
      asset = pick_asset(character)
      return unless asset
      selected = choose(label(asset), ["升等级（每级1个神奇糖果）", "增加 EV（对应营养品）", "降低 EV（每次250联机币）", "回复 HP／PP／异常", "返回"])
      return if selected < 0 || selected >= 4
      if selected == 0
        count = number("提升等级数，当前 Lv.#{asset['snapshot']['level']}")
        return unless count && pbConfirmMessage("消耗 #{count} 个神奇糖果，提升 #{count} 级？")
        @sdk.operate(character["id"], "train", [asset["id"]], {"count" => count})
      elsif selected == 3
        @sdk.operate(character["id"], "heal", [asset["id"]])
      else
        stats = Snapshot::STATS
        stat = choose("选择能力值", stats + ["返回"])
        return if stat < 0 || stat >= stats.length
        count = number("次数（每次10点 EV）")
        return unless count
        return unless pbConfirmMessage("#{selected == 1 ? '消耗对应营养品' : '支付' + (count * 250).to_s + '联机币'}，#{selected == 1 ? '增加' : '降低'} #{count * 10} 点 EV？")
        @sdk.operate(character["id"], "ev", [asset["id"]], {"stat" => stats[stat], "count" => count, "reduce" => selected == 2})
      end
      pbMessage("服务器已保存培养结果。")
    end
    def release(character)
      asset=pick_asset(character,"选择要释放的联机 PC 精灵")
      return unless asset
      raise Error,"请先将精灵存入联机 PC。" if asset['assigned_character'] || asset['locked']
      return unless pbConfirmMessage("永久释放 #{label(asset)}？\n携带物退回联机库存，精灵不能取回。")
      @client.request("POST","/v1/mainline/assets/#{@sdk.identifier(asset['id'])}/release",{"version"=>asset['version'] || 1})
      pbMessage("已释放，携带物已退回。")
    end
    def learn(character)
      asset = pick_asset(character)
      return unless asset
      value = @ui.enter("招式名称或英文 ID", "", 80)
      return if value.empty?
      move = @trading_ui.resolve_id(:Move, value)
      return unless move
      moves = asset["snapshot"]["moves"]
      choices = moves.map { |entry| "替换 #{text(entry['id'])}" }
      choices << "加入新招式" if moves.length < 4
      selected = choose("学习 #{text(move)} · 1000联机币", choices + ["返回"])
      return if selected < 0 || selected >= choices.length
      return unless pbConfirmMessage("支付1000联机币，学习该招式？")
      @sdk.operate(character["id"], "learn", [asset["id"]], {"move_id" => move, "slot" => selected})
      pbMessage("招式已保存。")
    end
    def show_preview(snapshot)
      pbMessage("目标 #{text(snapshot['species'])} Lv.#{snapshot['level']}\n特性 #{text(snapshot['ability'])}\nIV #{text(WireJSON.dump(snapshot['iv']))}\nEV #{text(WireJSON.dump(snapshot['ev']))}\n携带物 #{text(snapshot['item'])}")
    end
    def evolve(character)
      asset = pick_asset(character)
      return unless asset
      selected = choose("进化条件", ["等级／亲密度等条件", "使用进化道具", "交易进化预览", "返回"])
      return if selected < 0 || selected >= 3
      params = {"method" => %w[level item trade][selected]}
      if selected == 1
        value = @ui.enter("进化道具名称或英文 ID", "", 80)
        return if value.empty?
        params["item_id"] = @trading_ui.resolve_id(:Item, value)
        return unless params["item_id"]
      end
      preview = @sdk.operate(character["id"], "preview_evolution", [asset["id"]], params)
      show_preview(preview["result"]["preview"])
      if selected==2
        pbMessage("交易进化由唯一成交触发。上方为进化后的物种和携带物；不符合条件时保持原样。")
        return
      end
      return unless pbConfirmMessage("按上述结果进化？#{selected == 1 ? '消耗1个所选道具。' : ''}")
      @sdk.operate(character["id"], "evolve", [asset["id"]], params)
      pbMessage("进化结果已保存。")
    end
    def fusion(character)
      body = pick_asset(character, "选择身体精灵")
      return unless body
      head = pick_asset(character, "选择头部精灵", [body["id"]])
      return unless head
      preview = @sdk.operate(character["id"], "preview_fusion", [body["id"], head["id"]])
      show_preview(preview["result"]["preview"])
      return unless pbConfirmMessage("支付1000联机币完成融合？\n身体携带物随融合体，头部携带物在拆分时归还。")
      @sdk.operate(character["id"], "fuse", [body["id"], head["id"]])
      pbMessage("融合结果与两个原始组件身份已保存。")
    end
    def split(character)
      asset = pick_asset(character, "选择有托管组件记录的融合精灵")
      return unless asset
      raise Error, "此精灵没有服务器托管组件记录。" unless asset["lineage_ids"].is_a?(Array) && asset["lineage_ids"].length == 2
      return unless pbConfirmMessage("支付500联机币拆分？\n恢复原组件身份，融合期间获得的经验按两部分分配。")
      @sdk.operate(character["id"], "split", [asset["id"]])
      pbMessage("拆分结果已保存，原组件已回到账号。")
    end
    def breed(character)
      first=pick_asset(character,"选择第一个繁育亲本")
      return unless first
      second=pick_asset(character,"选择第二个繁育亲本",[first["id"]])
      return unless second
      return unless pbConfirmMessage("支付2000联机币繁育？\n匹配条件由服务器检查，亲本保留，孵化准备时间5分钟。")
      @sdk.operate(character["id"],"breed",[first["id"],second["id"]])
      pbMessage("蛋记录已保存，请从孵化记录领取。")
    end
    def eggs
      loop do
        values=@client.request("GET","/v1/mainline/eggs")["eggs"]
        raise Error,"孵化记录无效。" unless values.is_a?(Array) && values.length<=100
        selected=choose("服务器孵化记录",values.map { |value| "#{text(value['id'])} · #{value['status']=='hatched' ? '已孵化' : value['ready'] ? '可孵化' : '准备中'}" }+["返回"])
        return if selected<0 || selected>=values.length
        value=values[selected]
        next if value["status"]=="hatched"
        result=@client.request("POST","/v1/mainline/eggs/#{@sdk.identifier(value['id'])}/hatch")
        pbMessage("孵化完成，资产 #{text(result['egg']['asset_id'])} 已进入联机 PC。")
      end
    end
    def shop
      loop do
        values=@client.request("GET","/v1/mainline/shop")["items"]
        raise Error,"补给目录无效。" unless values.is_a?(Array) && values.length<=128
        selected=choose("联机补给",values.map { |item| "#{text(item['name'])} · 单价 #{item['price']}" }+["返回"])
        return if selected<0 || selected>=values.length
        item=values[selected];quantity=number("购买数量（1至99）")
        next unless quantity
        return unless pbConfirmMessage("购买 #{quantity} 件 #{text(item['name'])}，总价 #{quantity*item['price']} 联机币？")
        @client.request("POST","/v1/mainline/shop/buy",{"item_id"=>item["id"],"quantity"=>quantity,"unit_price"=>item["price"],"compatibility"=>@client.compatibility})
        pbMessage("补给已进入联机库存。")
      end
    end
  end
end
