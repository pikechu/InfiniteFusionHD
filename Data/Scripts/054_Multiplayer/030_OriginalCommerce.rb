module KIFMultiplayer
  class OriginalClient
    def commerce_read(kind, filters = {})
      raise Error, "交易读取类型无效。" unless %w[market trades].include?(kind)
      query = filters.map { |key, value| "#{key}=#{value}" }.join("&")
      raise Error, "市场筛选无效。" unless query =~ /\A[A-Za-z0-9_=&]*\z/
      response = @client.request("GET", "/v1/controlled/characters/#{@id}/#{kind}" + (query.empty? ? "" : "?#{query}"))
      if kind == "market"
        raise Error, "挂牌列表无效。" unless response["listings"].is_a?(Array) && response["mine"].is_a?(Array)
        rows = response["listings"] + response["mine"]
      else
        rows = response["offers"]
      end
      raise Error, "交易响应无效。" unless rows.is_a?(Array) && rows.length <= 100
      rows.each do |row|
        if kind == "market"
          raise Error, "挂牌响应无效。" unless row.is_a?(Hash) && row["id"].to_s =~ /\Acml_[a-f0-9]{32}\z/ && integer?(row["price"], 1, 1_000_000_000) && integer?(row["fee"], 0, row["price"]-1) && integer?(row["version"], 1, 9_007_199_254_740_991)
          validate_monster(row["monster"])
        else
          raise Error, "双方交易响应无效。" unless row.is_a?(Hash) && row["id"].to_s =~ /\Acto_[a-f0-9]{32}\z/ && row["terms"].is_a?(Hash) && row["terms"].length == 2 && row["terms_hash"].to_s =~ /\A[a-f0-9]{64}\z/
          row["terms"].each_value { |term| term.fetch("details").each { |monster| validate_monster(monster) } }
        end
      end
      response
    end
    def commerce_act(kind, action, fields)
      raise Error, "交易操作类型无效。" unless %w[market trades].include?(kind) && fields.is_a?(Hash)
      refresh
      response = @client.request("POST", "/v1/controlled/characters/#{@id}/#{kind}", fields.merge(
        "action" => action, "expected_revision" => @character["revision"],
        "expected_wallet_revision" => @character["wallet"]["revision"], "rules_hash" => @original["rules_hash"]), 30.0)
      accept(response)
    end
  end

  class OriginalCommerceUI < UI
    def show_monster(monster)
      data = GameData::Species.get(monster["species"].to_sym)
      dex = data.id_number
      paths = []
      if monster["egg_steps"] > 0
        paths << GameData::Species.egg_sprite_filename(data.id, monster["form"])
      elsif dex <= Settings::NB_POKEMON
        paths += [Settings::CUSTOM_BASE_SPRITES_FOLDER+"#{dex}.png", Settings::BATTLERS_FOLDER+"#{dex}/#{dex}.png", Settings::BATTLERS_FOLDER+"#{dex}.png"]
      else
        body, head = getBodyID(dex), getHeadID(dex)
        paths += [Settings::CUSTOM_BATTLERS_FOLDER_INDEXED+"#{head}/#{head}.#{body}.png", Settings::BATTLERS_FOLDER+"#{head}/#{head}.#{body}.png", Settings::BATTLERS_FOLDER+"#{head}.#{body}.png"]
      end
      path = paths.find { |candidate| candidate && pbResolveBitmap(candidate) }
      unless path
        pbMessage(monster_text(monster)+"\n素材缺失：安装此精灵图片后才能完成购买或最终确认。")
        return false
      end
      wrapper = AnimatedBitmap.new(path).recognizeDims()
      appearance = monster["appearance"]
      if monster["shiny"] && appearance
        omega = appearance.slice("pif_shiny", "body_shiny", "head_shiny").merge("dexNum" => dex)
        wrapper.pbGiveFinaleColor(appearance["red"],appearance["green"],appearance["blue"],appearance["hue"],appearance["krs"],omega)
      end
      viewport = Viewport.new(0,0,Graphics.width,Graphics.height)
      viewport.z = 100005
      sprite = Sprite.new(viewport)
      sprite.bitmap = wrapper.bitmap
      sprite.ox, sprite.oy = sprite.bitmap.width/2, sprite.bitmap.height/2
      sprite.x, sprite.y = Graphics.width/2, Graphics.height/4
      pbMessage(monster_text(monster)) { wrapper.update; sprite.bitmap = wrapper.bitmap }
      true
    ensure
      sprite&.dispose
      viewport&.dispose
      wrapper&.dispose
    end
    def main(model)
      @model = model
      loop do
        return unless perform { @model.refresh }
        choice = choose("原版交易中心 · GOLD #{@model.character['wallet']['balance']}", ["全球市场", "出售精灵", "我的挂牌与领取", "双方交易", "返回"])
        case choice
        when 0 then perform { browse }
        when 1 then perform { list_monster }
        when 2 then perform { browse(true) }
        when 3 then perform { trades }
        else return
        end
        return if @model.original["prompt"]
      end
    end
    def number(title, minimum, maximum, default = minimum)
      params = ChooseNumberParams.new
      params.setRange(minimum, maximum)
      params.setDefaultValue([[default, minimum].max, maximum].min)
      params.setCancelValue(minimum)
      pbMessageChooseNumber(title, params)
    end
    def monster_text(monster)
      "#{text(monster['name'])} / #{monster['species']} Lv.#{monster['level']}#{monster['shiny'] ? ' ★' : ''}\n" +
        "#{text(monster['nature'])} · #{text([monster['ability'],monster['ability2']].compact.join('/'))} · #{text(monster['item'] || '无携带物')}\n" +
        "IV #{monster['iv'].map { |key, value| "#{key}:#{value}" }.join(' ')}\nEV #{monster['ev'].values.join('/')}\n" +
        "招式 #{monster['moves'].map { |move| move['id'] }.join(' / ')}\n原训练师 #{text(monster['owner']['name'])} / #{monster['owner']['id']}\n#{monster['id']}"
    end
    def browse(mine = false)
      filters = {}
      unless mine
        species = enter("物种或融合编号，留空为全部", "", 64).upcase
        raise Error, "编号仅支持英文、数字和下划线。" unless species =~ /\A[A-Z0-9_]*\z/
        filters["species"] = species unless species.empty?
        filters["min_level"] = number("最低等级", 1, 100)
        filters["max_level"] = number("最高等级", filters["min_level"], 100, 100)
        filters["min_iv"] = number("最低 IV 总和", 0, 186)
      end
      page = 0
      loop do
        result = @model.commerce_read("market", filters.merge(mine ? {"mine_page" => page} : {"page" => page}))
        rows = result[mine ? "mine" : "listings"]
        labels = rows.map { |row| "#{text(row['monster']['name'])} Lv.#{row['monster']['level']} · #{row['price']} GOLD · #{row['status']}" }
        index = choose("#{mine ? '我的挂牌 / 记录' : '全球市场'} · 第 #{page+1} 页", labels + ["上一页", "下一页", "返回"])
        if index == rows.length
          page = [page-1, 0].max
        elsif index == rows.length+1
          page += 1 if result[mine ? "mine_has_more" : "has_more"]
        elsif index && index.between?(0, rows.length-1)
          row = rows[index]
          available = show_monster(row["monster"])
          seller = row["seller_identity"]
          pbMessage("售价 #{row['price']} GOLD · 成交费 #{row['fee']}\n卖家 #{text(seller['nickname'])} / #{seller['friend_code']}\n挂牌 #{row['id']}")
          next unless row["status"] == "active" || mine && row["status"] == "withdrawn"
          if mine
            action = result["as_of"] >= row["expires"] || row["status"] == "withdrawn" ? "claim" : "cancel"
            next unless pbConfirmMessage(action == "claim" ? "领取到期精灵回队伍或电脑？" : "撤销挂牌并收回精灵？")
            @model.commerce_act("market", action, {"listing_id" => row["id"], "expected_listing_version" => row["version"]})
          else
            next unless available
            next unless pbConfirmMessage("支付 #{row['price']} GOLD 购买？\n服务器交付到队伍或电脑，通信进化由服务器结算。")
            @model.commerce_act("market", "buy", {"listing_id" => row["id"], "expected_listing_version" => row["version"], "expected_price" => row["price"], "expected_fee" => row["fee"]})
          end
          return if @model.original["prompt"]
        else return
        end
      end
    end
    def selectable
      @model.original["view"]["monsters"].reject { |monster| monster["borrowed"] }
    end
    def list_monster
      rows = selectable
      index = choose("选择自有精灵挂牌", rows.map { |monster| "#{text(monster['name'])} Lv.#{monster['level']} · #{monster['id'][-6,6]}" } + ["返回"])
      return unless index && index.between?(0, rows.length-1)
      monster = rows[index]
      price = number("挂牌售价 GOLD", 1, 1_000_000_000)
      return unless pbConfirmMessage(monster_text(monster) + "\n售价 #{price} GOLD · 期限 7 天\n挂牌后精灵进入服务器托管，保留至少一只可战斗队员。确认上架？")
      @model.commerce_act("market", "list", {"monster_id" => monster["id"], "price" => price})
    end
    def edit_terms(current = nil)
      terms = {"monsters" => (current && current["monsters"] || []).dup, "items" => (current && current["items"] || []).map(&:dup), "gold" => current && current["gold"] || 0}
      loop do
        choice = choose("交易清单 · 精灵 #{terms['monsters'].length}/6 · 道具 #{terms['items'].length}/8 · GOLD #{terms['gold']}", ["编辑精灵", "编辑道具", "编辑金币", "保存清单", "放弃编辑"])
        case choice
        when 0
          rows = selectable
          index = choose("选择或移除精灵", rows.map { |monster| "#{terms['monsters'].include?(monster['id']) ? '✓' : '□'} #{text(monster['name'])} Lv.#{monster['level']}" } + ["返回"])
          next unless index && index.between?(0, rows.length-1)
          id = rows[index]["id"]
          if terms["monsters"].include?(id)
            terms["monsters"].delete(id)
          elsif terms["monsters"].length < 6
            pbMessage(monster_text(rows[index])); terms["monsters"] << id
          end
        when 1
          rows = @model.character["inventory"]
          index = choose("选择道具", rows.map { |item| "#{text(item['item'])} × #{item['quantity']}" } + ["返回"])
          next unless index && index.between?(0, rows.length-1)
          item = rows[index]
          quantity = number("交易数量（0 为移除）", 0, [item["quantity"],999].min)
          terms["items"].reject! { |entry| entry["item"] == item["item"] }
          terms["items"] << {"item" => item["item"], "quantity" => quantity} if quantity > 0 && terms["items"].length < 8
        when 2 then terms["gold"] = number("交易 GOLD", 0, @model.character["wallet"]["balance"], terms["gold"])
        when 3 then return terms
        else return nil
        end
      end
    end
    def trades
      loop do
        @model.refresh
        response = @model.commerce_read("trades")
        rows = response["offers"]
        index = choose("双方交易 · 清单变更后须重新锁定与确认", rows.map { |row| "#{row['id'][-8,8]} · #{row['status']} · 版本#{row['version']}" } + ["发起交易", "返回"])
        if index == rows.length
          target = enter("对方的 cc_ 角色编号（可在角色信息查看）", "", 35)
          next if target.empty?
          terms = edit_terms
          @model.commerce_act("trades", "invite", terms.merge("target" => target)) if terms
        elsif index && index.between?(0, rows.length-1)
          offer = rows[index]
          previews = []
          offer["terms"].each do |id, terms|
            party = (offer["participants"] || {})[id] || {"nickname" => "历史角色", "friend_code" => "未记录", "character_name" => id}
            pbMessage("#{text(party['nickname'])} / 好友码 #{party['friend_code']}\n角色 #{text(party['character_name'])} / #{id}\nGOLD #{terms['gold']}\n道具 #{terms['items'].map { |item| "#{item['item']} × #{item['quantity']}" }.join('、')}")
            terms["details"].each { |monster| previews << show_monster(monster) }
          end
          next unless offer["status"] == "open"
          action = choose("清单版本 #{offer['version']}\n已锁定 #{offer['locked'].length}/2 · 已最终确认 #{offer['confirmed'].length}/2", ["编辑我的清单", "锁定我的清单", "最终确认", "取消交易", "返回"])
          fields = {"offer_id" => offer["id"], "expected_offer_version" => offer["version"]}
          case action
          when 0
            terms = edit_terms(offer["terms"][@model.character["id"]])
            @model.commerce_act("trades", "edit", fields.merge(terms)) if terms
          when 1 then @model.commerce_act("trades", "lock", fields.merge("terms_hash" => offer["terms_hash"]))
          when 2
            next unless previews.all?
            next unless pbConfirmMessage("确认此版本全部精灵、道具和金币？\n双方最终确认相同清单后同时结算，结果可断线恢复。")
            @model.commerce_act("trades", "confirm", fields.merge("terms_hash" => offer["terms_hash"]))
          when 3 then @model.commerce_act("trades", "cancel", fields)
          end
          return if @model.original["prompt"]
        else return
        end
      end
    end
  end
end
