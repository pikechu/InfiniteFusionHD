module KIFMultiplayer
  class << self
    attr_accessor :hall_controller
  end

  class HallSession
    MAP_ID = "social-lobby-v1"
    DIRECTIONS = {2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1]}
    EMOTES = %w[hello happy ready thanks]
    attr_reader :client, :hall, :error, :local_position
    def initialize(client, hall)
      @client = client
      @code = hall["code"]
      raise Error, "无效大厅编号。" unless @code.is_a?(String) && @code =~ /\A[A-Z0-9]{4,12}\z/
      @sequence, @local_position = 0, nil
      @next_poll = Time.now
      @worker, @pending_move, @pending_emote, @error = nil, nil, nil, nil
      @closed, @foreground = false, false
      adopt(hall)
    end
    def path; "/v1/halls/#{@code}"; end
    def own_member; (@hall["members"] || []).find { |member| member["id"] == @client.player_id }; end
    def map_compatible?
      map = @hall["map"]
      map.is_a?(Hash) && map["id"] == MAP_ID && map["width"] == 20 && map["height"] == 15
    end
    def adopt(hall, authoritative = false)
      Snapshot.check(hall.is_a?(Hash) && hall["code"] == @code && hall["members"].is_a?(Array) && hall["members"].length <= 4, "Invalid hall state")
      ids = []
      hall["members"].each do |member|
        Snapshot.check(member.is_a?(Hash) && member["id"].is_a?(String) && member["nickname"].is_a?(String) && member["nickname"].length <= 32, "Invalid hall member")
        Snapshot.check(Snapshot.number(member["x"], 0, 19) && Snapshot.number(member["y"], 0, 14) && DIRECTIONS.key?(member["direction"]) && Snapshot.number(member["seq"], 0, 0x7fffffff), "Invalid hall position")
        Snapshot.check(member["emote"].nil? || EMOTES.include?(member["emote"]), "Invalid hall emote")
        ids << member["id"]
      end
      Snapshot.check(ids.uniq.length == ids.length, "Duplicate hall member")
      invites = hall["invites"] || []
      Snapshot.check(invites.is_a?(Array) && invites.length <= 100, "Invalid hall invitations")
      invites.each do |invite|
        Snapshot.check(invite.is_a?(Hash) && invite["id"].is_a?(String) && invite["id"] =~ /\A[A-Za-z0-9_-]{8,100}\z/ && %w[battle trade].include?(invite["kind"]) && %w[pending accepted declined expired].include?(invite["status"]), "Invalid hall invitation")
        Snapshot.check(%w[from_id to_id].all? { |field| invite[field].is_a?(String) && invite[field] =~ /\A[A-Za-z0-9_-]{3,80}\z/ }, "Invalid hall invitation owners")
        %w[room_code trade_code].each do |field|
          Snapshot.check(!invite.key?(field) || invite[field].is_a?(String) && invite[field] =~ /\A[A-Z0-9]{4,16}\z/, "Invalid hall activity code")
        end
      end
      @hall = hall
      member = own_member
      raise Error.new("大厅席位已过期，请重新加入。", "hall_not_member") unless member
      if member["seq"] >= @sequence || authoritative && !@pending_move
        @sequence = member["seq"]
        @local_position = member.slice("x", "y", "direction", "seq")
      end
      @error = nil
      hall
    end
    def move(direction)
      return false unless DIRECTIONS.key?(direction) && @local_position && map_compatible?
      dx, dy = DIRECTIONS[direction]
      @sequence += 1
      @local_position = {"x" => [[@local_position["x"] + dx, 0].max, 19].min,
                         "y" => [[@local_position["y"] + dy, 0].max, 14].min,
                         "direction" => direction, "seq" => @sequence}
      @pending_move = @local_position.dup
      true
    end
    def emote(value)
      raise Error, "未知预设表情。" unless EMOTES.include?(value)
      @pending_emote = value
    end
    def display_members
      @hall["members"].map do |member|
        value = member.dup
        value.merge!(@local_position) if member["id"] == @client.player_id && @local_position
        value
      end
    end

    # Only these ephemeral position/presence requests run in a worker. It uses
    # the transport directly, so no Graphics, Input or local credential writes
    # occur on that thread. Invitations and trades use Client's durable journal.
    def tick
      return if @closed || @foreground
      if @worker
        return if busy?
        begin
          value = @worker.value
          if value.is_a?(Exception)
            @error = value
          else
            begin
              adopt(value["hall"], @last_worker_method == "GET")
            rescue Error => failure
              @error = failure
            end
          end
        ensure
          @worker = nil
        end
      end
      return if Time.now < @next_poll
      method, endpoint, body = "GET", path, {}
      if @pending_move
        method, endpoint, body = "POST", "#{path}/move", @pending_move
        @pending_move = nil
      elsif @pending_emote
        method, endpoint, body = "POST", "#{path}/emote", {"emote" => @pending_emote}
        @pending_emote = nil
      end
      body = body.merge("request_id" => KIFMultiplayer.operation_id) if method == "POST"
      transport, url, token = @client.transport, @client.server + endpoint, @client.token
      @last_worker_method = method
      @next_poll = Time.now + 0.35
      @worker = KIFMultiplayer.network_worker do
        begin
          response = transport.call(method, url, body, token, 3.0)
          status = response[:status] || response["status"]
          parsed = WireJSON.parse((response[:body] || response["body"]).to_s)
          unless status.to_i.between?(200, 299) && parsed.is_a?(Hash) && parsed["ok"] == true
            failure = parsed.is_a?(Hash) ? parsed["error"] || {} : {}
            raise Error.new(failure["message"] || "大厅连接中断", failure["code"] || "hall_unreachable")
          end
          parsed
        rescue StandardError => failure
          failure
        end
      end
      KIFMultiplayer.register_worker(@worker) if KIFMultiplayer.respond_to?(:register_worker)
    end
    def busy?
      @worker.poll if @worker && @worker.respond_to?(:poll)
      @worker && @worker.alive?
    end
    def drain
      previous_foreground = @foreground
      @foreground = true
      until_time = Time.now + 5
      while busy? && Time.now < until_time
        @client.pump
        Thread.pass
      end
      raise UncertainRequest.new("大厅上一个请求仍在执行，请稍后重试。", "hall_busy") if busy?
      if @worker
        result = @worker.value
        @worker = nil
        adopt(result["hall"], @last_worker_method == "GET") unless result.is_a?(Exception)
      end
    ensure
      @foreground = previous_foreground
    end
    def foreground(endpoint, body = {})
      @foreground = true
      drain
      response = @client.request("POST", "#{path}/#{endpoint}", body)
      adopt(response["hall"]) if response["hall"]
      response
    rescue Error
      # Query first when an invite response is uncertain. Never infer that
      # acceptance failed and create a different battle/trade as a workaround.
      begin
        adopt(@client.request("GET", path)["hall"])
      rescue Error
        nil
      end
      raise
    ensure
      @foreground = false
      @next_poll = Time.now + 0.35
    end
    def invite(target, kind)
      raise Error, "只能邀请当前大厅中的其他玩家。" unless @hall["members"].any? { |member| member["id"] == target && target != @client.player_id }
      raise Error, "未知邀请类型。" unless %w[battle trade].include?(kind)
      foreground("invite", {"target_id" => target, "kind" => kind})
    end
    def accept(id); foreground("accept", {"invite_id" => id}); end
    def decline(id); foreground("decline", {"invite_id" => id}); end
    def pending_invites
      (@hall["invites"] || []).select { |invite| invite["status"] == "pending" && invite["to_id"] == @client.player_id }
    end
    def accepted_invites
      (@hall["invites"] || []).select { |invite| invite["status"] == "accepted" && [invite["from_id"], invite["to_id"]].include?(@client.player_id) }
    end
    def close(leave = true)
      return if @closed
      @closed = true
      @foreground = true
      begin
        drain
        @client.request("POST", "#{path}/leave", {}) if leave
      rescue Error
        # Presence TTL removes an unreachable departing client; no map or save
        # data was changed, and the profile retains the code for recovery.
        nil
      ensure
        # A bounded socket request closes itself. An OS DNS resolver may still
        # be returning after drain's UI deadline; keep its guard/reference and
        # let it finish naturally instead of interrupting native IO with kill.
        if @worker && !@worker.alive?
          KIFMultiplayer.unregister_worker(@worker) if KIFMultiplayer.respond_to?(:unregister_worker)
          @worker = nil
        end
      end
    end
  end

  class HallScene
    EMOTE_LABELS = {"hello" => "你好", "happy" => "开心", "ready" => "准备好了", "thanks" => "谢谢"}
    def initialize(client, hall)
      @client, @session, @ui = client, HallSession.new(client, hall), UI.new(client)
      @opened_invites, @last_move = {}, Time.now
      ((@client.profile.account["hall_opened_invites"] || [])).each { |id| @opened_invites[id] = true }
      @sprites, @avatars = {}, {}
    end
    attr_reader :session
    def run
      old_scene, old_update = $scene, @client.wait_update
      @client.wait_update = proc { update_visuals }
      $scene = self
      unless @session.map_compatible?
        pbMessage("大厅地图版本不兼容，已返回菜单式大厅；仍可查看成员和邀请。")
        return menu_fallback
      end
      create_visuals
      loop do
        Graphics.update
        Input.update
        update_visuals
        if KIFMultiplayer.hall_controller
          action = KIFMultiplayer.hall_controller.call(@session.hall, @client.player_id)
          return if action == :leave
          @session.move(action) if action.is_a?(Integer)
        else
          return if Input.trigger?(Input::BACK)
          direction = Input.dir4
          if direction != 0 && Time.now - @last_move >= 0.13
            @session.move(direction)
            @last_move = Time.now
          end
          member_menu if Input.trigger?(Input::USE)
          emote_menu if Input.trigger?(Input::ACTION)
          handle_click if defined?(Input::MOUSELEFT) && Input.trigger?(Input::MOUSELEFT)
        end
        auto_launch_accepted
        if @session.error && %w[hall_not_member not_member hall_expired].include?(@session.error.respond_to?(:code) && @session.error.code)
          pbMessage("大厅席位已过期，请重新加入。") unless KIFMultiplayer.hall_controller
          return
        end
      end
    ensure
      begin
        @session.close
      rescue StandardError => error
        # A failed departure journal/write must not strand the player in this
        # scene or leave its callback installed in ordinary single-player play.
        KIFMultiplayer.log_error(error) if KIFMultiplayer.respond_to?(:log_error)
      ensure
        @client.wait_update = old_update
        $scene = old_scene
        @avatars.each_value { |value| BattlePresentation.dispose(value) }
        @sprites.each_value { |value| BattlePresentation.dispose(value) }
        BattlePresentation.dispose(@charset)
        BattlePresentation.dispose(@viewport)
        Graphics.frame_reset if defined?(Graphics)
      end
    end
    def create_visuals
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 90000
      @cell = [Graphics.width / 20, (Graphics.height - 72) / 15].min
      @left = (Graphics.width - @cell * 20) / 2
      @top = 42
      @sprites["background"] = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      bitmap = @sprites["background"].bitmap
      bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(24, 37, 48))
      15.times do |y|
        20.times do |x|
          color = (x + y).even? ? Color.new(58, 91, 81) : Color.new(65, 102, 89)
          bitmap.fill_rect(@left + x * @cell, @top + y * @cell, @cell - 1, @cell - 1, color)
        end
      end
      @sprites["labels"] = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      @sprites["labels"].z = 1000
      pbSetSystemFont(@sprites["labels"].bitmap)
      cjk_font = ["Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "SimSun"].find { |name| Font.exist?(name) }
      @english_labels = cjk_font.nil?
      if cjk_font
        @sprites["labels"].bitmap.font.name = cjk_font
        @sprites["labels"].bitmap.font.size = 18
      end
      filename = GameData::TrainerType.charset_filename($Trainer.trainer_type)
      @charset = AnimatedBitmap.new(filename) if filename
      @last_draw = nil
    end
    def update_visuals
      @session.tick
      return unless @viewport
      members = @session.display_members
      current_ids = members.map { |member| member["id"] }
      (@avatars.keys - current_ids).each { |id| BattlePresentation.dispose(@avatars.delete(id)) }
      members.each do |member|
        sprite = @avatars[member["id"]]
        unless sprite
          sprite = @charset ? Sprite.new(@viewport) : BitmapSprite.new(18, 22, @viewport)
          if @charset
            sprite.bitmap = @charset.bitmap
          else
            sprite.bitmap.fill_rect(0, 0, 18, 22, Color.new(230, 205, 110))
          end
          @avatars[member["id"]] = sprite
        end
        if @charset
          width, height = @charset.bitmap.width / 4, @charset.bitmap.height / 4
          frame = (Time.now.to_f * 4).to_i % 4
          sprite.src_rect = Rect.new(frame * width, (member["direction"] / 2 - 1) * height, width, height)
          sprite.ox, sprite.oy = width / 2, height
        end
        sprite.x = @left + member["x"] * @cell + @cell / 2
        sprite.y = @top + (member["y"] + 1) * @cell
        sprite.z = sprite.y
        sprite.opacity = member["status"] == "reconnecting" ? 120 : 255
      end
      key = [members.map { |member| [member["id"], member["nickname"], member["x"], member["y"], member["emote"], member["status"]] }, @session.pending_invites.length, @session.error && @session.error.message]
      return if key == @last_draw
      @last_draw = key
      labels = @sprites["labels"].bitmap
      labels.clear
      heading = @english_labels ? "Lobby #{@session.hall['code']} · #{members.length}/4 · Invites #{@session.pending_invites.length}" : "大厅 #{@session.hall['code']} · #{members.length}/4 · 邀请 #{@session.pending_invites.length}"
      labels.draw_text(8, 2, Graphics.width - 16, 32, heading)
      members.each do |member|
        label = KIFMultiplayer.display_text(member["nickname"])
        label += @english_labels ? " (you)" : "（你）" if member["id"] == @client.player_id
        label += " #{@english_labels ? member['emote'] : EMOTE_LABELS[member['emote']]}" if member["emote"]
        label += " [#{KIFMultiplayer.display_text(member['status'])}]" if member["status"] && member["status"] != "online"
        labels.draw_text(@left + member["x"] * @cell - 56, @top + member["y"] * @cell - 24, 140, 24, label, 1)
      end
      footer = @session.error ? "连接中断，正在重连；位置以服务器为准。" : "方向键移动 · 确认/点击成员互动 · 动作键表情 · 取消离开"
      footer = @session.error ? "Reconnecting; server positions are authoritative." : "Arrows move | Enter / click: members | Action: emote | Cancel: exit" if @english_labels
      labels.draw_text(4, Graphics.height - 30, Graphics.width - 8, 28, footer)
    end
    def choose(title, options)
      pbMessage(title, options, options.length) { update_visuals }
    end
    def emote_menu
      keys = HallSession::EMOTES
      index = choose("预设表情", keys.map { |key| EMOTE_LABELS[key] } + ["返回"])
      @session.emote(keys[index]) if index >= 0 && index < keys.length
    end
    def handle_click
      return unless Input.respond_to?(:mouse_x) && Input.respond_to?(:mouse_y)
      x = ((Input.mouse_x - @left) / @cell).floor
      y = ((Input.mouse_y - @top) / @cell).floor
      members = @session.display_members.select { |member| member["id"] != @client.player_id && member["x"] == x && member["y"] == y }
      interact(members.first) if members.first
    end
    def member_menu
      members = @session.hall["members"].reject { |member| member["id"] == @client.player_id }
      index = choose("大厅成员 / 邀请", members.map { |member| KIFMultiplayer.display_text(member["nickname"]) } + ["收到的邀请", "预设表情", "返回"])
      if index >= 0 && index < members.length
        interact(members[index])
      elsif index == members.length
        invitation_menu
      elsif index == members.length + 1
        emote_menu
      end
    end
    def interact(member)
      index = choose("#{KIFMultiplayer.display_text(member['nickname'])}\n状态：#{KIFMultiplayer.display_text(member['status'] || 'online')}", ["查看名片", "邀请两人好友对战", "邀请休闲交换", "返回"])
      case index
      when 0
        # Hall membership already exposes this public card; no credential or
        # recovery code is requested or shown.
        pbMessage("昵称：#{KIFMultiplayer.display_text(member['nickname'])}\n联机 ID：#{KIFMultiplayer.display_text(member['id'])}\n#{KIFMultiplayer.display_text(member['friend_code'])}") { update_visuals }
      when 1 then @session.invite(member["id"], "battle")
      when 2 then @session.invite(member["id"], "trade")
      end
    rescue Error => error
      pbMessage(KIFMultiplayer.display_text(error.message)) { update_visuals }
    end
    def invitation_menu
      invites = @session.pending_invites
      return pbMessage("暂无收到的邀请。") { update_visuals } if invites.empty?
      index = choose("收到的邀请", invites.map { |invite| "#{invite['kind'] == 'battle' ? '对战' : '交换'} · #{KIFMultiplayer.display_text(invite['from_id'])}" } + ["返回"])
      return if index < 0 || index >= invites.length
      invite = invites[index]
      choice = choose("接受此#{invite['kind'] == 'battle' ? '对战' : '休闲交换'}邀请？", ["接受", "拒绝", "返回"])
      @session.accept(invite["id"]) if choice == 0
      @session.decline(invite["id"]) if choice == 1
    rescue Error => error
      pbMessage(KIFMultiplayer.display_text(error.message)) { update_visuals }
    end
    def auto_launch_accepted
      @session.accepted_invites.each do |invite|
        next if @opened_invites[invite["id"]]
        @session.drain
        @viewport.visible = false if @viewport
        begin
          if invite["kind"] == "battle" && invite["room_code"]
            room = @client.request("GET", "/v1/rooms/#{invite['room_code']}")["room"]
            remember_invite(invite["id"], room["code"])
            @ui.room_menu(room)
          elsif invite["kind"] == "trade" && invite["trade_code"]
            ui = TradeUI.new(@client)
            session = TradeSession.new(@client)
            trade = session.get(invite["trade_code"])
            remember_invite(invite["id"])
            ui.trade_menu(trade)
          end
        ensure
          @viewport.visible = true if @viewport
        end
      end
    end
    def remember_invite(id, room_code = nil)
      KIFMultiplayer.persist_account(@client.profile) do |account|
        values = account["hall_opened_invites"] ||= []
        values << id unless values.include?(id)
        values.shift while values.length > 100
        account["room_code"] = room_code if room_code
      end
      @opened_invites[id] = true
    end
    def menu_fallback
      loop do
        @session.tick
        choice = choose("菜单式大厅 #{@session.hall['code']}\n地图版本不兼容，移动已禁用。", ["成员与邀请", "刷新", "离开"])
        return if choice < 0 || choice == 2
        member_menu if choice == 0
        auto_launch_accepted
      end
    end
  end

  def self.run_hall(client, hall)
    HallScene.new(client, hall).run
  end
  def self.open_hall_menu(client)
    ui = UI.new(client)
    loop do
      index = ui.choose("可走动大厅\n最多四人，专用社交场景；主线位置与剧情不参与同步。", ["创建大厅", "加入大厅", "恢复大厅", "返回"])
      return if index < 0 || index == 3
      ui.perform do
        ui.connect
        case index
        when 0
          hall = client.request("POST", "/v1/halls", {"name" => "好友大厅", "compatibility" => client.compatibility})["hall"]
        when 1
          code = ui.enter("大厅码", "", 12).upcase
          next if code.empty?
          hall = client.request("POST", "/v1/halls/#{code}/join", {"compatibility" => client.compatibility})["hall"]
        when 2
          code = client.profile.account["hall_code"]
          raise Error, "没有可恢复的大厅。" unless code
          hall = client.request("POST", "/v1/halls/#{code}/join", {"compatibility" => client.compatibility})["hall"]
        end
        client.profile.account["hall_code"] = hall["code"]
        client.profile.save
        run_hall(client, hall)
      end
    end
  end
end
