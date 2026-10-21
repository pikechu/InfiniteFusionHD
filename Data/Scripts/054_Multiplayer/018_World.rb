module KIFMultiplayer
  class WorldSession
    attr_reader :players, :messages, :map_key, :error, :revision, :client
    def initialize(client, compatibility, session_id = nil)
      @client, @compatibility = client, compatibility
      @session_id = session_id || KIFMultiplayer.operation_id
      @server, @owner, @token = client.server, client.player_id, client.token
      @io, @joined, @closed = AsyncRequest.new(client), false, false
      @players, @messages, @outbox, @cursor, @seq, @revision = [], [], [], 0, 0, 0
      @next_poll = 0
    end
    def position
      scene = defined?($scene) && $scene
      return nil unless (scene.is_a?(Scene_Map) || (defined?(OnlineMode) && OnlineMode.chatting)) &&
        defined?($game_map) && $game_map && defined?($game_player) && $game_player &&
        defined?($Trainer) && $Trainer && $game_temp && !$game_temp.in_battle && !$game_temp.player_transferring && !$game_player.transparent
      map = $game_map
      unless @fingerprint_map.equal?(map)
        require "digest/sha2"
        # Canonical JSON plus explicit little-endian tile integers avoids
        # depending on a Ruby version's Marshal or native Table serialization.
        digest = Digest::SHA256.new
        data = map.data
        digest.update(WireJSON.dump({"map_id" => map.map_id, "width" => map.width, "height" => map.height, "layers" => data.zsize, "tileset" => map.tileset_name}))
        data.zsize.times do |z|
          map.height.times do |y|
            row = Array.new(map.width) { |x| data[x, y, z] }
            digest.update(row.pack("S<*"))
          end
        end
        @map_hash = digest.hexdigest
        @fingerprint_map = map
      end
      {"map_id" => map.map_id, "map_hash" => @map_hash, "width" => map.width, "height" => map.height,
       "x" => $game_player.x, "y" => $game_player.y, "direction" => $game_player.direction,
       "character_id" => [[$Trainer.character_ID.to_i, 0].max, 7].min, "moving" => !!$game_player.moving?}
    end
    def validate_world(world)
      check(world.is_a?(Hash) && world["players"].is_a?(Array) && world["players"].length <= 128)
      check(world["map_key"].nil? || world["map_key"].is_a?(String) && world["map_key"] =~ /\A[a-f0-9]{64}\z/)
      check(world["cursor"].is_a?(Integer) && world["cursor"] >= 0)
      check(world["messages"].is_a?(Array) && world["messages"].length <= 50)
      ids = []
      world["players"].each do |player|
        check(player.is_a?(Hash) && player["id"].is_a?(String) && player["id"] =~ /\A[A-Za-z0-9_-]{3,80}\z/)
        check(player["nickname"].is_a?(String) && player["nickname"].length <= 32)
        check(@sent_position && %w[map_id map_hash width height].all? { |key| player[key] == @sent_position[key] })
        check(Snapshot.number(player["x"], 0, @sent_position["width"] - 1) && Snapshot.number(player["y"], 0, @sent_position["height"] - 1))
        check([2, 4, 6, 8].include?(player["direction"]) && Snapshot.number(player["character_id"], 0, 7))
        ids << player["id"]
      end
      check(ids.uniq.length == ids.length && !ids.include?(@owner))
      world["messages"].each { |message| validate_message(message) }
      world
    end
    def check(value); raise Error.new("地图或聊天响应无效。", "invalid_world") unless value; end
    def validate_message(message)
      check(message.is_a?(Hash) && message["id"].is_a?(Integer) && message["id"] > 0)
      check(%w[map world].include?(message["channel"]) && message["sender_id"].is_a?(String) && message["sender_id"] =~ /\A[A-Za-z0-9_-]{3,80}\z/)
      check(message["nickname"].is_a?(String) && message["nickname"].length <= 32 && message["text"].is_a?(String) && message["text"].length.between?(1, 200))
      check(message["channel"] == "world" && message["map_key"].nil? || message["channel"] == "map" && message["map_key"].is_a?(String) && message["map_key"] =~ /\A[a-f0-9]{64}\z/)
      message
    end
    def remember(message)
      validate_message(message)
      return if @messages.any? { |value| value["id"] == message["id"] }
      @messages << message
      @messages.sort_by! { |value| value["id"] }
      @messages = @messages.last(200)
      @revision += 1
    end
    def visible_messages(channel = nil)
      @messages.select { |value| (!channel || value["channel"] == channel) && (value["channel"] == "world" || value["map_key"] == @map_key) }
    end
    def send_chat(channel, text)
      text = text.to_s.strip
      raise Error, "请选择地图或世界频道。" unless %w[map world].include?(channel)
      raise Error, "请输入1至200字，不能包含换行或控制字符。" unless text.length.between?(1, 200) && text !~ /[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/
      raise Error, "地图尚未连接，请稍候。" if channel == "map" && !@map_key
      raise Error, "待发送消息较多，请稍候。" if @outbox.length >= 5
      @outbox << {"session_id" => @session_id, "client_id" => KIFMultiplayer.operation_id, "channel" => channel, "text" => text, "map_key" => @map_key}
      @next_poll = 0
    end
    def pending_messages; @outbox.length; end
    def same_map?(left, right)
      left && right && %w[map_id map_hash width height].all? { |key| left[key] == right[key] }
    end
    def players_for(map)
      return [] if @error || !@current_position || @current_position["map_id"] != map.map_id || !@fingerprint_map.equal?(map)
      @players
    end
    def tick
      return if @closed
      return close unless @client.server == @server && @client.player_id == @owner && @client.token == @token
      current = position
      unless (current.nil? && @current_position.nil?) || same_map?(current, @current_position)
        @players, @map_key = [], nil
        @cursor = 0
        @revision += 1
      end
      @current_position = current
      if current && current != @sent_position
        @next_poll = [@next_poll, KIFMultiplayer.monotonic + 0.1].min
      end
      if @io.pending?
        return if @io.busy?
        begin
          response = @io.take
          case @kind
          when :join then @joined = true
          when :chat
            remember(response["message"])
            @outbox.shift
          when :sync
            world = validate_world(response["world"])
            if same_map?(@sent_position, current)
              @players, @map_key, @cursor = world["players"], world["map_key"], world["cursor"]
            elsif @sent_position.nil? && current.nil?
              @players, @map_key, @cursor = [], nil, world["cursor"]
            end
            world["messages"].each { |message| remember(message) }
          end
          @error = nil
        rescue StandardError => error
          @error, @players = error, []
          if error.respond_to?(:code)
            @joined = false if error.code == "world_session_lost"
            @outbox.shift if @kind == :chat && %w[invalid_message invalid_field message_conflict map_chat_unavailable].include?(error.code)
          end
          @next_poll = KIFMultiplayer.monotonic + 2
        end
      end
      return if @io.pending? || KIFMultiplayer.monotonic < @next_poll
      if !@joined
        @kind = :join
        @io.start("/v1/world/join", {"session_id" => @session_id, "compatibility" => @compatibility})
      elsif @outbox.any? && (@outbox.first["channel"] == "world" || @map_key && same_map?(current, @sent_position))
        message = @outbox.first
        if message["channel"] == "map" && message["map_key"] != @map_key
          @outbox.shift
          @error = Error.new("地图已切换，该地图消息未发送。", "map_changed")
          return
        end
        @kind = :chat
        @io.start("/v1/chat/send", message.reject { |key, _value| key == "map_key" })
      else
        @kind, @seq, @sent_position = :sync, @seq + 1, current
        @io.start("/v1/world/sync", {"session_id" => @session_id, "seq" => @seq, "after" => @cursor, "position" => current})
      end
      delay = @kind == :join ? 0 : (@kind == :chat ? 0.2 : (current ? (current["moving"] ? 0.2 : 0.8) : 2.0))
      @next_poll = KIFMultiplayer.monotonic + delay
    rescue StandardError => error
      @error, @players = error, []
      @next_poll = KIFMultiplayer.monotonic + 2
    end
    def close
      @closed = true
      @players = []
      @io.cancel
      # Do not race an in-flight sync with leave. TTL cleans up if IO is busy.
      @client.request("POST", "/v1/world/leave", {"session_id" => @session_id}, 2.0) if @joined && !@io.busy?
    rescue Error
      nil
    end
  end

  if defined?(Game_Character)
    class RemoteCharacter < Game_Character
      AVATARS = %w[trainer_POKEMONTRAINER_Red trainer_POKEMONTRAINER_Leaf trchar003 trchar004 trchar005 trchar006 trchar007 trchar008].freeze
      def name; ""; end
      def initialize(map, player)
        super(map)
        @through = true
        moveto(player["x"], player["y"])
        @last_update = KIFMultiplayer.monotonic
        adopt(player)
      end
      def adopt(player)
        @x, @y, @direction = player.values_at("x", "y", "direction")
        @walking = player["moving"]
        @character_name = AVATARS[player["character_id"]] || AVATARS.first
      end
      def update
        now = KIFMultiplayer.monotonic
        fraction = [[(now - @last_update) / 0.15, 0.02].max, 1.0].min
        @last_update = now
        target_x, target_y = @x * Game_Map::REAL_RES_X, @y * Game_Map::REAL_RES_Y
        if (target_x - @real_x).abs > Game_Map::REAL_RES_X * 3 || (target_y - @real_y).abs > Game_Map::REAL_RES_Y * 3
          @real_x, @real_y = target_x, target_y
        else
          @real_x += (target_x - @real_x) * fraction
          @real_y += (target_y - @real_y) * fraction
          @real_x = target_x if (@real_x - target_x).abs < 1
          @real_y = target_y if (@real_y - target_y).abs < 1
        end
        @pattern = (@walking || moving?) ? (now * 7).to_i % 4 : 0
      end
    end

    # The base Sprite_Character is patched by shadows/outfit add-ons that assume
    # every non-player character has a local RPG event. Remote actors have no
    # event page and use an independent, resource-only sprite instead.
    class RemoteSprite < Sprite
      def initialize(viewport, character)
        super(viewport)
        @character = character
        refresh
        update
      end
      def refresh
        @charset.dispose if @charset
        @fallback.dispose if @fallback
        @charset, @fallback = nil, nil
        @name = @character.character_name
        path = "Graphics/Characters/" + @name
        @charset = AnimatedBitmap.new(path) if !@name.empty? && pbResolveBitmap(path)
        unless @charset
          @fallback = Bitmap.new(24, 32)
          @fallback.fill_rect(6, 0, 12, 12, Color.new(255, 220, 170))
          @fallback.fill_rect(2, 12, 20, 16, Color.new(80, 160, 240))
          @fallback.fill_rect(4, 28, 6, 4, Color.new(35, 50, 70))
          @fallback.fill_rect(14, 28, 6, 4, Color.new(35, 50, 70))
        end
      end
      def update
        super
        refresh if @name != @character.character_name
        @charset.update if @charset
        self.bitmap = @charset ? @charset.bitmap : @fallback
        width, height = @charset ? [bitmap.width / 4, bitmap.height / 4] : [bitmap.width, bitmap.height]
        self.src_rect.set(@charset ? @character.pattern * width : 0, @charset ? (@character.direction / 2 - 1) * height : 0, width, height)
        self.ox, self.oy = width / 2, height
        self.x, self.y, self.z = @character.screen_x, @character.screen_y, @character.screen_z(height)
        pbDayNightTint(self)
      end
      def dispose
        @charset.dispose if @charset
        @fallback.dispose if @fallback
        super
      end
    end

    class WorldSprites
      attr_reader :avatars
      def initialize(viewport, map)
        @viewport, @map, @avatars, @disposed = viewport, map, {}, false
        @hud = BitmapSprite.new(Graphics.width, 80, viewport)
        @hud.z = 5000
        @hud.y = Graphics.height - 80
        font(@hud.bitmap)
      end
      def font(bitmap)
        bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
        bitmap.font.size = 16
        bitmap.font.color = Color.new(255, 255, 255)
      end
      def update
        return if @disposed
        session = defined?(OnlineMode) && OnlineMode.world
        visible = session && $game_map.equal?(@map) && $scene.is_a?(Scene_Map)
        players = visible ? session.players_for(@map) : []
        ids = players.map { |player| player["id"] }
        (@avatars.keys - ids).each { |id| dispose_avatar(@avatars.delete(id)) }
        players.each do |player|
          entry = @avatars[player["id"]]
          unless entry
            character = RemoteCharacter.new(@map, player)
            sprite = RemoteSprite.new(@viewport, character)
            label = BitmapSprite.new(180, 24, @viewport)
            font(label.bitmap)
            @avatars[player["id"]] = entry = [character, sprite, label, nil]
          end
          character, sprite, label, nickname = entry
          character.adopt(player)
          character.update
          sprite.update
          if nickname != player["nickname"]
            label.bitmap.clear
            label.bitmap.draw_text(0, 0, 180, 24, player["nickname"], 1)
            entry[3] = player["nickname"]
          end
          label.x, label.y, label.z = sprite.x - 90, sprite.y - sprite.src_rect.height - 22, 4999
        end
        @hud.visible = !!visible
        return unless visible
        cloud = OnlineMode.cloud
        lines = session.visible_messages.last(2)
        status = cloud && cloud.error ? "云存档待同步：#{cloud.error.message}" : (session.error ? "地图连接中断，正在重连…" : "在线 · 同地图 #{players.length + 1} 人 · 暂停菜单 → 聊天")
        key = [status, lines.map { |message| message["id"] }, Graphics.height]
        return if key == @drawn
        @drawn = key
        bitmap = @hud.bitmap
        bitmap.clear
        bitmap.fill_rect(0, 0, Graphics.width, 80, Color.new(12, 20, 30, 170))
        bitmap.draw_text(8, 0, Graphics.width - 16, 24, status)
        lines.each_with_index do |message, index|
          channel = message["channel"] == "world" ? "世界" : "地图"
          bitmap.draw_text(8, 24 + index * 24, Graphics.width - 16, 24, "[#{channel}] #{message['nickname']}：#{message['text']}")
        end
      end
      def dispose_avatar(entry)
        entry[1].dispose
        entry[2].dispose
      end
      def disposed?; @disposed; end
      def dispose
        return if @disposed
        @avatars.each_value { |entry| dispose_avatar(entry) }
        @avatars.clear
        @hud.dispose
        @disposed = true
      end
    end
  end

  class ChatScene
    def initialize(session)
      @session, @channel, @scroll = session, "map", 0
    end
    def run
      previous_scene, previous_chatting = $scene, OnlineMode.chatting
      OnlineMode.chatting = true
      $scene = Object.new
      KIFMultiplayer.with_ui_fonts do
        @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
        @viewport.z = 99999
        @canvas = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
        @canvas.bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
        @canvas.bitmap.font.size = 18
        loop do
          Graphics.update
          Input.update
          draw
          break if Input.trigger?(Input::BACK)
          if Input.trigger?(Input::ACTION)
            switch_channel
          elsif Input.trigger?(Input::UP)
            @scroll += 1
          elsif Input.trigger?(Input::DOWN)
            @scroll = [@scroll - 1, 0].max
          elsif Input.trigger?(Input::USE)
            compose
          elsif defined?(Input::MOUSELEFT) && Input.trigger?(Input::MOUSELEFT) && Input.respond_to?(:mouse_y) && Input.mouse_y >= Graphics.height - 48
            if Input.mouse_x < Graphics.width / 3
              switch_channel
            elsif Input.mouse_x < Graphics.width * 2 / 3
              compose
            else
              break
            end
          end
        end
      end
    ensure
      @canvas.dispose if @canvas
      @viewport.dispose if @viewport
      OnlineMode.chatting = previous_chatting
      $scene = previous_scene
    end
    def switch_channel
      @channel = @channel == "map" ? "world" : "map"
      @scroll = 0
    end
    def compose
      value = pbMessageFreeText(@channel == "map" ? "发送地图消息（最多200字）" : "发送世界消息（最多200字）", "", false, 200).to_s.strip
      return if value.empty?
      @session.send_chat(@channel, value)
      @scroll = 0
    rescue Error => error
      pbMessage(KIFMultiplayer.display_text(error.message))
    end
    def draw
      key = [@session.revision, @session.error && @session.error.message, @session.pending_messages, @session.map_key, @channel, @scroll]
      return if key == @drawn
      bitmap = @canvas.bitmap
      bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(19, 27, 41))
      bitmap.font.color = Color.new(240, 245, 255)
      title = @channel == "map" ? "地图聊天" : "世界聊天"
      bitmap.draw_text(16, 8, Graphics.width - 32, 32, "#{title} · 待发送 #{@session.pending_messages}")
      status = @session.error ? @session.error.message : "方向键翻阅 · 动作键切换频道 · 确认键输入"
      bitmap.font.size = 14
      bitmap.draw_text(16, 42, Graphics.width - 32, 24, status)
      bitmap.font.size = 18
      lines = []
      @session.visible_messages(@channel).each do |message|
        prefix = "#{message['nickname']}："
        current = ""
        (prefix + message["text"]).each_char do |character|
          if bitmap.text_size(current + character).width > Graphics.width - 40
            lines << current
            current = ""
          end
          current += character
        end
        lines << current
        lines << ""
      end
      capacity = [(Graphics.height - 126) / 24, 1].max
      @scroll = [@scroll, [lines.length - capacity, 0].max].min
      finish = lines.length - @scroll
      lines[[finish - capacity, 0].max...finish].to_a.each_with_index do |line, index|
        bitmap.draw_text(20, 76 + index * 24, Graphics.width - 40, 24, line)
      end
      ["切换频道", "输入消息", "返回地图"].each_with_index do |label, index|
        width = Graphics.width / 3
        bitmap.fill_rect(index * width + 4, Graphics.height - 44, width - 8, 36, Color.new(44, 68, 95))
        bitmap.draw_text(index * width, Graphics.height - 44, width, 36, label, 1)
      end
      @drawn = key
    end
  end

  def self.open_chat
    raise Error, "请在启动时选择在线模式并登录账号。" unless OnlineMode.active? && OnlineMode.world
    ChatScene.new(OnlineMode.world).run
  end
end

if defined?(Events) && defined?(KIFMultiplayer::WorldSprites)
  Events.onSpritesetCreate += proc { |_sender, event|
    event[0].addUserSprite(KIFMultiplayer::WorldSprites.new(event[1], event[0].map))
  }
end
