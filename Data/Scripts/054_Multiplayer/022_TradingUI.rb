module KIFMultiplayer
  module TradingPreview
    # Resolve installed standard art without invoking the game's random-alt
    # selector/downloader, which also mutates the main world's sprite caches.
    def self.bitmap(snapshot)
      Snapshot.validate(snapshot)
      species = snapshot["species"]
      fusion = /\AB([0-9]+)H([0-9]+)\z/.match(species)
      if fusion
        body, head = fusion[1].to_i, fusion[2].to_i
        stem = "#{head}.#{body}"
        paths = Dir["Graphics/CustomBattlers/indexed/#{head}/#{stem}*.png"].select { |path| File.basename(path) =~ /\A#{head}\.#{body}[a-z]*\.png\z/i }.sort
        paths << "Graphics/Battlers/#{head}/#{stem}.png"
      else
        dex = GameData::Species.get(species).id_number
        paths = Dir["Graphics/BaseSprites/#{dex}*.png"].select { |path| File.basename(path) =~ /\A#{dex}[a-z]*\.png\z/i }.sort
        paths << "Graphics/Battlers/#{dex}/#{dex}.png"
      end
      path = paths.find { |candidate| File.file?(candidate) }
      raise Error, "缺少此精灵的标准立绘，请安装素材后再预览和购买。" unless path
      animated = AnimatedBitmap.new(path).recognizeDims
      appearance = snapshot["appearance"] || {}
      if snapshot["shiny"]
        dex_number = GameData::Species.get(species).id_number
        omega = {"pif_shiny" => appearance["shinyimprovpif"] || 0, "body_shiny" => appearance["body_shiny"], "head_shiny" => appearance["head_shiny"], "dexNum" => dex_number}
        animated.pbGiveFinaleColor(appearance["shinyR"] || 0, appearance["shinyG"] || 1, appearance["shinyB"] || 2, appearance["shinyValue"] || 0, appearance["shinyKRS"] || [0] * 9, omega)
      end
      animated.scale_bitmap(appearance["sprite_scale"] || 1.0)
      animated
    rescue Exception
      animated.dispose if animated
      raise
    end
  end

  def self.open_trading_menu(client = self.client)
    raise Error, "请从标题选择在线模式，注册或登录账号后使用交易中心。" unless client.profile.account["username"]
    with_trading_scene { TradingUI.new(client).main }
  end

  def self.with_trading_scene(propagate_errors = false)
    previous_scene = $scene
    previous_chatting = OnlineMode.chatting if defined?(OnlineMode)
    $scene = Object.new
    OnlineMode.chatting = true if defined?(OnlineMode) && OnlineMode.active?
    with_ui_fonts { yield }
  rescue Error => error
    raise if propagate_errors
    pbMessage("交易：#{display_text(error.message)}")
  rescue StandardError => error
    raise if propagate_errors
    log_error(error)
    pbMessage("交易界面暂时不可用，请重试。")
  ensure
    $scene = previous_scene
    OnlineMode.chatting = previous_chatting if defined?(OnlineMode)
  end

  class TradingUI
    STATES = {"active" => "在售", "sold" => "已售", "cancelled" => "已取消", "expired" => "已到期", "invited" => "等待接受", "offering" => "协商中", "locked" => "双方已锁定", "committed" => "已成交", "pending" => "待收纳", "claimed" => "已收纳"}.freeze
    def initialize(client)
      @client, @ui, @trading = client, UI.new(client), TradingClient.new(client)
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def state(value); STATES[value] || text(value); end
    def choose(title, choices); @ui.choose(title, choices); end
    def number(title, initial = 0, minimum = 0)
      value = @ui.enter(title, initial.to_s, 10)
      return nil if value.empty?
      raise Error, "请输入整数金额。" unless value =~ /\A[0-9]+\z/
      @trading.amount(value.to_i, minimum)
    end
    def label(asset)
      snapshot = asset["snapshot"]
      "#{text(snapshot['name'])} · #{text(snapshot['species'])} Lv.#{snapshot['level']}#{snapshot['shiny'] ? ' ★' : ''}"
    end
    def listing_label(value)
      return "#{text(value['item']['name'])} ×#{value['quantity']} · 单价 #{value['unit_price']} · 总价 #{value['price']}" if value["kind"] == "item"
      "#{label({'snapshot' => value['snapshot']})} · #{value['price']}"
    end
    def item_name(id); GameData::Item.get(id).name; end
    def inspect_item(id, quantity)
      item = GameData::Item.get(id)
      pbMessage("#{text(item.name)} ×#{quantity}\n#{text(item.description)}\n来源：服务器库存；不会写入本地背包。")
    end
    def inspect_listing(value)
      value["kind"] == "item" ? inspect_item(value["item_id"], value["quantity"]) : inspect_asset({"id" => value["asset_id"], "snapshot" => value["snapshot"]})
    end
    def resolve_id(type, value)
      if type == :Species && value =~ /\A[0-9]+\z/
        id = value.to_i
        raise Error, "图鉴号不存在。" unless GameData::Species::DATA.key?(id)
        return GameData::Species.get(id).id.to_s
      end
      return value.upcase if value =~ /\A[A-Za-z0-9_]+\z/
      registry = GameData.const_get(type)
      matches = registry::DATA.values.uniq.select { |entry| entry.name.include?(value) }.first(20)
      raise Error, "未找到对应名称，请输入游戏名称或英文 ID。" if matches.empty?
      return matches.first.id.to_s if matches.length == 1
      selected = choose("选择#{type == :Item ? '道具' : '精灵'}", matches.map { |entry| text(entry.name) } + ["返回"])
      selected >= 0 && selected < matches.length ? matches[selected].id.to_s : nil
    end
    def inspect_asset(asset)
      snapshot = asset["snapshot"]
      Snapshot.validate(snapshot)
      pbMessage("#{label(asset)}\n性格 #{text(snapshot['nature'])}\n特性 #{text(snapshot['ability'])} / #{text(snapshot['ability2'])}\n携带物 #{text(snapshot['item'])}\n招式 #{snapshot['moves'].map { |move| text(move['id']) }.join(' / ')}")
      pbMessage("IV #{text(WireJSON.dump(snapshot['iv']))}\nEV #{text(WireJSON.dump(snapshot['ev']))}\n原训练师 #{text(WireJSON.dump(snapshot['owner']))}")
      animated = viewport = sprite = nil
      begin
        animated = TradingPreview.bitmap(snapshot)
        viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
        viewport.z = 99999
        sprite = Sprite.new(viewport)
        sprite.bitmap = animated.bitmap
        sprite.ox, sprite.oy = sprite.bitmap.width / 2, sprite.bitmap.height / 2
        sprite.x, sprite.y = Graphics.width / 2, Graphics.height / 3
        pbMessage("标准立绘与保存的闪光颜色预览。\n本阶段不交易玩家自选替代立绘。") { animated.update; sprite.bitmap = animated.bitmap }
      ensure
        sprite.dispose if sprite && !sprite.disposed?
        viewport.dispose if viewport && !viewport.disposed?
        animated.dispose if animated
      end
    end
    def main
      @trading.recover
      loop do
        wallet = @trading.wallet
        heading = "交易中心 · 托管资产封测\n联机币 #{wallet['available']}（预留 #{wallet['reserved']}）\n精灵和道具均保存在服务器。"
        index = choose(heading, ["全球精灵市场", "全球道具市场", "出售", "我的挂牌", "面对面交易", "待领取", "我的联机道具", "交易记录", "恢复断线操作", "服务器托管收藏箱", "交易邀请设置", "托管角色与培养", "更多交易功能", "返回"])
        return if index < 0 || index >= 13
        @ui.perform do
          case index
          when 0 then market
          when 1 then market("item")
          when 2
            kind = choose("选择出售类型", ["精灵", "道具", "返回"])
            sell if kind == 0
            sell_item if kind == 1
          when 3 then listings
          when 4 then exchanges
          when 5 then deliveries
          when 6 then inventory
          when 7 then history
          when 8
            @trading.recover
            pbMessage("已核实原操作并刷新服务器钱包、交付和交易会话。")
          when 9 then KIFMultiplayer.open_collection_menu(@client)
          when 10 then preferences
          when 11 then KIFMultiplayer.open_mainline_menu(@client)
          when 12 then TradingExtrasUI.new(@client).main
          end
        end
      end
    end
    def filters_menu(filters)
      filters = WireJSON.parse(WireJSON.dump(filters))
      return item_filters(filters) if filters["category"] == "item"
      loop do
        index = choose("市场筛选\n#{text(WireJSON.dump(filters))}", ["物种名称／ID／融合 B25H133", "最低等级", "最高等级", "最低价格", "最高价格", "闪光", "性格 ID", "特性 ID（包含第二特性）", "融合头部图鉴号", "融合身体图鉴号", "六项 IV 下限／精确值", "至少几项 31 IV", "性别", "清空", "完成"])
        return filters if index < 0 || index >= 14
        case index
        when 0, 6, 7
          key = {0 => "species", 6 => "nature", 7 => "ability"}[index]
          value = @ui.enter("输入 #{key}，留空取消该条件", filters[key].to_s, 80)
          value = resolve_id(:Species, value) if index == 0 && !value.empty?
          next if value.nil?
          value = value.upcase
          value.empty? ? filters.delete(key) : filters[key] = value
        when 1, 2, 3, 4, 8, 9, 11
          key = {1 => "min_level", 2 => "max_level", 3 => "min_price", 4 => "max_price", 8 => "head", 9 => "body", 11 => "min_perfect"}[index]
          value = number("输入 #{key}；留空取消条件", filters[key] || 0)
          value.nil? ? filters.delete(key) : filters[key] = value
        when 5
          value = choose("闪光条件", ["不限", "仅闪光", "仅非闪光"])
          value == 1 || value == 2 ? filters["shiny"] = (value == 1) : filters.delete("shiny")
        when 10
          stats = Snapshot::STATS
          selected = choose("选择能力值", stats + ["返回"])
          next if selected < 0 || selected >= stats.length
          mode = choose("#{stats[selected]} 条件", ["至少", "精确值（可筛 0 攻／0 速）", "删除该能力条件"])
          stat = stats[selected]
          (filters["iv_min"] || {}).delete(stat)
          (filters["iv_exact"] || {}).delete(stat)
          next unless mode == 0 || mode == 1
          value = number("IV 0 至 31", 0)
          if value
            key = mode == 0 ? "iv_min" : "iv_exact"
            (filters[key] ||= {})[stat] = value
          end
        when 12
          gender = choose("性别条件", ["不限", "雄性", "雌性", "无性别", "返回"])
          filters.delete("gender") if gender == 0
          filters["gender"] = gender - 1 if gender >= 1 && gender <= 3
        when 13 then filters = {"category" => "pokemon"}
        end
      end
    end
    def item_filters(filters)
      loop do
        selected = choose("道具筛选\n#{text(WireJSON.dump(filters))}", ["道具名称／ID", "最低整单总价", "最高整单总价", "清空", "完成"])
        return filters if selected < 0 || selected >= 4
        if selected == 0
          value = @ui.enter("输入道具名称或英文 ID；留空取消", filters["item_id"].to_s, 80)
          value = resolve_id(:Item, value) unless value.empty?
          next if value.nil?
          value.empty? ? filters.delete("item_id") : filters["item_id"] = value
        elsif selected == 3
          filters = {"category" => "item"}
        else
          key = selected == 1 ? "min_price" : "max_price"
          value = number("输入整单总价；留空取消", filters[key] || 0)
          value ? filters[key] = value : filters.delete(key)
        end
      end
    end
    def market(category = "pokemon", initial_filters = nil, initial_sort = 'price_asc')
      filters, sort, cursor = initial_filters || {"category" => category}, initial_sort, nil
      loop do
        page = @trading.search(filters, sort, cursor)
        values = page["listings"]
        actions = values.map { |value| listing_label(value) }
        index = choose("全球#{category == 'item' ? '道具' : '精灵'}市场 · 联机币\n#{values.length} 条", actions + ["下一页", "回到第一页", "筛选", "排序", "收藏此搜索", "返回"])
        return if index < 0 || index >= actions.length + 5
        if index < actions.length
          listing_menu(values[index])
        elsif index == actions.length
          page["next_cursor"] ? cursor = page["next_cursor"] : pbMessage("已是最后一页。")
        elsif index == actions.length + 1
          cursor = nil
        elsif index == actions.length + 2
          filters, cursor = filters_menu(filters), nil
        elsif index == actions.length + 4
          TradingExtrasUI.new(@client).save_search(filters,sort)
        else
          selected = choose("排序", ["价格从低到高", "价格从高到低", "最新上架", "即将到期", "等级从高到低", "IV 总和从高到低", "返回"])
          sort = %w[price_asc price_desc newest expiring level_desc iv_desc][selected] if selected >= 0 && selected < 6
          cursor = nil
        end
      end
    end
    def listing_menu(value)
      loop do
        value = @trading.listing(value["id"])
        own = value["seller_id"] == @client.player_id
        index = choose("#{listing_label(value)}\n#{state(value['status'])} · 总价 #{value['price']} 联机币\n上架费 #{value['fee']} · 商品 #{text(value['id'])}", ["查看完整详情", own ? "撤销挂牌" : "购买", "分享到交易频道", "返回"])
        return if index < 0 || index >= 3
        if index == 0
          inspect_listing(value)
        elsif index == 2
          raise Error, "仅能分享自己仍在售的商品。" unless own && value["status"] == "active"
          world = defined?(OnlineMode) && OnlineMode.world
          raise Error, "请先连接在线地图。" unless world
          world.send_chat("trade", listing_label(value)[0, 180], value["id"])
          pbMessage("商品已排队发送到交易频道，点击商品卡会重新核对挂牌状态。")
        else
          raise Error, "此商品已经结束。" unless value["status"] == "active"
          if own
            next unless pbConfirmMessage("撤销后资产进入待领取，上架费不退。继续？")
            @trading.cancel_listing(value["id"])
            pbMessage("已撤单，请到待领取收纳原资产。")
          else
            inspect_listing(value)
            quantity=value['kind']=='item' ? number('购买数量；留空返回',value['quantity'],1) : nil
            next if value['kind']=='item' && quantity.nil?
            raise Error,'购买数量超过剩余库存。' if quantity && quantity>value['quantity']
            total=quantity ? quantity*value['unit_price'] : value['price']
            next unless pbConfirmMessage("支付 #{total} 联机币#{quantity ? "购买#{quantity}件" : '购买精灵'}？\n成交后保存在服务器待领取。")
            result = @trading.buy(value,quantity)
            pbMessage("成交 #{text(result['order']['id'])}。资产已归你所有，请到待领取收纳。")
          end
          return
        end
      end
    end
    def sell
      assets = @trading.assets.reject { |asset| asset["locked"] }
      raise Error, "没有可出售的托管精灵。已挂牌、已报价或待领取资产不能再次上架。" if assets.empty?
      index = choose("选择出售精灵", assets.map { |asset| label(asset) } + ["返回"])
      return if index < 0 || index >= assets.length
      asset = assets[index]
      inspect_asset(asset)
      price = number("输入整只售价（联机币）", 1000, 1)
      return unless price
      fee = [[(price * 2 + 99) / 100, 100].max, 25000].min
      return unless pbConfirmMessage("售价 #{price} · 上架费 #{fee}\n预计净收入 #{price - fee} · 7 天到期\n撤单或到期不退费用。确认上架？")
      value = @trading.sell(asset["id"], price)
      pbMessage("已上架 #{text(value['id'])}，离线期间仍可成交。")
    end
    def listings
      loop do
        values = @trading.my_listings
        index = choose("我的挂牌", values.map { |v| "#{state(v['status'])} · #{listing_label(v)}" } + ["返回"])
        return if index < 0 || index >= values.length
        listing_menu(values[index])
      end
    end
    def deliveries
      loop do
        values = @trading.deliveries.select { |value| value["status"] == "pending" }
        index = choose("待领取 #{values.length} 项\n领取只解除交付占用，不重复生成资产。", values.map { |v| "#{text(v['reason'])} · #{v['kind'] == 'item' ? text(item_name(v['item_id'])) + ' ×' + v['quantity'].to_s : label(v['asset'])}" } + ["返回"])
        return if index < 0 || index >= values.length
        value = values[index]
        value["kind"] == "item" ? inspect_item(value["item_id"], value["quantity"]) : inspect_asset(value["asset"])
        next unless pbConfirmMessage("收纳到服务器收藏箱？")
        @trading.claim(value["id"])
        pbMessage("收纳完成，可在收藏箱查看或再次交易。")
      end
    end
    def history
      values = @trading.history
      raise Error, "交易记录响应无效。" unless values.is_a?(Array) && values.length <= 100
      loop do
        index = choose("最近交易记录", values.map { |v| "#{text(v['kind'])} · #{text(v['id'])}" } + ["返回"])
        return if index < 0 || index >= values.length
        pbMessage(text(WireJSON.dump(values[index]))[0, 2500])
      end
    end
    def exchanges
      loop do
        values = @trading.exchanges
        index = choose("面对面交易\n#{values.length} 个会话；邀请通过好友码确认身份。", ["输入好友码发起交易"] + values.map { |v| "#{state(v['status'])} · #{text(v['id'])}" } + ["返回"])
        return if index < 0 || index >= values.length + 1
        if index == 0
          code = @ui.enter("对方八位好友码", "", 8)
          next if code.empty?
          exchange_menu(@trading.invite(code))
        else
          exchange_menu(values[index - 1])
        end
      end
    end
    def sell_item
      values = @trading.inventory["items"].select { |value| value["available"] > 0 && value["item"]["tradeable"] }
      raise Error, "没有可出售的联机道具。" if values.empty?
      selected = choose("选择道具", values.map { |v| "#{text(v['item']['name'])} · 可用 #{v['available']}" } + ["返回"])
      return if selected < 0 || selected >= values.length
      value = values[selected]
      quantity = number("出售数量（最多9999，当前可用#{value['available']}）", 1, 1)
      return unless quantity
      raise Error, "超过当前可用数量或单次9999上限。" if quantity > [9999, value["available"]].min
      unit = number("每件单价（联机币）", 100, 1)
      return unless unit
      total = @trading.amount(unit * quantity, 1)
      fee = [[(total * 2 + 99) / 100, 100].max, 25000].min
      return unless pbConfirmMessage("#{text(value['item']['name'])} ×#{quantity}\n单价 #{unit} · 整单总价 #{total}\n上架费 #{fee} · 7天到期，整单出售。确认？")
      @trading.sell_item(value["item_id"], quantity, unit)
      pbMessage("道具已上架。")
    end
    def inventory
      values = @trading.inventory["items"]
      loop do
        selected = choose("联机道具库存", values.map { |v| "#{text(v['item']['name'])} · 可用 #{v['available']}／占用 #{v['reserved']}" } + ["返回"])
        return if selected < 0 || selected >= values.length
        inspect_item(values[selected]["item_id"], values[selected]["quantity"])
      end
    end
    def preferences
      loop do
        value = @trading.preferences
        selected = choose("交易邀请设置\n附近邀请：#{value['allow_nearby'] ? '接收' : '关闭'}\n好友码邀请：#{value['allow_friend'] ? '接收' : '关闭'}\n已屏蔽 #{value['blocked'].length} 人", ["切换附近邀请", "切换好友码邀请", "按好友码屏蔽玩家", "取消屏蔽", "返回"])
        return if selected < 0 || selected >= 4
        if selected == 0 || selected == 1
          key = selected == 0 ? "allow_nearby" : "allow_friend"
          @trading.preferences({key => !value[key]})
        elsif selected == 2
          code = @ui.enter("输入对方八位好友码", "", 8).upcase
          @trading.preferences({"block_friend_code" => code}) unless code.empty?
        else
          trainers = value["blocked"]
          chosen = choose("选择取消屏蔽的玩家", trainers.map { |t| "#{text(t['nickname'])} · #{text(t['friend_code'])}" } + ["返回"])
          @trading.preferences({"unblock_friend_code" => trainers[chosen]["friend_code"]}) if chosen >= 0 && chosen < trainers.length
        end
      end
    end
    def edit_items(session)
      selected = WireJSON.parse(WireJSON.dump(session["offers"][@client.player_id]["items"] || {}))
      values = @trading.inventory["items"].select { |value| value["item"]["tradeable"] && (value["available"] > 0 || selected[value["item_id"]]) }
      loop do
        index = choose("交易道具 #{selected.length}/8", values.map { |v| "#{text(v['item']['name'])} · 给出 #{selected[v['item_id']] || 0}" } + ["清空道具", "完成", "取消编辑"])
        return nil if index < 0 || index >= values.length + 2
        return selected if index == values.length + 1
        if index == values.length
          selected = {}
        else
          value = values[index]
          id = value["item_id"]
          maximum = value["available"] + (session["offers"][@client.player_id]["items"] || {})[id].to_i
          quantity = number("给出数量 0至#{maximum}（0删除）", selected[id] || 0)
          next if quantity.nil?
          raise Error, "道具数量不足。" if quantity > maximum
          if quantity == 0
            selected.delete(id)
          else
            raise Error, "最多八种道具。" if !selected.key?(id) && selected.length >= 8
            selected[id] = quantity
          end
        end
      end
    end
    def edit_offer(session)
      reference = "exchange:" + session["id"]
      assets = @trading.assets.select { |a| !a["locked"] || a["lock_reference"] == reference }
      selected = session["offers"][@client.player_id]["assets"].map { |a| a["id"] }
      loop do
        index = choose("选择交易精灵 #{selected.length}/6", assets.map { |a| "#{selected.include?(a['id']) ? '[已选]' : '[未选]'} #{label(a)}" } + ["清空精灵", "下一步：金额", "取消编辑"])
        return if index < 0 || index >= assets.length + 2
        if index < assets.length
          id = assets[index]["id"]
          selected.include?(id) ? selected.delete(id) : (selected << id if selected.length < 6)
        elsif index == assets.length
          selected = []
        else
          items = edit_items(session)
          return if items.nil?
          coins = number("给对方的联机币金额；0 为不给钱", session["offers"][@client.player_id]["amount"])
          return unless coins
          return @trading.offer(session, selected, coins, items)
        end
      end
    end
    def inspect_offers(session)
      pbMessage("本服启用交易进化。成交后符合条件的精灵由服务器进化，所需携带物会消耗。\n可先在托管角色的进化菜单查看交易预览。") if session['trade_evolution']
      session["members"].each do |owner|
        offer = session["offers"][owner]
        item_text = (offer["items"] || {}).map { |id, quantity| "#{text(item_name(id))} ×#{quantity}" }.join("、")
        pbMessage("#{owner == @client.player_id ? '你' : '对方'} · 好友码 #{text(session['friend_codes'][owner])}\n给出 #{offer['assets'].length} 只精灵、#{offer['amount']} 联机币。\n道具：#{item_text.empty? ? '无' : item_text}")
        offer["assets"].each { |asset| inspect_asset(asset) }
      end
    end
    def exchange_menu(session)
      loop do
        session = @trading.exchange(session["id"])
        index = choose("面对面交易 #{state(session['status'])}\n版本 #{session['revision']} · 锁定 #{session['locked'].length}/2 · 确认 #{session['confirmed'].length}/2", ["刷新／恢复结果", "接受邀请", "编辑我的精灵与金额", "查看双方完整清单", "锁定当前清单", "最终确认", "取消交易", "返回"])
        return if index < 0 || index >= 7
        case index
        when 0
          pbMessage("成交编号 #{text(session['transaction_id'])}，请刷新收藏箱和钱包。") if session["status"] == "committed"
        when 1 then session = @trading.exchange_action(session, "accept")
        when 2 then session = edit_offer(session) || session
        when 3 then inspect_offers(session)
        when 4 then session = @trading.exchange_action(session, "lock")
        when 5
          inspect_offers(session)
          next unless pbConfirmMessage("按当前完整清单完成交换？双方最终确认后立即成交。")
          session = @trading.exchange_action(session, "confirm")
        when 6
          next unless pbConfirmMessage("取消尚未成交的交易并释放精灵与预留金额？")
          session = @trading.exchange_action(session, "cancel")
        end
      end
    end
  end
end
