# Public trainer cards and independently versioned showcase drafts. These APIs
# only publish snapshots/references; there is no Pokemon receive/import action.
module KIFMultiplayer
  module CardData
    DEFAULT_AVATAR = "POKEMONTRAINER_Red"
    PUBLIC_FIELDS = %w[name owner iv ev].freeze
    BASE_FIELDS = %w[version species level form moves ability ability2 shiny appearance].freeze
    def self.check(condition, message); raise Error.new(message, "invalid_card") unless condition; end
    def self.code(value)
      check(value.is_a?(String) && value =~ /\A[A-F0-9]{8}\z/, "名片或展示代码必须为八位十六进制字符。")
      value
    end
    def self.avatar(value)
      check(Snapshot.identifier(value) && GameData::TrainerType.exists?(value), "头像类型不属于当前游戏数据，无法显示。")
      value
    end
    def self.avatar_path(value)
      avatar(value)
      # front_sprite_filename derives its path from the trusted registered
      # numeric trainer type; no network string is used as a file path.
      GameData::TrainerType.front_sprite_filename(value)
    end
    def self.visibility(values)
      check(values.is_a?(Array) && values.uniq == values && (values - PUBLIC_FIELDS).empty?, "展示公开字段不支持。")
      values
    end
    def self.public_snapshot(data, fields)
      Snapshot.validate(data)
      visibility(fields)
      result = TradeCodec.copy(data.select { |key, _| (BASE_FIELDS + fields).include?(key) })
      result["appearance"].delete("head_nickname") unless fields.include?("name")
      result
    end
    def self.validate_public(data, fields)
      visibility(fields)
      check(data.is_a?(Hash) && (data.keys - BASE_FIELDS - fields).empty? && (BASE_FIELDS + fields - data.keys).empty?, "公开展示字段缺失或包含未授权字段。")
      check(data["version"] == 1 && data["form"] == 0 && Snapshot.number(data["level"], 1, 100), "展示版本、形态或等级不支持。")
      Snapshot.registry(:Species, data["species"])
      Snapshot.registry(:Ability, data["ability"])
      Snapshot.registry(:Ability, data["ability2"], true)
      check([true, false].include?(data["shiny"]), "无效闪光标记。")
      Snapshot.validate_appearance(data["appearance"])
      check(fields.include?("name") || !data["appearance"].key?("head_nickname"), "隐藏的融合昵称不能出现在公开展示中。")
      moves = data["moves"]
      check(moves.is_a?(Array) && moves.length.between?(1, 4), "展示招式列表不支持。")
      moves.each do |move|
        check(move.is_a?(Hash) && move.keys.sort == %w[id pp ppup] && Snapshot.number(move["pp"], 0, 99) && Snapshot.number(move["ppup"], 0, 3), "展示招式资料无效。")
        Snapshot.registry(:Move, move["id"])
      end
      if fields.include?("name")
        check(data["name"].is_a?(String) && data["name"].length <= 32 && data["name"] !~ /[\x00-\x1f]/, "展示昵称无效。")
      end
      %w[iv ev].each do |field|
        next unless fields.include?(field)
        values = data[field]
        maximum = field == "iv" ? 31 : 252
        check(values.is_a?(Hash) && values.keys.sort == Snapshot::STATS.sort && values.values.all? { |n| Snapshot.number(n, 0, maximum) }, "展示 #{field} 无效。")
        check(values.values.inject(0, :+) <= 510, "展示 EV 总量不支持。") if field == "ev"
      end
      if fields.include?("owner")
        owner = data["owner"]
        check(owner.is_a?(Hash) && owner.keys.sort == %w[gender id language name] && Snapshot.number(owner["id"], 0, 0xffffffff) && Snapshot.number(owner["gender"], 0, 2) && Snapshot.number(owner["language"], 0, 10), "展示原训练师字段无效。")
        check(owner["name"].is_a?(String) && owner["name"].length <= 32 && owner["name"] !~ /[\x00-\x1f]/, "展示原训练师名无效。")
      end
      data
    end
    def self.showcase(value)
      check(value.is_a?(Hash), "展示响应无效。")
      code(value["code"])
      check(Snapshot.identifier(value["owner_id"]) && Snapshot.number(value["version"], 1, 1_000_000), "展示身份或版本无效。")
      validate_public(value["snapshot"], value["public_fields"])
      value
    end
    def self.card(value)
      check(value.is_a?(Hash) && Snapshot.identifier(value["id"]), "名片响应无效。")
      code(value["friend_code"])
      avatar(value["avatar"] || DEFAULT_AVATAR)
      check(value["nickname"].is_a?(String) && value["nickname"].length <= 32 && value["nickname"] !~ /[\x00-\x1f]/, "名片昵称无效。")
      check([true, false].include?(value["show_badges"]), "名片徽章公开设置无效。")
      check(value["badges"].is_a?(Array) && value["badges"].length <= 1000, "名片徽章列表无效。")
      check(value["show_badges"] || value["badges"].empty?, "关闭公开时收到不应公开的徽章。")
      value["badges"].each do |badge|
        check(badge.is_a?(Hash) && (badge.keys - %w[id kind boss_id gym_code dungeon_id]).empty? && Snapshot.identifier(badge["id"]) && %w[boss_medal gym_medal dungeon_medal].include?(badge["kind"]), "名片徽章字段不支持。")
        %w[boss_id gym_code dungeon_id].each { |key| check(Snapshot.identifier(badge[key]), "无效徽章来源。") if badge.key?(key) }
      end
      check(value["showcases"].is_a?(Array) && value["showcases"].length <= 6, "名片展柜最多六个引用。")
      value["showcases"].each { |entry| showcase(entry); check(entry["owner_id"] == value["id"], "名片包含他人展示。") }
      value
    end
  end

  class CardSession
    attr_reader :client
    def initialize(client); @client = client; end
    def account; @client.profile.account; end
    def save; @client.profile.save; end
    def change(&block); LocalJournal.change(@client.profile, &block); end
    def mine; CardData.card(@client.request("GET", "/v1/cards/me")["card"]); end
    def find(friend_code); CardData.card(@client.request("GET", "/v1/cards/#{CardData.code(friend_code)}")["card"]); end
    def owned_showcases
      values = @client.request("GET", "/v1/showcases")["showcases"]
      CardData.check(values.is_a?(Array), "我的展示列表响应无效。")
      values.each { |value| CardData.showcase(value); CardData.check(value["owner_id"] == @client.player_id, "我的展示列表混入其他身份。") }
      change do
        codes = account["showcase_codes"] ||= []
        codes << account["showcase_code"] if account["showcase_code"] && !codes.include?(account["showcase_code"])
        values.each { |value| codes << value["code"] unless codes.include?(value["code"]) }
      end
      values
    end
    def update_card(avatar, show_badges, codes)
      CardData.avatar(avatar || CardData::DEFAULT_AVATAR)
      CardData.check([true, false].include?(show_badges) && codes.is_a?(Array) && codes.length <= 6 && codes.uniq == codes, "名片设置无效。")
      codes.each { |value| CardData.code(value) }
      payload = { "avatar" => avatar || CardData::DEFAULT_AVATAR, "show_badges" => show_badges, "showcases" => codes.dup }
      change { account["card_settings_draft"] = payload }
      result = CardData.card(@client.request("POST", "/v1/cards/me", payload)["card"])
      change { account.delete("card_settings_draft") }
      result
    end
    def drafts; account["showcase_drafts"] ||= {}; end
    def prepare_draft(pokemon, public_fields, code = nil)
      @client.recover_pending
      if code
        CardData.code(code)
        previous = CardData.showcase(@client.request("GET", "/v1/showcases/#{code}")["showcase"])
        raise Error, "不能更新其他身份的展示。" unless previous["owner_id"] == @client.player_id
        raise Error, "托管资产展示由服务器快照固定，不能用本地精灵覆盖。请从托管收藏箱重新发布。" if previous["source"] == "server_managed"
      end
      CardData.visibility(public_fields)
      snapshot = Snapshot.export(pokemon)
      id = KIFMultiplayer.operation_id
      change do
        drafts[id] = { "id" => id, "code" => code, "snapshot" => TradeCodec.copy(snapshot), "public_fields" => public_fields.dup,
          "request_id" => KIFMultiplayer.operation_id, "owner_id" => @client.player_id, "created_at" => Time.now.to_i }
      end
      drafts[id]
    end
    def preview(draft)
      raise Error, "此草稿属于其他身份。" unless draft["owner_id"] == @client.player_id
      CardData.public_snapshot(draft["snapshot"], draft["public_fields"])
    end
    def publish_draft(id)
      draft = drafts[id]
      raise Error, "草稿不存在。" unless draft
      preview(draft)
      payload = { "request_id" => draft["request_id"], "snapshot" => draft["snapshot"], "public_fields" => draft["public_fields"] }
      payload["code"] = draft["code"] if draft["code"]
      result = CardData.showcase(@client.request("POST", "/v1/showcases", payload)["showcase"])
      raise Error, "发布结果不属于当前身份。" unless result["owner_id"] == @client.player_id
      change do
        codes = account["showcase_codes"] ||= []
        codes << result["code"] unless codes.include?(result["code"])
        account["showcase_code"] = result["code"] # legacy single-entry UI interop
        drafts.delete(id)
      end
      result
    end
    def discard_draft(id)
      @client.recover_pending
      change { drafts.delete(id) }
    end
    def unpublish(code)
      CardData.code(code)
      @client.request("POST", "/v1/showcases/#{code}/unpublish")
      change { account.delete("showcase_code") if account["showcase_code"] == code }
    end
  end

  class CardAvatar
    attr_reader :sprite, :bitmap
    def initialize(avatar, viewport = nil)
      path = CardData.avatar_path(avatar || CardData::DEFAULT_AVATAR)
      raise Error, "头像类型兼容，但本机缺少对应头像素材。" unless path
      @owns_viewport = viewport.nil?
      @viewport = viewport || Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 99998 if @owns_viewport
      @bitmap = AnimatedBitmap.new(path)
      @sprite = Sprite.new(@viewport)
      @sprite.bitmap = @bitmap.bitmap
      @sprite.ox = @sprite.bitmap.width / 2
      @sprite.oy = @sprite.bitmap.height
      @sprite.x, @sprite.y = Graphics.width / 2, Graphics.height / 2
    rescue StandardError
      dispose
      raise
    end
    def update
      @bitmap.update
      @sprite.bitmap = @bitmap.bitmap
      @sprite.update
    end
    def dispose
      @sprite.dispose if @sprite && !@sprite.disposed?
      @bitmap.dispose if @bitmap
      @viewport.dispose if @viewport && @owns_viewport && !@viewport.disposed?
      @sprite, @bitmap, @viewport = nil, nil, nil
    end
  end

  def self.open_card_menu(client); with_ui_fonts { CardUI.new(client).main }; end
  class CardUI
    def initialize(client); @client, @ui, @session = client, UI.new(client), CardSession.new(client); end
    def text(value); KIFMultiplayer.display_text(value); end
    def show_public_showcase(value)
      CardData.showcase(value)
      pbMessage(value["source"] == "server_managed" ? "来源：服务器托管资产的展示引用。" : "来源：本地精灵的休闲展示快照。")
      @ui.show_showcase(value)
    end
    def main
      loop do
        choice = @ui.choose("训练师名片与精灵展示\n展柜只保存展示引用，不会生成精灵。", ["查看我的名片", "头像、公开徽章与六槽展柜", "输入好友码查看名片", "管理多个精灵展示", "恢复保存的展示草稿", "返回"])
        return if choice < 0 || choice == 5
        @ui.perform do
          case choice
          when 0 then show_card(@session.mine)
          when 1 then edit_card
          when 2
            code = @ui.enter("输入八位好友码", "", 8).upcase
            show_card(@session.find(code)) unless code.empty?
          when 3 then manage_showcases
          when 4 then draft_menu
          end
        end
      end
    end
    def show_card(card)
      CardData.card(card)
      badges = { "boss_medal" => "Boss 纪念章", "gym_medal" => "AI 道馆纪念章", "dungeon_medal" => "合作副本纪念章" }.map do |kind, label|
        count = card["badges"].count { |badge| badge["kind"] == kind }
        count > 0 ? "#{label} #{count} 枚" : nil
      end.compact
      heading = "#{text(card['nickname'])} · #{text(card['friend_code'])}\n徽章：#{card['show_badges'] ? (badges.empty? ? '尚无纪念章' : badges.join(' / ')) : '未公开'}\n展柜 #{card['showcases'].length} / 6"
      avatar = nil
      begin
        avatar = CardAvatar.new(card["avatar"])
        pbMessage(heading) { avatar.update }
      rescue Error, StandardError => error
        KIFMultiplayer.log_error(error)
        pbMessage(heading + "\n本机头像资源不完整。")
      ensure
        avatar.dispose if avatar
      end
      loop do
        index = @ui.choose("名片展柜", card["showcases"].map { |value| "#{text(value['snapshot']['species'])} · #{text(value['code'])} v#{value['version']}" } + ["返回"])
        return if index < 0 || index >= card["showcases"].length
        show_public_showcase(card["showcases"][index])
      end
    end
    def edit_card
      current = @session.mine
      draft = @session.account["card_settings_draft"] || { "avatar" => current["avatar"], "show_badges" => current["show_badges"], "showcases" => current["showcases"].map { |value| value["code"] } }
      avatar = draft["avatar"] || CardData::DEFAULT_AVATAR
      if pbConfirmMessage("更换名片头像？")
        avatars = []
        avatar_labels = []
        GameData::TrainerType.each do |value|
          if GameData::TrainerType.front_sprite_filename(value.id)
            avatars << value.id.to_s
            gender = value.gender == 0 ? "男" : (value.gender == 1 ? "女" : "其他")
            avatar_labels << "#{text(value.name)} · #{gender}"
          end
          KIFMultiplayer.pump if avatars.length % 16 == 0
        end
        index = @ui.choose("选择头像", avatar_labels + ["取消"])
        if index >= 0 && index < avatars.length
          avatar = avatars[index]
          preview_avatar = nil
          begin
            preview_avatar = CardAvatar.new(avatar)
            pbMessage("所选头像预览。") { preview_avatar.update }
          ensure
            preview_avatar.dispose if preview_avatar
          end
        end
      end
      show_badges = pbConfirmMessage("自愿公开已领取的 Boss、AI 道馆和副本纪念章？")
      available = @session.owned_showcases
      selected = draft["showcases"] & available.map { |value| value["code"] }
      loop do
        labels = available.map { |value| "#{selected.include?(value['code']) ? '●' : '○'} #{text(value['snapshot']['species'])} · #{text(value['code'])}" }
        index = @ui.choose("选择最多六个公开展柜引用（#{selected.length} / 6）", labels + ["保存名片", "取消"])
        return if index < 0 || index == labels.length + 1
        break if index == labels.length
        code = available[index]["code"]
        if selected.include?(code)
          selected.delete(code)
        elsif selected.length < 6
          selected << code
        else
          pbMessage("展柜最多六个引用。")
        end
      end
      @session.update_card(avatar, show_badges, selected)
      pbMessage("名片已保存。展示或托管资产下架、转让后，服务器会移除无效引用。")
    end
    def manage_showcases
      loop do
        values = @session.owned_showcases
        choice = @ui.choose("我的多个精灵展示\n#{values.length} 个正在发布；失败草稿保留在本机。", ["发布一个新展示", "查看 / 更新 / 下架已有展示", "输入分享码查看与收藏", "我的收藏引用", "展示草稿", "返回"])
        return if choice < 0 || choice == 5
        @ui.perform do
          case choice
          when 0 then prepare_showcase
          when 1
            raise Error, "尚无正在发布的展示。" if values.empty?
            index = @ui.choose("选择展示", values.map { |value| "#{text(value['snapshot']['species'])} · #{text(value['code'])} v#{value['version']}" } + ["返回"])
            next if index < 0 || index >= values.length
            value = values[index]
            actions = value["source"] == "server_managed" ? %w[view unpublish return] : %w[view update unpublish return]
            labels = { "view" => "查看", "update" => "从本地精灵创建更新草稿", "unpublish" => "下架", "return" => "返回" }
            action = @ui.choose("展示 #{text(value['code'])}", actions.map { |key| labels[key] })
            case actions[action]
            when "view" then show_public_showcase(value)
            when "update" then prepare_showcase(value["code"])
            when "unpublish" then @session.unpublish(value["code"]) if pbConfirmMessage("下架此展示？其他展示不变。")
            end
          when 2
            code = @ui.enter("输入展示分享码", "", 8).upcase
            next if code.empty?
            value = CardData.showcase(@client.request("GET", "/v1/showcases/#{CardData.code(code)}")["showcase"])
            show_public_showcase(value)
            if pbConfirmMessage("收藏此展示引用？不会生成精灵。")
              favorites = @session.account["favorites"] ||= []
              favorites << code unless favorites.include?(code)
              @session.save
            end
          when 3
            values = @session.account["favorites"] || []
            raise Error, "尚无收藏引用。" if values.empty?
            index = @ui.choose("收藏引用", values + ["返回"])
            show_public_showcase(CardData.showcase(@client.request("GET", "/v1/showcases/#{CardData.code(values[index])}")["showcase"])) if index >= 0 && index < values.length
          when 4 then draft_menu
          end
        end
      end
    end
    def prepare_showcase(code = nil)
      pokemon = @ui.choose_pokemon
      return unless pokemon
      fields = []
      CardData::PUBLIC_FIELDS.zip(["昵称与融合头部昵称", "原训练师", "IV", "EV"]).each { |field, label| fields << field if pbConfirmMessage("公开#{label}？") }
      draft = @session.prepare_draft(pokemon, fields, code)
      show_draft(draft)
    end
    def show_draft(draft)
      public = @session.preview(draft)
      @ui.show_showcase({ "code" => draft["code"] || "尚未发布", "version" => "草稿", "snapshot" => public })
      pbMessage("完整快照和公开设置已保存为本地草稿。失败可以重试；旧公开版本在更新成功前继续保留。")
      if pbConfirmMessage("现在发布这个固定草稿？")
        value = @session.publish_draft(draft["id"])
        pbMessage("展示已发布：#{text(value['code'])} · 版本 #{value['version']}")
      end
    end
    def draft_menu
      loop do
        values = @session.drafts.values
        raise Error, "没有待发布的草稿。" if values.empty?
        index = @ui.choose("已保存的展示草稿", values.map { |draft| "#{draft['code'] ? '更新 ' + text(draft['code']) : '新展示'} · #{text(draft['snapshot']['species'])}" } + ["返回"])
        return if index < 0 || index >= values.length
        draft = values[index]
        action = @ui.choose("草稿 #{text(draft['id'])}", ["预览 / 重试发布", "丢弃此草稿", "返回"])
        if action == 0
          @ui.perform { show_draft(draft) }
        elsif action == 1 && pbConfirmMessage("只丢弃这个本地草稿？已发布版本不变。")
          @session.discard_draft(draft["id"])
        end
      end
    end
  end
end
