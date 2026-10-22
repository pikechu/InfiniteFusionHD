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
    with_ui_fonts { TradingUI.new(client).main }
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
        heading = "交易中心 · 托管精灵封测\n联机币 #{wallet['available']}（预留 #{wallet['reserved']}）\n此处精灵保存在服务器收藏箱。"
        index = choose(heading, ["全球精灵市场", "出售精灵", "我的挂牌", "面对面交易", "待领取", "交易记录", "恢复断线操作", "服务器托管收藏箱", "返回"])
        return if index < 0 || index >= 8
        @ui.perform do
          case index
          when 0 then market
          when 1 then sell
          when 2 then listings
          when 3 then exchanges
          when 4 then deliveries
          when 5 then history
          when 6
            @trading.recover
            pbMessage("已核实原操作并刷新服务器钱包、交付和交易会话。")
          when 7 then KIFMultiplayer.open_collection_menu(@client)
          end
        end
      end
    end
    def filters_menu(filters)
      filters = WireJSON.parse(WireJSON.dump(filters))
      loop do
        index = choose("市场筛选\n#{text(WireJSON.dump(filters))}", ["物种英文 ID／融合 B25H133", "最低等级", "最高等级", "最低价格", "最高价格", "闪光", "性格 ID", "特性 ID（包含第二特性）", "融合头部图鉴号", "融合身体图鉴号", "六项 IV 下限／精确值", "至少几项 31 IV", "清空", "完成"])
        return filters if index < 0 || index >= 13
        case index
        when 0, 6, 7
          key = {0 => "species", 6 => "nature", 7 => "ability"}[index]
          value = @ui.enter("输入 #{key}，留空取消该条件", filters[key].to_s, 80).upcase
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
        when 12 then filters = {}
        end
      end
    end
    def market
      filters, sort, cursor = {}, "price_asc", nil
      loop do
        page = @trading.search(filters, sort, cursor)
        values = page["listings"]
        actions = values.map { |value| "#{label({'snapshot' => value['snapshot']})} · #{value['price']}" }
        index = choose("全球精灵市场 · 联机币\n#{values.length} 条", actions + ["下一页", "回到第一页", "筛选", "排序", "返回"])
        return if index < 0 || index >= actions.length + 4
        if index < actions.length
          listing_menu(values[index])
        elsif index == actions.length
          page["next_cursor"] ? cursor = page["next_cursor"] : pbMessage("已是最后一页。")
        elsif index == actions.length + 1
          cursor = nil
        elsif index == actions.length + 2
          filters, cursor = filters_menu(filters), nil
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
        index = choose("#{label({'snapshot' => value['snapshot']})}\n#{state(value['status'])} · 售价 #{value['price']} 联机币\n上架费 #{value['fee']} · 商品 #{text(value['id'])}", ["查看完整精灵与外观", own ? "撤销挂牌" : "购买", "返回"])
        return if index < 0 || index >= 2
        if index == 0
          inspect_asset({"id" => value["asset_id"], "snapshot" => value["snapshot"]})
        else
          raise Error, "此商品已经结束。" unless value["status"] == "active"
          if own
            next unless pbConfirmMessage("撤销后资产进入待领取，上架费不退。继续？")
            @trading.cancel_listing(value["id"])
            pbMessage("已撤单，请到待领取收纳原资产。")
          else
            inspect_asset({"id" => value["asset_id"], "snapshot" => value["snapshot"]})
            next unless pbConfirmMessage("支付 #{value['price']} 联机币购买这只精灵？\n成交后保存在服务器待领取，不进入主队伍。")
            result = @trading.buy(value)
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
        index = choose("我的挂牌", values.map { |v| "#{state(v['status'])} · #{label({'snapshot' => v['snapshot']})} · #{v['price']}" } + ["返回"])
        return if index < 0 || index >= values.length
        listing_menu(values[index])
      end
    end
    def deliveries
      loop do
        values = @trading.deliveries.select { |value| value["status"] == "pending" }
        index = choose("待领取 #{values.length} 项\n领取仅收纳已有资产，不重复生成精灵。", values.map { |v| "#{text(v['reason'])} · #{label(v['asset'])}" } + ["返回"])
        return if index < 0 || index >= values.length
        value = values[index]
        inspect_asset(value["asset"])
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
          coins = number("给对方的联机币金额；0 为不给钱", session["offers"][@client.player_id]["amount"])
          return unless coins
          return @trading.offer(session, selected, coins)
        end
      end
    end
    def inspect_offers(session)
      session["members"].each do |owner|
        offer = session["offers"][owner]
        pbMessage("#{owner == @client.player_id ? '你' : '对方'} · 好友码 #{text(session['friend_codes'][owner])}\n给出 #{offer['assets'].length} 只精灵、#{offer['amount']} 联机币。")
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
