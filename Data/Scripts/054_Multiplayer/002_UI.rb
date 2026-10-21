module KIFMultiplayer
  def self.client
    @client ||= Client.new
  end

  def self.display_text(value)
    value.to_s.gsub("\\", "＼").gsub("<", "＜").gsub(">", "＞").gsub(/[\x00-\x08\x0b-\x1f]/, "")
  end

  module UIDownloadPreference
    def download_sprites
      Thread.current[:kif_multiplayer_ui_presentation] ? 1 : super
    end
  end

  module UIColorPreference
    def shinyadvanced
      Thread.current[:kif_multiplayer_ui_presentation] ? 2 : super
    end
  end

  def self.with_ui_fonts
    # The old native sprite downloader calls Ruby APIs without the GVL. Avoid
    # asset HTTP while multiplayer workers run; use installed/fallback sprites.
    # Override getters on this thread only: TradeSave can serialize the full
    # original System while this UI is open, so its stored ivars must not change.
    system = defined?($PokemonSystem) && $PokemonSystem
    if system
      system.class.prepend(UIDownloadPreference) if system.respond_to?(:download_sprites) && !system.class.ancestors.include?(UIDownloadPreference)
      system.class.prepend(UIColorPreference) if system.respond_to?(:shinyadvanced) && !system.class.ancestors.include?(UIColorPreference)
    end
    previous_presentation = Thread.current[:kif_multiplayer_ui_presentation]
    fonts = defined?(Font) && defined?(MessageConfig) && Font.exist?("Noto Sans SC")
    previous = [MessageConfig.pbGetSystemFontName, MessageConfig.pbGetSmallFontName,
                MessageConfig.pbGetNarrowFontName, Font.default_name] if fonts
    begin
      # All received channels were checked against 0..25. The ordinary 1-mode
      # getter would replace valid advanced colors (>11) with new random ones.
      Thread.current[:kif_multiplayer_ui_presentation] = true
      if fonts
        MessageConfig.pbSetSystemFontName("Noto Sans SC")
        MessageConfig.pbSetSmallFontName("Noto Sans SC")
        MessageConfig.pbSetNarrowFontName("Noto Sans SC")
        Font.default_name = "Noto Sans SC"
      end
      yield
    ensure
      Thread.current[:kif_multiplayer_ui_presentation] = previous_presentation
      if fonts
        MessageConfig.pbSetSystemFontName(previous[0])
        MessageConfig.pbSetSmallFontName(previous[1])
        MessageConfig.pbSetNarrowFontName(previous[2])
        Font.default_name = previous[3]
      end
    end
  end

  def self.open_menu
    previous_scene = $scene
    # Online menus can wait much longer than a local dialogue. Native message
    # windows must not run the original map's events/player/transfers meanwhile.
    $scene = Object.new
    with_ui_fonts { UI.new(client).main }
  rescue Error => error
    pbMessage("联机：#{display_text(error.message)}")
  rescue StandardError => error
    # An optional network feature must not make the single-player menu unusable.
    pbMessage("联机暂时不可用（#{error.class}）。请查看联机日志。")
    log_error(error)
  ensure
    $scene = previous_scene
  end

  def self.log_error(error)
    directory = defined?(System) && System.respond_to?(:data_directory) ? System.data_directory : "UserData"
    Dir.mkdir(directory) unless File.directory?(directory)
    File.open(File.join(directory, "multiplayer-errors.log"), "a") do |file|
      file.puts("#{Time.now.utc} #{CLIENT_BUILD} #{error.class}: #{error.message}")
      file.puts((error.backtrace || []).take(12))
    end
  rescue StandardError
    nil
  end

  class UI
    def initialize(client)
      @client = client
    end
    def text(value); KIFMultiplayer.display_text(value); end
    def choose(title, choices)
      pbMessage(title, choices, choices.length)
    end
    def enter(title, initial = "", length = 64)
      pbMessageFreeText(title, initial, false, length).to_s.strip
    end
    def perform
      yield
    rescue Error => error
      message = text(error.message)
      if error.details
        message += "\n" + text(WireJSON.dump(error.details))[0, 500]
      end
      pbMessage(message)
      nil
    end

    def connect
      name = defined?($Trainer) && $Trainer ? $Trainer.name.to_s : "Trainer"
      @client.connect(name)
    end

    def main
      loop do
        identity = @client.identity
        heading = "联机 #{CLIENT_BUILD}\n#{text(@client.server)}\n"
        heading += identity ? "#{text(identity['nickname'])} · #{text(identity['friend_code'])}" : "尚未连接"
        heading += @client.profile.account["connected"] ? "（已连接）" : "（已断开）"
        commands = ["服务器与身份", "创建好友单打房间", "加入房间", "恢复当前房间", "训练师名片与精灵展示", "合作 Boss / 固定副本", "道馆挑战与回放", "交换与托管收藏", "租借杯与走动大厅", "地图与世界聊天", "返回"]
        command = choose(heading, commands)
        break if command < 0 || command == commands.length - 1
        perform do
          case command
          when 0 then settings
          when 1
            connect
            name = enter("房间名称", "好友单打", 40)
            next if name.empty?
            result = @client.request("POST", "/v1/rooms", { "name" => name, "compatibility" => @client.compatibility })
            room = result["room"]
            @client.room_code = room["code"]
            room_menu(room)
          when 2
            connect
            code = enter("输入好友房间码", "", 12).upcase
            next if code.empty?
            result = @client.request("POST", "/v1/rooms/#{code}/join", { "compatibility" => @client.compatibility })
            @client.room_code = result["room"]["code"]
            result["room"]["mode"] == "rental_singles" ? KIFMultiplayer.run_rental(@client, result["room"]) : room_menu(result["room"])
          when 3
            connect
            room = recover_room
            next unless room
            room["mode"] == "rental_singles" ? KIFMultiplayer.run_rental(@client, room) : room_menu(room)
          when 4
            connect
            KIFMultiplayer.open_card_menu(@client)
          when 5
            mode = choose("合作玩法", ["双人合作 Boss", "固定路线合作副本", "返回"])
            KIFMultiplayer.open_boss_menu(@client) if mode == 0
            KIFMultiplayer.open_dungeon_menu(@client) if mode == 1
          when 6
            mode = choose("异步挑战与回放", ["玩家配置的 AI 道馆", "战斗回放分享", "返回"])
            KIFMultiplayer.open_gym_menu(@client) if mode == 0
            KIFMultiplayer.open_replay_menu(@client) if mode == 1
          when 7
            connect
            mode = choose("交换与收藏\n本地休闲个体与服务器托管资产分区。", ["好友休闲交换", "在线奇迹交换池", "服务器托管收藏箱", "返回"])
            KIFMultiplayer.open_trade_menu(@client) if mode == 0
            KIFMultiplayer.open_pool_menu(@client) if mode == 1
            KIFMultiplayer.open_collection_menu(@client) if mode == 2
          when 8
            mode = choose("休闲联机", ["随机租借杯", "可走动大厅", "返回"])
            KIFMultiplayer.open_rental_menu(@client) if mode == 0
            KIFMultiplayer.open_hall_menu(@client) if mode == 1
          when 9
            KIFMultiplayer.open_chat
          end
        end
      end
    end

    def recover_room
      if @client.room_code
        begin
          room = @client.request("GET", "/v1/rooms/#{@client.room_code}")["room"]
          return room if room && room["status"] != "closed"
        rescue Error => error
          raise unless %w[room_not_found room_expired not_member].include?(error.code)
        end
      end
      # The create/join response can arrive just before a profile write fails.
      # Query membership instead of guessing that no room was ever created.
      rooms = @client.request("GET", "/v1/rooms")["rooms"]
      unless rooms.is_a?(Array) && rooms.length <= 100 && rooms.all? { |room| room.is_a?(Hash) && room["code"].is_a?(String) && room["code"] =~ /\A[A-Z0-9]{4,12}\z/ }
        raise Error, "房间恢复响应无效。"
      end
      raise Error, "没有可恢复的房间。" if rooms.empty?
      index = rooms.length == 1 ? 0 : choose("恢复我仍在其中的房间", rooms.map { |room| "#{text(room['name'])} · #{text(room['code'])} · #{text(room['status'])}" } + ["返回"])
      return nil unless index >= 0 && index < rooms.length
      @client.room_code = rooms[index]["code"]
      rooms[index]
    end

    def settings
      loop do
        command = choose("服务器与身份\n#{text(@client.server)}", ["设置服务器", "连接测试与登录", "训练师名片", "导出恢复码", "用恢复码登录", "断开联机", "返回"])
        break if command < 0 || command == 6
        perform do
          case command
          when 0
            url = enter("本机/局域网填写 http://地址:8765；公网必须使用可信 HTTPS 服务。", @client.server, 120)
            @client.profile.server = url unless url.empty?
          when 1
            connect
            pbMessage("连接成功。协议与规则版本兼容。\n#{text(@client.identity['friend_code'])}")
          when 2
            connect
            pbMessage("#{text(@client.identity['nickname'])}\n好友码：#{text(@client.identity['friend_code'])}\n联机 ID：#{text(@client.player_id)}\n本地训练师 ID 不作为登录凭据。")
          when 3
            connect
            code = @client.profile.account["recovery_code"]
            if code
              filename = @client.profile.path.sub(/\.json\z/, "-recovery.txt")
              File.open(filename, "wb") { |file| file.write("Server: #{@client.server}\nRecovery code: #{code}\nKeep this private. It grants control of your multiplayer identity.\n") }
              pbMessage("恢复码已导出到：\n#{text(filename)}\n请私密保管，不要发给其他玩家。")
            else
              pbMessage("此设备没有保存恢复码。请使用首次连接设备导出的恢复码。")
            end
          when 4
            code = enter("输入私密恢复码", "", 120)
            @client.recover_identity(code) unless code.empty?
          when 5
            @client.disconnect
            pbMessage("已断开联机。单机功能可以继续使用。")
          end
        end
      end
    end

    def room_summary(room)
      mode = room["mode"] == "coop_boss" ? "双人合作 Boss" : "50 级六选三单打"
      lines = ["#{text(room['name'])} · 房间码 #{text(room['code'])}", "状态：#{text(room['status'])} · #{mode}"]
      if room["boss"]
        boss = room["boss"]
        lines << "#{text(boss['name'])} v#{boss['version']} · #{text(boss['difficulty'])} · Lv.#{boss['level']}"
      end
      (room["members"] || []).each do |member|
        status = member["ready"] ? "已准备" : "未准备"
        own = member["id"] == @client.player_id ? "（你）" : ""
        lines << "#{text(member['nickname'])}#{own}：#{status}，已选 #{member['selected_count'].to_i} 只"
      end
      lines << "再战：双方重新准备，再由房主点击开始。" if room["status"] == "settled"
      lines.join("\n")
    end

    def room_menu(room)
      code = room["code"]
      loop do
        choices = ["刷新 / 进入已开始对战", "候选队伍与三只顺序", room["mode"] == "coop_boss" ? "查看队友配招" : "查看双方候选物种", "准备 / 取消准备", "开始 / 再战（房主）", "房间名称（房主）", "留在房间并返回", "离开 / 关闭房间"]
        command, room = live_room_choice(room, choices)
        break if command < 0 || command == 6
        performed = perform do
          room = @client.request("GET", "/v1/rooms/#{code}")["room"]
          if room["status"] == "closed"
            @client.room_code = nil
            pbMessage("房间已关闭。")
            return
          end
          case command
          when 0
            if room["battle_id"] && ["in_battle", "playing", "battle", "settled", "finished"].include?(room["status"])
              launch_battle(room)
            end
          when 1
            select_team(code)
          when 2
            lines = []
            room["members"].each do |member|
              names = (member["candidates"] || []).map { |p| text(p["species"]) }
              lines << "#{text(member['nickname'])}：#{names.empty? ? '尚未提交' : names.join(' / ')}"
            end
            if room["mode"] == "coop_boss"
              room["members"].each do |member|
                (member["team"] || []).each do |pokemon|
                  lines << "#{text(pokemon['species'])}：#{pokemon['moves'].map { |m| text(m['id']) }.join('/')} · #{text(pokemon['ability'])}"
                end
              end
            end
            notice = room["mode"] == "coop_boss" ? "合作模式向队友公开完整参赛配置。" : "实际三只、顺序、招式与道具不会从候选预览公开。"
            pbMessage(lines.join("\n") + "\n" + notice)
          when 3
            member = room["members"].find { |m| m["id"] == @client.player_id }
            @client.request("POST", "/v1/rooms/#{code}/ready", { "ready" => !member["ready"] })
          when 4
            raise Error, "只有房主可以开始对战。" unless room["host_id"] == @client.player_id
            result = @client.request("POST", "/v1/rooms/#{code}/start")
            launch_battle(result["room"] || room.merge("battle_id" => result["battle_id"]))
          when 5
            name = enter("房间名称", room["name"], 40)
            @client.request("POST", "/v1/rooms/#{code}/configure", { "name" => name }) unless name.empty?
          when 7
            next unless pbConfirmMessage(room["host_id"] == @client.player_id ? "关闭此房间？" : "离开此房间？")
            @client.request("POST", "/v1/rooms/#{code}/leave")
            @client.room_code = nil
            return
          end
          true
        end
        # A network failure leaves the known room available for explicit recovery.
        if performed
          refreshed = perform { @client.request("GET", "/v1/rooms/#{code}")["room"] }
          room = refreshed if refreshed
        end
      end
    end

    def live_room_choice(room, choices)
      previous_update = @client.wait_update
      message = pbCreateMessageWindow
      window = Window_CommandPokemonEx.new(choices)
      window.z = 99999
      window.resizeToFit(choices)
      pbPositionNearMsgWindow(window, message, :right)
      @client.wait_update = proc do
        window.update
        message.update
        raise Error.new("Room menu closed", "room_menu_closed") if Input.trigger?(Input::BACK)
      end
      next_poll, failures, last_heading = Time.now, 0, nil
      loop do
        heading = room_summary(room)
        if heading != last_heading
          message.text = heading
          last_heading = heading
        end
        Graphics.update
        Input.update
        window.update
        message.update
        return [6, room] if Input.trigger?(Input::BACK)
        return [window.index, room] if Input.trigger?(Input::USE)
        next if Time.now < next_poll
        begin
          room = @client.request("GET", "/v1/rooms/#{room['code']}")["room"]
          last_heading = nil if failures > 0
          failures = 0
          return [0, room] if ["playing", "closed"].include?(room["status"])
        rescue Error => error
          return [6, room] if error.code == "room_menu_closed"
          failures += 1
          raise if failures >= 3
          message.text = "连接暂时中断，正在查询房间状态。\n#{text(error.message)}\n按返回可继续单机。"
        end
        next_poll = Time.now + (failures > 0 ? 2 : 1)
      end
    ensure
      @client.wait_update = previous_update
      window.dispose if window && !window.disposed?
      pbDisposeMessageWindow(message) if message
    end

    def choose_party_snapshots(minimum = 3, maximum = 3)
      party, selected = $Trainer.party, []
      raise Error, "队伍数量不足。" if party.length < minimum
      loop do
        labels = party.each_with_index.map { |p, i| "#{selected.include?(i) ? '●' : '○'} #{text(p.name)} Lv.#{p.level}" }
        choice = choose("按顺序选择#{minimum}至#{maximum}只精灵。", labels + ["完成", "取消"])
        return nil if choice < 0 || choice == labels.length + 1
        if choice == labels.length
          return selected.map { |i| Snapshot.export_for_battle(party[i]) } if selected.length.between?(minimum, maximum)
          pbMessage("请选择#{minimum}至#{maximum}只支持的精灵。")
        elsif selected.include?(choice)
          selected.delete(choice)
        elsif selected.length < maximum
          Snapshot.export_for_battle(party[choice])
          selected << choice
        end
      end
    end

    def select_team(code)
      party = $Trainer.party
      raise Error, "队伍至少需要三只支持的精灵。" if party.length < 3
      candidates = []
      loop do
        labels = party.each_with_index.map { |p, i| "#{candidates.include?(i) ? '●' : '○'} #{text(p.name)} Lv.#{p.level}" }
        selected = choose("选择 3 至 6 只候选。再次选择可移除。", labels + ["候选完成", "取消"])
        return if selected < 0 || selected == labels.length + 1
        break if selected == labels.length && candidates.length.between?(3, 6)
        if selected == labels.length
          pbMessage("请选择至少三只候选。")
        elsif candidates.include?(selected)
          candidates.delete(selected)
        else
          Snapshot.export_for_battle(party[selected]) # refuse incompatibilities before locking
          candidates << selected
        end
      end
      snapshots = candidates.map { |index| Snapshot.export_for_battle(party[index]) }
      order = []
      3.times do |slot|
        available = (0...candidates.length).to_a - order
        index = choose("选择第 #{slot + 1} 只参赛精灵（出场顺序）", available.map { |i| text(party[candidates[i]].name) } + ["取消"])
        return if index < 0 || index >= available.length
        order << available[index]
      end
      @client.request("POST", "/v1/rooms/#{code}/team", { "candidates" => snapshots, "selected" => order })
      pbMessage("候选与出场顺序已锁定。修改队伍会取消准备。\n对战使用 50 级临时副本，原队伍不变。")
    end

    def launch_battle(room)
      id = room["battle_id"]
      raise Error, "房间尚未开始对战。" unless id
      battle = @client.request("GET", "/v1/battles/#{id}")["battle"]
      if battle["mode"] == "coop_boss"
        KIFMultiplayer.run_boss(@client, room, battle)
      elsif battle["phase"] == "finished"
        KIFMultiplayer.present_battle_result(BattleSession.new(@client, battle))
      else
        KIFMultiplayer.run_battle(@client, room, battle)
      end
    end

    def choose_pokemon
      options = ["随身队伍", "电脑盒子", "取消"]
      case choose("选择展示精灵来源", options)
      when 0
        party = $Trainer.party
        selected = choose("选择精灵", party.map { |p| text(p.name) } + ["取消"])
        return nil if selected < 0 || selected >= party.length
        party[selected]
      when 1
        storage = $PokemonStorage
        raise Error, "电脑尚不可用。" unless storage
        boxes = (0...storage.maxBoxes).to_a
        selected = choose("选择盒子", boxes.map { |i| "#{i + 1}：#{text(storage[i].name)}" } + ["取消"])
        return nil if selected < 0 || selected >= boxes.length
        values = (0...storage.maxPokemon(selected)).map { |i| storage[selected, i] }.compact
        raise Error, "这个盒子没有精灵。" if values.empty?
        index = choose("选择展示精灵", values.map { |p| text(p.name) } + ["取消"])
        index >= 0 && index < values.length ? values[index] : nil
      end
    end

    def showcases
      loop do
        command = choose("精灵展示\n仅展示，不能领取或导入。", ["发布 / 更新我的展示", "查看我的展示", "输入分享码查看", "收藏的展示", "下架我的展示", "返回"])
        break if command < 0 || command == 5
        perform do
          case command
          when 0
            pokemon = choose_pokemon
            next unless pokemon
            snapshot = Snapshot.export(pokemon)
            fields = []
            %w[name owner iv ev].zip(["昵称", "原训练师", "个体值 IV", "努力值 EV"]).each do |field, label|
              fields << field if pbConfirmMessage("公开#{label}？")
            end
            pbMessage("默认公开：物种 / 融合编号、等级、特性、招式、闪光与支持的外观参数。\n不上传完整存档。自定义本机图片路径不上传，资源不同时外观可能有差异。")
            next unless pbConfirmMessage("发布该展示？")
            previous = @client.profile.account["showcase_code"]
            body = { "snapshot" => snapshot, "public_fields" => fields }
            body["code"] = previous if previous
            result = @client.request("POST", "/v1/showcases", body)
            showcase = result["showcase"]
            @client.profile.account["showcase_code"] = showcase["code"]
            @client.profile.save
            pbMessage("展示已发布。分享码：#{text(showcase['code'])}")
          when 1
            code = @client.profile.account["showcase_code"]
            raise Error, "尚未发布展示。" unless code
            show_showcase(@client.request("GET", "/v1/showcases/#{code}")["showcase"])
          when 2
            code = enter("输入展示分享码", "", 16).upcase
            next if code.empty?
            showcase = @client.request("GET", "/v1/showcases/#{code}")["showcase"]
            show_showcase(showcase)
            if pbConfirmMessage("收藏这个展示引用？（不会生成精灵）")
              favorites = @client.profile.account["favorites"] ||= []
              favorites << code unless favorites.include?(code)
              @client.profile.save
            end
          when 3
            favorites = @client.profile.account["favorites"] || []
            raise Error, "尚未收藏展示。" if favorites.empty?
            index = choose("收藏的展示引用", favorites + ["取消"])
            next if index < 0 || index >= favorites.length
            show_showcase(@client.request("GET", "/v1/showcases/#{favorites[index]}")["showcase"])
          when 4
            code = @client.profile.account["showcase_code"]
            raise Error, "尚未发布展示。" unless code
            next unless pbConfirmMessage("下架后新访问将无法获取展示。继续？")
            @client.request("POST", "/v1/showcases/#{code}/unpublish")
            @client.profile.account.delete("showcase_code")
            @client.profile.save
          end
        end
      end
    end

    def show_showcase(showcase)
      data = showcase["snapshot"]
      raise Error, "无效展示数据。" unless data.is_a?(Hash)
      Snapshot.registry(:Species, data["species"])
      Snapshot.check(Snapshot.number(data["level"], 1, 100), "Invalid showcase level")
      Snapshot.validate_appearance(data["appearance"] || {})
      title = "展示 #{text(showcase['code'])} · 版本 #{showcase['version']}\n"
      title += "#{text(data['name'] || data['species'])} Lv.#{data['level']}\n"
      title += "特性 #{text(data['ability'])} / #{text(data['ability2'])}\n"
      title += "招式 #{(data['moves'] || []).map { |m| text(m['id']) }.join(' / ')}\n"
      title += data["shiny"] ? "闪光；支持的自定义颜色随展示发布。" : "非闪光。"
      %w[owner iv ev].each { |key| title += "\n#{key}: #{text(WireJSON.dump(data[key]))}" if data.key?(key) }
      pbMessage(title)
      # Render only a temporary display object. There is deliberately no import
      # or receive action anywhere in the showcase flow.
      sprite = viewport = nil
      begin
        pokemon = Pokemon.new(data["species"], data["level"], nil, false, false)
        pokemon.shiny = data["shiny"] == true
        appearance = data["appearance"] || {}
        Snapshot::APPEARANCE_KEYS.each do |key|
          next unless appearance.key?(key)
          value = appearance[key]
          if key == "size_category" && value
            next unless %w[SMALL AVERAGE LARGE SUPER].include?(value)
            value = value.to_sym
          end
          pokemon.instance_variable_set("@#{key}", value)
        end
        viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
        viewport.z = 99999
        sprite = PokemonSprite.new(viewport)
        sprite.setPokemonBitmap(pokemon)
        sprite.x, sprite.y = Graphics.width / 2, Graphics.height / 3
        sprite.ox = sprite.bitmap.width / 2 if sprite.bitmap
        sprite.oy = sprite.bitmap.height / 2 if sprite.bitmap
        pbMessage("展示外观预览。资源缺失时使用游戏备用素材，外观可能不完整。") { sprite.update }
      rescue StandardError => error
        KIFMultiplayer.log_error(error)
        pbMessage("外观资源不完整；文字与颜色参数仍可查看。")
      ensure
        sprite.dispose if sprite && !sprite.disposed?
        viewport.dispose if viewport && !viewport.disposed?
      end
    end
  end

  # Append at display time, preserving every original command and index. Other
  # work in the existing PauseMenu file is intentionally left untouched.
  module PauseMenuEntry
    def pbShowCommands(commands)
      return super(commands) unless defined?($Trainer) && $Trainer
      return super(commands) if defined?(OnlineMode) && OnlineMode.offline?
      choices = commands + ["联机"]
      loop do
        result = super(choices)
        return result unless result == commands.length
        pbHideMenu
        KIFMultiplayer.open_menu
        pbShowMenu
      end
    end
  end
end

PokemonPauseMenu_Scene.prepend(KIFMultiplayer::PauseMenuEntry) if defined?(PokemonPauseMenu_Scene)
