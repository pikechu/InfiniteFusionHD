module KIFMultiplayer
  module ShopVisual
    Actor = Struct.new(:clothes, :hat, :hair, :skin_tone, :clothes_color, :hat_color, :hair_color)
    def self.bitmap(appearance, action = "walk")
      wrappers, result = [], nil
      load = lambda do |path, hue = 0|
        return nil unless path && pbResolveBitmap(path)
        wrapper = AnimatedBitmap.new(path, hue.to_i)
        wrappers << wrapper
        wrapper.bitmap
      end
      base = load.call(getBaseOverworldSpriteFilename(action, appearance["skin_tone"]))
      raise Error, "角色基础素材缺失。" unless base
      result = base.clone
      outfit = load.call(getOverworldOutfitFilename(appearance["clothes"], action), appearance["clothes_color"])
      raise Error, "服装动作素材缺失。" unless outfit
      result.blt(0, 0, outfit, outfit.rect)
      hair = load.call(getOverworldHairFilename(appearance["hair"]), appearance["hair_color"])
      result.blt(0, 0, hair, hair.rect) if hair
      hat = load.call(getOverworldHatFilename(appearance["hat"]), appearance["hat_color"])
      if hat
        width = result.width / 4
        4.times do |index|
          result.blt(index * width, index.odd? ? -2 : 0, hat, hat.rect)
        end
      end
      result
    rescue Exception
      result.dispose if result
      raise
    ensure
      wrappers.each(&:dispose)
    end
    def self.preview(base, grants)
      result = ShopData.copy(base)
      grants.each do |key|
        item = ShopData.local["entitlements"][key]
        next unless item && %w[clothes hat hair].include?(item["slot"])
        result[item["slot"]], result[item["slot"] + "_color"] = item["resource"], 0
      end
      result
    end
  end

  class ShopScene
    CATEGORIES = [["推荐", nil], ["服装", "clothes"], ["帽子", "hat"], ["发型", "hair"], ["套装", "bundle"],
                  ["节日", "seasonal"], ["名片", "frame"], ["称号", "title"], ["主题", "palette"]].freeze
    attr_reader :shop, :products
    def initialize(shop = ShopClient.new)
      @shop, @category, @index, @page, @direction = shop, 0, 0, 0, 2
      @draft_grants = []
    end
    def filter
      category = CATEGORIES[@category][1]
      @products = @shop.catalog["products"].select { |item| !category || item["category"] == category }
      @index = [[@index, @products.length - 1].min, 0].max
      @page = @index / 5
    end
    def dialog
      @viewport.visible = false if @viewport
      yield
    ensure
      @viewport.visible = true if @viewport
      @drawn = nil
    end
    def run
      raise Error, "请先登录在线模式。" unless OnlineMode.active?
      @shop.refresh
      filter
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 1_000_000
      @canvas = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      @preview = Sprite.new(@viewport)
      @preview.z = 1
      @preview.zoom_x = @preview.zoom_y = 2.5
      loop do
        update
        break if Input.trigger?(Input::BACK)
        if Input.trigger?(Input::UP)
          select(@index - 1)
        elsif Input.trigger?(Input::DOWN)
          select(@index + 1)
        elsif Input.trigger?(Input::LEFT)
          select(@index - 5)
        elsif Input.trigger?(Input::RIGHT)
          select(@index + 5)
        elsif Input.trigger?(Input::ACTION)
          @direction = {2 => 4, 4 => 8, 8 => 6, 6 => 2}[@direction]
        elsif Input.trigger?(Input::USE)
          details
        elsif defined?(Input::MOUSELEFT) && Input.trigger?(Input::MOUSELEFT) && Input.respond_to?(:mouse_x)
          break if click(Input.mouse_x, Input.mouse_y) == :exit
        end
      end
    ensure
      dispose
    end
    def update
      Graphics.update
      Input.update
      draw
      if @preview && @preview.bitmap
        width, height = @preview.bitmap.width / 4, @preview.bitmap.height / 4
        frame = (KIFMultiplayer.monotonic * 5).to_i % 4
        @preview.src_rect.set(frame * width, (@direction / 2 - 1) * height, width, height)
        @preview.ox, @preview.oy = width / 2, height
      end
    end
    def select(index)
      return if @products.empty?
      @index = index % @products.length
      @page = @index / 5
      @drawn = nil
    end
    def click(x, y)
      if y >= Graphics.height - 44
        action = [[x * 6 / Graphics.width, 0].max, 5].min
        case action
        when 0 then details
        when 1 then mine
        when 2
          selected = dialog { UI.new(@shop.client).choose("商品分类", CATEGORIES.map(&:first) + ["返回"]) }
          if selected >= 0 && selected < CATEGORIES.length
            @category, @index = selected, 0
            filter
          end
        when 3 then select(@index - 5)
        when 4 then select(@index + 5)
        when 5 then return :exit
        end
        @drawn = nil
      elsif x < Graphics.width * 3 / 5 && y >= 82 && y < 302
        index = @page * 5 + (y - 82) / 44
        if index < @products.length
          index == @index ? details : select(index)
        end
      elsif x >= Graphics.width * 3 / 5
        @direction = {2 => 4, 4 => 8, 8 => 6, 6 => 2}[@direction]
      end
      nil
    end
    def draw
      return unless @canvas
      item = @products[@index]
      slots = @shop.state["equipment"]["slots"]
      signature = [@index, @category, @shop.state["wallet"]["balance"], slots, @draft_grants]
      return if @drawn == signature
      @drawn = ShopData.copy(signature)
      bitmap = @canvas.bitmap
      palette = slots["palette"] && ShopData.local["entitlements"][slots["palette"]]["color"]
      accent = Color.new(*(palette || [50, 125, 190]))
      bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(18, 26, 41))
      bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
      bitmap.font.size = 21
      bitmap.font.color = Color.new(240, 246, 255)
      bitmap.draw_text(14, 8, 240, 30, "融合商城 · #{CATEGORIES[@category][0]}")
      bitmap.font.size = 17
      bitmap.draw_text(Graphics.width - 182, 10, 168, 28, "RP #{@shop.state['wallet']['balance']}", 2)
      bitmap.font.color = Color.new(160, 181, 206)
      bitmap.draw_text(14, 44, Graphics.width - 28, 26, "方向键翻页 · 确认看详情 · 动作键转身")
      left = Graphics.width * 3 / 5
      @products[@page * 5, 5].to_a.each_with_index do |product, row|
        y = 82 + row * 44
        bitmap.fill_rect(10, y, left - 16, 40, @page * 5 + row == @index ? accent : Color.new(29, 40, 58))
        bitmap.font.color = Color.new(245, 248, 255)
        bitmap.draw_text(18, y, left - 35, 24, KIFMultiplayer.display_text(product["name"]))
        bitmap.font.size = 14
        bitmap.font.color = Color.new(185, 211, 230)
        label = product["owned"] ? "已拥有" : "#{product['total']} RP · 永久绑定"
        bitmap.draw_text(18, y + 20, left - 35, 19, label)
        bitmap.font.size = 17
      end
      bitmap.draw_text(12, 307, left - 20, 24, @products.empty? ? "此分类暂无在售商品" : "第 #{@page + 1}/#{[(@products.length + 4) / 5, 1].max} 页")
      bitmap.font.color = Color.new(180, 205, 230)
      bitmap.draw_text(left, 83, Graphics.width - left, 26, "试穿预览", 1)
      bitmap.font.size = 14
      bitmap.draw_text(left, 275, Graphics.width - left, 22, "未购买不会装备", 1)
      bitmap.draw_text(left, 297, Graphics.width - left, 22, "点击角色转身", 1)
      @preview.bitmap.dispose if @preview.bitmap
      base = ShopState.base
      grants = slots.values + @draft_grants + (item ? item["grants"] : [])
      @preview.bitmap = ShopVisual.bitmap(ShopVisual.preview(base, grants))
      @preview.x, @preview.y = left + (Graphics.width - left) / 2, 260
      ["详情", "我的", "分类", "上页", "下页", "返回"].each_with_index do |label, index|
        width = Graphics.width / 6
        bitmap.fill_rect(index * width + 3, Graphics.height - 42, width - 6, 36, accent)
        bitmap.font.color = Color.new(255, 255, 255)
        bitmap.font.size = 16
        bitmap.draw_text(index * width, Graphics.height - 42, width, 36, label, 1)
      end
    end
    def details
      product = @products[@index]
      return unless product
      dialog do
        ui = UI.new(@shop.client)
        owned = product["owned"]
        choices = [owned ? "装备／组合" : "确认购买", "保留组合试穿", "清空试穿组合", "我的商城", "商品分类", "返回"]
        expiry = product["ends_at"] ? "\n下架：#{Time.at(product['ends_at']).utc.strftime('%Y-%m-%d %H:%M UTC')}" : ""
        selected = ui.choose("#{product['name']}\n#{product['description']}#{expiry}\n#{owned ? '已拥有' : "总价 #{product['total']} RP"}", choices)
        if selected == 0
          if owned
            equip_grants(product["grants"])
          elsif pbConfirmMessage("购买 #{product['name']}？\n总价 #{product['total']} RP\n当前 #{@shop.state['wallet']['balance']} RP\n购买后 #{@shop.state['wallet']['balance'] - product['total']} RP")
            order = @shop.purchase(product)
            filter
            pbMessage("购买成功。订单 #{order['id']}\n权益已保存至账号。")
            equip_grants(product["grants"]) if pbConfirmMessage("立即装备？")
          end
        elsif selected == 1
          @draft_grants = (@draft_grants + product["grants"]).uniq
        elsif selected == 2
          @draft_grants = []
        elsif selected == 3
          mine
        elsif selected == 4
          category = ui.choose("商品分类", CATEGORIES.map(&:first) + ["返回"])
          if category >= 0 && category < CATEGORIES.length
            @category, @index = category, 0
            filter
          end
        end
      end
    rescue Error => error
      dialog { pbMessage(KIFMultiplayer.display_text(error.message)) }
      @shop.refresh
      filter
    end
    def equip_grants(grants)
      slots = ShopData.copy(@shop.state["equipment"]["slots"])
      grants.each do |key|
        next unless @shop.state["entitlements"].include?(key)
        slots[ShopData.local["entitlements"][key]["slot"]] = key
      end
      @shop.equip(slots)
      pbMessage("已装备；同地图玩家将看到最新外观。")
    end
    def mine
      dialog do
        ui = UI.new(@shop.client)
        loop do
          choice = ui.choose("我的商城\nRP #{@shop.state['wallet']['balance']} · 市场币 #{@shop.state['market_wallet']['balance']}", ["已购装扮", "恢复原外观", "兑换点券码", "订单记录", "点券明细", "托管交易所", "获取点券说明", "返回"])
          case choice
          when 0
            keys = @shop.state["entitlements"]
            index = ui.choose("已购装扮", keys.map { |key| ShopData.local["entitlements"][key]["name"] } + ["返回"])
            equip_grants([keys[index]]) if index >= 0 && index < keys.length
          when 1 then @shop.equip({})
          when 2
            code = ui.enter("输入兑换码", "", 80)
            unless code.empty?
              receipt = @shop.redeem(code)
              pbMessage("兑换成功：#{receipt['amount']} #{receipt['currency']}")
            end
          when 3
            history("orders")
          when 4
            history("ledger")
          when 5 then MarketUI.new(@shop).run
          when 6 then pbMessage("点券通过服务器活动兑换码、奖励和补偿获得。\n首版未接入真实支付。主线金钱不可兑换。\n市场币为单独的服务器活动货币。")
          else break
          end
          @shop.refresh
          filter
        end
      end
    rescue Error => error
      dialog { pbMessage(KIFMultiplayer.display_text(error.message)) }
    end
    def history(kind)
      cursors = [0]
      loop do
        result = @shop.history(kind, cursors.last)
        rows = result[kind]
        lines = rows.map do |row|
          if kind == "orders"
            "#{row['name']} · #{row['total']} RP · #{row['status']}"
          else
            "#{row['currency']} #{row['amount'] > 0 ? '+' : ''}#{row['amount']} → #{row['balance']}"
          end
        end
        index = UI.new(@shop.client).choose(kind == "orders" ? "订单记录" : "点券明细", lines + ["上一页", "下一页", "返回"])
        if index >= 0 && index < rows.length
          row = rows[index]
          pbMessage(kind == "orders" ? "#{row['name']}\n订单 #{row['id']}\n#{row['total']} RP · #{row['status']}" : "#{row['currency']} #{row['amount']}\n来源 #{row['event']}\n余额 #{row['balance']}")
        elsif index == rows.length
          cursors.pop if cursors.length > 1
        elsif index == rows.length + 1
          cursors << result["next_cursor"] if result["next_cursor"]
        else
          return
        end
      end
    end
    def dispose
      if @preview
        @preview.bitmap.dispose if @preview.bitmap
        @preview.dispose
      end
      @canvas.dispose if @canvas
      @viewport.dispose if @viewport
    end
  end

  def self.open_shop
    previous_scene, previous_chatting = $scene, OnlineMode.chatting
    $scene = Object.new
    OnlineMode.chatting = true
    with_ui_fonts { ShopScene.new.run }
  rescue Error, StandardError => error
    pbMessage("商城：#{display_text(error.message)}")
    log_error(error)
  ensure
    OnlineMode.chatting = previous_chatting
    $scene = previous_scene
    refreshPlayerOutfit if $scene.respond_to?(:spritesetGlobal)
  end

  module ShopPauseEntry
    def pbShowCommands(commands)
      return super unless OnlineMode.active?
      choices = commands + ["商城"]
      loop do
        result = super(choices)
        return result unless result == commands.length
        pbHideMenu
        KIFMultiplayer.open_shop
        pbShowMenu
      end
    end
  end
  PokemonPauseMenu_Scene.prepend(ShopPauseEntry) if defined?(PokemonPauseMenu_Scene)
end
