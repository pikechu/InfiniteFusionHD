module KIFMultiplayer
  class MarketUI
    def initialize(shop)
      @shop, @client, @ui = shop, shop.client, UI.new(shop.client)
    end
    def request(action, body = {})
      @client.request("POST", "/v1/market/" + action, body.merge("session_id" => @shop.session_id))
    rescue UncertainRequest
      @client.recover_pending || raise
    end
    def run
      loop do
        wallet = @client.request("GET", "/v1/shop/wallet")["market_wallet"]
        choice = @ui.choose("服务器托管交易所 · 市场币 #{wallet['balance']}\n仅托管收藏资产；成交后仍保留在托管收藏箱。", ["浏览挂牌", "上架收藏", "我的挂牌", "交易记录", "返回"])
        case choice
        when 0 then browse
        when 1 then list
        when 2 then browse(true)
        when 3
          rows = @client.request("GET", "/v1/market/history")["receipts"]
          pbMessage("暂无记录。") if rows.empty?
          rows.each_slice(6) { |page| pbMessage(page.map { |row| "#{row['kind']} · #{row['price']} 市场币\n#{row['listing_id']}" }.join("\n")) }
        else return
        end
      rescue Error => error
        pbMessage(KIFMultiplayer.display_text(error.message))
      end
    end
    def browse(mine = false)
      keyword, sorting = "_", "recent"
      unless mine
        keyword = @ui.enter("筛选精灵或融合编号，留空显示全部", "", 40)
        keyword = "_" if keyword.empty?
        raise Error, "请输入精灵英文或融合编号（字母、数字、点、横线）。" unless keyword =~ /\A[A-Za-z0-9_.-]{1,40}\z/
        sort = @ui.choose("排序", ["最新上架", "价格从低到高", "价格从高到低"])
        sorting = sort == 1 ? "low" : sort == 2 ? "high" : "recent"
      end
      offsets, page, loaded = [0], 0, nil
      loop do
        if loaded != offsets.last
          response = @client.request("GET", "/v1/market/#{mine ? 'mine' : 'listings'}/page/#{offsets.last}/#{sorting}/#{keyword}")
          rows, next_offset, loaded = response["listings"], response["next_offset"], offsets.last
        end
        current = rows[page * 8, 8].to_a
        labels = current.map { |row| "#{row['snapshot']['species']} Lv#{row['snapshot']['level']} · #{row['price']}币 · #{row['status']}" }
        selected = @ui.choose("#{mine ? '我的挂牌' : '托管精灵'} · 第 #{page + 1} 页", labels + ["上一页", "下一页", "返回"])
        if selected == labels.length
          if page > 0
            page -= 1
          elsif offsets.length > 1
            offsets.pop
            page = 2
          end
        elsif selected == labels.length + 1
          if (page + 1) * 8 < rows.length
            page += 1
          elsif next_offset
            offsets << next_offset
            page = 0
          end
        elsif selected < 0 || selected >= labels.length
          return
        else
          row = current[selected]
          snapshot = row["snapshot"]
          details = "#{snapshot['species']} Lv#{snapshot['level']}\n特性：#{snapshot['ability']} / #{snapshot['ability2']}\n#{snapshot['shiny'] ? '闪光' : '普通'} · #{row['price']} 市场币\n到期：#{Time.at(row['expires_at']).utc.strftime('%m-%d %H:%M UTC')}"
          if mine
            if row["status"] == "active" && pbConfirmMessage(details + "\n撤回此挂牌？")
              request("cancel/" + row["id"])
              return
            else
              pbMessage(details)
            end
          elsif !row["mine"] && pbConfirmMessage(details + "\n确认购买到托管收藏箱？")
            receipt = request("buy/" + row["id"], {"expected_price" => row["price"]})["receipt"]
            pbMessage("购买成功。资产 #{receipt['asset_id']}\n可在托管收藏箱展示或交换。")
            return
          else
            pbMessage(details)
          end
        end
      end
    end
    def list
      assets = CollectionClient.new(@client).refresh.reject { |asset| asset["locked"] }
      if assets.empty?
        pbMessage("没有可上架的未锁定托管收藏。\n可先在联机的托管收藏箱领取初始收藏。")
        return
      end
      index = @ui.choose("选择上架收藏", assets.map { |asset| "#{asset['snapshot']['species']} · #{asset['id'][-8, 8]}" } + ["返回"])
      return unless index >= 0 && index < assets.length
      text = @ui.enter("一口价（1～1000000000 市场币）", "100", 10)
      raise Error, "请输入正整数价格。" unless text =~ /\A[1-9][0-9]{0,9}\z/ && text.to_i <= 1_000_000_000
      return unless pbConfirmMessage("以 #{text} 市场币上架？\n挂牌七天，上架期间资产锁定；最多十件。")
      receipt = request("listings", {"asset_id" => assets[index]["id"], "price" => text.to_i})["receipt"]
      pbMessage("上架成功：#{receipt['listing_id']}")
    end
  end
end
