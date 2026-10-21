# Route state is server-owned; the host engine only advances a node after its
# official result and full temporary party state are durably recorded.
module KIFMultiplayer
  class DungeonSession
    TERMINAL = %w[completed failed abandoned expired].freeze
    attr_reader :client, :dungeon
    def initialize(client, id)
      raise Error, "Invalid route identifier" unless id.is_a?(String) && id =~ /\Ad_[a-f0-9]{32}\z/
      @client, @path = client, "/v1/dungeons/#{id}"
      @played = {}
    end
    def adopt(response)
      value = response["dungeon"]
      raise Error, "Invalid cooperative route response" unless value.is_a?(Hash) && value["players"].is_a?(Array) && value["players"].include?(client.player_id)
      @dungeon = value
      client.profile.account["dungeon_id"] = value["id"]
      client.profile.save
      value
    end
    def fetch; adopt(client.request("GET", @path)); end
    def mutate(action, body = {}); adopt(client.request("POST", "#{@path}/#{action}", body)); end
    def terminal?; @dungeon && TERMINAL.include?(@dungeon["status"]); end
    def host?; @dungeon["host_id"] == client.player_id; end
    def title
      names = {"battle" => "普通合作战", "rest" => "有限休息", "boss" => "最终 Boss", "complete" => "已通关"}
      "固定合作副本 #{@dungeon['id']}\n节点 #{@dungeon['node_index'] + 1}/5 · #{names[@dungeon['node_kind']] || @dungeon['node_kind']}\n状态 #{@dungeon['status']} · 中断重试 #{@dungeon['retry_used'] ? '已使用' : '剩余1次'}\n放弃票数 #{(@dungeon['abandon_votes'] || []).length}/2"
    end
    def wait_for_change
      initial = [@dungeon["status"], @dungeon["node_index"], @dungeon["battle_id"], @dungeon["readies"], @dungeon["rested"], @dungeon["abandon_votes"]]
      window = nil
      window = pbCreateMessageWindow unless KIFMultiplayer.battle_controller
      next_poll = Time.now
      loop do
        window.text = title + "\n等待另一位玩家。按返回离开此页面，可重新恢复。" if window
        client.pump
        window.update if window
        return false if window && Input.trigger?(Input::BACK)
        next if Time.now < next_poll
        fetch
        current = [@dungeon["status"], @dungeon["node_index"], @dungeon["battle_id"], @dungeon["readies"], @dungeon["rested"], @dungeon["abandon_votes"]]
        return true if current != initial || terminal?
        next_poll = Time.now + 0.5
      end
    ensure
      pbDisposeMessageWindow(window) if window
    end
    def run_node
      id = @dungeon["battle_id"]
      raise Error, "Route node has no battle" unless id.is_a?(String)
      battle = client.request("GET", "/v1/battles/#{id}")["battle"]
      raise Error, "Battle is not bound to this route" unless battle["dungeon_id"] == @dungeon["id"] && battle["node_index"] == @dungeon["node_index"]
      unless @played[id]
        KIFMultiplayer.run_boss(client, {"code" => @dungeon["room_code"]}, battle)
        @played[id] = true
      end
      if host?
        # The server uses the final resolve's atomic team_states. A crash after
        # winning but before this call therefore does not lose bench HP/PP.
        mutate("advance", {"battle_id" => id})
      else
        wait_for_change
      end
    end
    def claim
      raise Error, "Route is not complete" unless @dungeon["status"] == "completed"
      reward = client.request("POST", "#{@path}/claim", {})["reward"]
      raise Error, "Invalid route reward" unless reward.is_a?(Hash) && reward["owner_id"] == client.player_id && reward["kind"] == "dungeon_medal" && reward["dungeon_id"] == @dungeon["id"]
      KIFMultiplayer.battle_event("dungeon_reward", reward)
      reward
    end
    def play(automatic = false)
      fetch
      ui = UI.new(client)
      loop do
        if terminal?
          reward = claim if @dungeon["status"] == "completed"
          pbMessage("#{title}\n#{reward ? '副本纪念章已登记，每人每路线一次。' : '本次路线已结束，不发主线资源。'}") unless automatic
          return @dungeon
        end
        votes = @dungeon["abandon_votes"] || []
        if !automatic && !votes.empty? && !votes.include?(client.player_id) && @seen_votes != votes
          @seen_votes = votes.dup
          vote = ui.choose(title + "\n队友请求放弃；只有双方同意才会结束。", ["同意放弃", "继续路线", "返回"])
          return @dungeon if vote < 0 || vote == 2
          if vote == 0
            mutate("abandon")
            next
          end
        end
        case @dungeon["status"]
        when "battle"
          return @dungeon if run_node == false
        when "preparing"
          if @dungeon["readies"].include?(client.player_id)
            return @dungeon unless wait_for_change
          elsif automatic
            mutate("ready", {"ready" => true})
          else
            option = ui.choose(title, ["准备进入节点", "双方确认放弃", "返回"])
            return @dungeon if option < 0 || option == 2
            option == 0 ? mutate("ready", {"ready" => true}) : mutate("abandon")
          end
        when "rest"
          if @dungeon["rested"].include?(client.player_id)
            return @dungeon unless wait_for_change
          elsif automatic || pbConfirmMessage("#{title}\n使用本次休息恢复自己的临时队伍？不补回已消耗携带物。")
            mutate("rest", {"choice" => "heal"})
          else
            return @dungeon
          end
        else
          raise Error, "Unsupported route state: #{@dungeon['status']}"
        end
        fetch unless terminal?
      end
    end
  end

  def self.open_dungeon_menu(client)
    ui = UI.new(client)
    ui.connect
    loop do
      choice = ui.choose("固定路线合作副本\n三场普通合作战 → 各自一次休息 → 最终Boss。\nHP/PP/异常与携带物只在临时队伍中延续。", ["从当前已选队 Boss 房间创建", "恢复我的路线", "输入路线编号", "返回"])
      return if choice < 0 || choice == 3
      ui.perform do
        case choice
        when 0
          raise Error, "请先在双人Boss房间中双方选好三只队伍，暂不开始战斗。" unless client.room_code
          route = client.request("POST", "/v1/dungeons", {"room_code" => client.room_code})["dungeon"]
        when 1
          routes = client.request("GET", "/v1/dungeons")["dungeons"]
          raise Error, "没有可恢复的路线。" if routes.empty?
          index = ui.choose("我的路线", routes.map { |d| "#{d['id']} · #{d['status']} · 节点#{d['node_index'] + 1}" } + ["返回"])
          next unless index.between?(0, routes.length - 1)
          route = routes[index]
        when 2
          id = ui.enter("输入共同路线编号", "", 50)
          next if id.empty?
          route = {"id" => id}
        end
        DungeonSession.new(client, route["id"]).play
      end
    end
  end
end
