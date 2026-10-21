module KIFMultiplayer
  class << self
    attr_accessor :rental_controller
  end

  class RentalSession
    attr_reader :client, :room
    def initialize(client, room)
      @client = client
      @code = room["code"]
      raise Error, "无效租借房间码。" unless @code.is_a?(String) && @code =~ /\A[A-Z0-9]{4,12}\z/
      @pool_digest = nil
      @validated_draft = nil
      adopt(room)
    end
    def draft; @room["draft"]; end
    def path; "/v1/rooms/#{@code}"; end
    def own_turn?; draft && draft["status"] == "picking" && draft["next_owner_id"] == @client.player_id; end
    def adopt(room)
      raise Error, "该房间不是随机租借杯。" unless room.is_a?(Hash) && room["mode"] == "rental_singles" && room["code"] == @code
      value = room["draft"]
      if value
        validate_draft(value)
        digest = KIFMultiplayer.battle_digest(value["pool"])
        if @validated_draft == value["id"] && @pool_digest != digest
          raise Error, "服务端选宠池在同一比赛中发生变化，已阻止继续。"
        end
        @validated_draft, @pool_digest = value["id"], digest
      end
      @room = room
    end
    def validate_draft(value)
      Snapshot.check(value.is_a?(Hash) && value["id"].is_a?(String) && value["id"] =~ /\A[A-Za-z0-9_-]{8,100}\z/, "Invalid rental draft")
      Snapshot.check(%w[picking complete cancelled].include?(value["status"]), "Unknown rental state")
      pool = value["pool"]
      Snapshot.check(pool.is_a?(Array) && pool.length == 12 && pool.all? { |entry| entry.is_a?(Hash) && entry["slot"].is_a?(Integer) } && pool.map { |entry| entry["slot"] }.sort == (0...12).to_a, "Invalid rental candidate pool")
      pool.each { |entry| Snapshot.validate(entry["snapshot"]) }
      order = value["order"]
      Snapshot.check(order.is_a?(Array) && order.length == 6 && order.all? { |id| id.is_a?(String) } && order[0] != order[1] && order == [order[0], order[1], order[1], order[0], order[0], order[1]], "Invalid ABBAAB selection order")
      picks = value["picks"]
      Snapshot.check(picks.is_a?(Hash) && picks.keys.all? { |id| id.is_a?(String) } && picks.keys.sort == order.uniq.sort, "Invalid rental owners")
      all_picks = []
      picks.each do |_id, slots|
        Snapshot.check(slots.is_a?(Array) && slots.length <= 3 && slots.all? { |slot| slot.is_a?(Integer) && slot.between?(0, 11) }, "Invalid rental picks")
        all_picks.concat(slots)
      end
      Snapshot.check(all_picks.uniq.length == all_picks.length, "A rental candidate was assigned twice")
      picks.each do |id, slots|
        Snapshot.check(slots.length == order.first(all_picks.length).count(id), "Rental picks disagree with ABBAAB history")
      end
      Snapshot.check(!value.key?("pick_index") || value["pick_index"] == all_picks.length, "Rental pick index disagrees")
      remaining = value["remaining"]
      Snapshot.check(remaining.is_a?(Array) && remaining.sort == ((0...12).to_a - all_picks).sort, "Rental remaining candidates disagree")
      if value["status"] == "picking"
        Snapshot.check(all_picks.length < 6 && value["next_owner_id"] == order[all_picks.length], "Rental selection owner disagrees")
      elsif value["status"] == "complete"
        Snapshot.check(all_picks.length == 6 && picks.values.all? { |slots| slots.length == 3 }, "Incomplete rental teams")
      end
      true
    end
    def fetch
      adopt(@client.request("GET", path)["room"])
    end
    def mutate(suffix, payload)
      adopt(@client.request("POST", "#{path}/#{suffix}", payload)["room"])
    rescue Error
      # The selection may have committed. Always query before allowing the
      # caller to retry; Client also recovers the journaled operation ID.
      begin
        fetch
      rescue Error
        nil
      end
      raise
    end
    def start
      raise Error, "只有房主可以开始选宠。" unless @room["host_id"] == @client.player_id
      mutate("draft", {})
    end
    def pick(slot)
      raise Error, "当前没有轮到你选宠，请刷新。" unless own_turn?
      raise Error, "该候选已被选择。" unless draft["remaining"].include?(slot)
      pick_index = draft["picks"].values.inject(0) { |total, slots| total + slots.length }
      mutate("pick", {"draft_id" => draft["id"], "pick_index" => pick_index, "slot" => slot})
    end
    def summary
      lines = ["随机租借杯 · 房间 #{@code}", "完整候选池由服务端保存；50 级临时队伍不会进入存档。"]
      unless draft
        lines << "成员 #{(@room['members'] || []).length}/2；双方加入后由房主开始。"
        return lines.join("\n")
      end
      lines << "比赛 #{draft['id']} · #{draft['status']}"
      lines << "顺序 A → B → B → A → A → B；#{own_turn? ? '轮到你' : '等待另一位玩家'}"
      if draft["deadline"].is_a?(Numeric)
        lines << "本次剩余约 #{[0, (draft['deadline'] - Time.now.to_f).ceil].max} 秒（服务器为准）"
      end
      draft["picks"].each { |id, slots| lines << "#{id == @client.player_id ? '你' : '对方'}：已选 #{slots.length}/3" }
      (draft["reconnect_remaining"] || {}).each { |id, seconds| lines << "#{id == @client.player_id ? '你' : '对方'}重连额度 #{seconds} 秒" }
      lines << "断线暂停；已选候选保留。" unless (draft["disconnected"] || []).empty?
      lines.join("\n")
    end
    def candidate(slot)
      draft && draft["pool"].find { |entry| entry["slot"] == slot }
    end
    def candidate_text(slot)
      entry = candidate(slot)
      raise Error, "未知租借候选。" unless entry
      data = entry["snapshot"]
      Snapshot.validate(data)
      "候选 #{slot + 1} · #{KIFMultiplayer.display_text(data['species'])}\n" +
        "特性：#{KIFMultiplayer.display_text(data['ability'])} / #{KIFMultiplayer.display_text(data['ability2'])}\n" +
        "道具：#{KIFMultiplayer.display_text(data['item'])}\n" +
        "招式：#{data['moves'].map { |move| KIFMultiplayer.display_text(move['id']) }.join(' / ')}\n" +
        "性格：#{data['nature']}；IV #{WireJSON.dump(data['iv'])}；EV #{WireJSON.dump(data['ev'])}"
    end
  end

  class RentalUI
    def initialize(client, room)
      @client, @session = client, RentalSession.new(client, room)
    end
    def run
      next_poll = Time.now
      current_key = nil
      window = message = nil
      loop do
        if Time.now >= next_poll
          @session.fetch
          next_poll = Time.now + 0.5
        end
        room, draft = @session.room, @session.draft
        if room["status"] == "closed" || draft && draft["status"] == "cancelled"
          pbMessage("租借杯已取消或关闭，原队伍未改变。") unless KIFMultiplayer.rental_controller
          return 0
        end
        if draft && draft["status"] == "complete"
          id = room["battle_id"]
          raise Error, "选宠完成但缺少战斗编号，请恢复房间。" unless id
          BattlePresentation.dispose(window)
          window = nil
          pbDisposeMessageWindow(message) if message
          message = nil
          battle = @client.request("GET", "/v1/battles/#{id}")["battle"]
          if battle["phase"] == "finished"
            finished = BattleSession.new(@client, battle)
            return finished.result_decision if KIFMultiplayer.rental_controller
            choice = UI.new(@client).choose("租借杯已结算。临时精灵不会保留。", ["查看结算", "再开一杯（房主）", "等待房主新杯", "返回"])
            case choice
            when 0 then KIFMultiplayer.present_battle_result(finished)
            when 1 then @session.start
            when 2 then return nil unless wait_next_cup(draft["id"])
            else return nil
            end
            current_key = nil
            next
          end
          decision = KIFMultiplayer.run_battle(@client, room, battle)
          return decision if KIFMultiplayer.rental_controller
          @session.fetch
          current_key = nil
          next
        end
        if KIFMultiplayer.rental_controller
          if !draft && room["host_id"] == @client.player_id && (room["members"] || []).length == 2
            @session.start
          elsif @session.own_turn?
            slot = KIFMultiplayer.rental_controller.call(draft, @client.player_id)
            @session.pick(slot) unless slot.nil?
          end
          @client.pump
          next
        end
        key = [draft && draft["id"], draft && draft["remaining"], @session.own_turn?, room["status"]]
        if key != current_key
          BattlePresentation.dispose(window)
          labels, @commands = choices
          window = Window_CommandPokemonEx.new(labels)
          window.z = 99999
          window.width = [Graphics.width, window.width].min
          window.height = [Graphics.height / 2, window.height].min
          window.y = Graphics.height - window.height
          message ||= pbCreateMessageWindow
          message.y = 0
          message.height = Graphics.height / 2
          current_key = key
        end
        message.text = @session.summary if !@last_text || @last_text != @session.summary
        @last_text = @session.summary
        Graphics.update
        Input.update
        window.update
        message.update
        next unless Input.trigger?(Input::USE) || Input.trigger?(Input::BACK)
        action = Input.trigger?(Input::BACK) ? [:return] : @commands[window.index]
        begin
          case action[0]
          when :start then @session.start
          when :candidate
            slot = action[1]
            presented_index = @session.draft["picks"].values.inject(0) { |total, slots| total + slots.length }
            poll_at = Time.now
            confirmed = pbConfirmMessage(@session.candidate_text(slot) + "\n选择这只候选？") do
              if Time.now >= poll_at
                begin
                  @session.fetch
                rescue Error
                  # A modal window has no ensure in the base game. Let it
                  # close normally, then the outer loop queries/reports again.
                  nil
                end
                poll_at = Time.now + 0.5
              end
            end
            current_index = @session.draft["picks"].values.inject(0) { |total, slots| total + slots.length }
            @session.pick(slot) if confirmed && presented_index == current_index && @session.own_turn? && @session.draft["remaining"].include?(slot)
          when :return then return nil
          when :leave
            if pbConfirmMessage("离开将取消未完成的租借杯。继续？")
              @client.request("POST", "#{@session.path}/leave", {})
              return nil
            end
          end
        rescue Error => error
          pbMessage(KIFMultiplayer.display_text(error.message))
          @session.fetch
        end
        current_key = nil
      end
    ensure
      BattlePresentation.dispose(window)
      pbDisposeMessageWindow(message) if message
      Input.update if defined?(Input)
    end
    def choices
      draft = @session.draft
      labels, actions = [], []
      if @session.own_turn?
        draft["remaining"].each do |slot|
          data = @session.candidate(slot)["snapshot"]
          labels << "#{slot + 1}. #{KIFMultiplayer.display_text(data['species'])} / #{KIFMultiplayer.display_text(data['item'])}"
          actions << [:candidate, slot]
        end
      elsif !draft && @session.room["host_id"] == @client.player_id
        labels << "开始 ABBAAB 选宠"
        actions << [:start]
      end
      labels.concat(["刷新", "返回（保留比赛，可恢复）", "离开 / 取消比赛"])
      actions.concat([[:refresh], [:return], [:leave]])
      [labels, actions]
    end
    def wait_next_cup(previous_id)
      message = pbCreateMessageWindow
      next_poll = Time.now
      begin
        message.text = "等待房主再开一杯；取消键返回。新杯有新的比赛编号和候选池。"
        loop do
          Graphics.update
          Input.update
          message.update
          return false if Input.trigger?(Input::BACK)
          if Time.now >= next_poll
            @session.fetch
            return false if @session.room["status"] == "closed"
            return true if @session.draft && @session.draft["id"] != previous_id
            next_poll = Time.now + 0.5
          end
        end
      ensure
        pbDisposeMessageWindow(message)
        Input.update
      end
    end
  end

  def self.run_rental(client, room)
    RentalUI.new(client, room).run
  end

  def self.open_rental_menu(client)
    ui = UI.new(client)
    loop do
      choice = ui.choose("随机租借杯\n十二只服务端候选池，ABBAAB 各选三只；原精灵和存档不变。", ["创建租借杯", "加入租借杯", "恢复当前租借杯", "返回"])
      return if choice < 0 || choice == 3
      ui.perform do
        ui.connect
        case choice
        when 0
          room = client.request("POST", "/v1/rooms", {"name" => "随机租借杯", "mode" => "rental_singles", "compatibility" => client.compatibility})["room"]
        when 1
          code = ui.enter("租借杯房间码", "", 12).upcase
          next if code.empty?
          room = client.request("POST", "/v1/rooms/#{code}/join", {"compatibility" => client.compatibility})["room"]
        when 2
          code = client.profile.account["rental_room_code"]
          raise Error, "没有可恢复的租借杯。" unless code
          room = client.request("GET", "/v1/rooms/#{code}")["room"]
        end
        raise Error, "该房间不是随机租借杯。" unless room["mode"] == "rental_singles"
        client.profile.account["rental_room_code"] = room["code"]
        client.room_code = room["code"]
        run_rental(client, room)
      end
    end
  end
end
