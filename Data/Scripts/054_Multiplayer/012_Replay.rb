# A replay presents recorded authoritative frames. It never runs combat again,
# imports received Pokemon into a save, or uses a replay as a reward receipt.
module KIFMultiplayer
  module ReplayData
    def self.check(condition, message); raise Error.new(message, "invalid_replay") unless condition; end
    def self.validate(replay, compatibility)
      check(replay.is_a?(Hash) && replay["compatibility"] == compatibility, "Replay game/data/mod/rules differ")
      players = replay["players"]
      check(players.is_a?(Array) && players.length == 2 && players.uniq.length == 2 && players.all? { |p| p.is_a?(String) && p =~ /\Ap_[a-f0-9]+\z/ }, "Invalid replay participants")
      data = replay["data"]
      check(data.is_a?(Hash) && data["version"] == 1 && players.include?(data["host_id"]), "Invalid replay version or authority")
      check(%w[friendly_singles rental_singles coop_boss].include?(data["mode"]), "Unsupported replay mode")
      check(data["initial_teams"].is_a?(Hash) && data["initial_teams"].keys.sort == players.sort, "Replay teams do not match participants")
      data["initial_teams"].each_value do |party|
        check(party.is_a?(Array) && party.length == 3, "Invalid replay party size")
        party.each { |pokemon| Snapshot.validate(pokemon) }
      end
      updates = data["updates"]
      check(updates.is_a?(Array) && updates.length.between?(1, 10000), "Invalid replay frame count")
      previous, visual_sequence = -1, 0
      updates.each do |update|
        check(update.is_a?(Hash) && update["turn"].is_a?(Integer) && update["turn"] > previous, "Replay phase order is damaged")
        previous = update["turn"]
        state = update["state"]
        check(state.is_a?(Hash) && %w[command switch].include?(state["kind"]), "Invalid replay phase")
        check(state["battlers"].is_a?(Array) && state["battlers"].length.between?(1, 4), "Invalid replay battlers")
        slots = state["battlers"].map { |entry| entry.is_a?(Hash) && entry["index"] }
        check(slots.uniq.length == slots.length, "Duplicate replay battler slot")
        state["battlers"].each do |b|
          check(b.is_a?(Hash) && Snapshot.number(b["index"], 0, 3) && Snapshot.number(b["totalhp"], 1, 100000) && Snapshot.number(b["hp"], 0, b["totalhp"]), "Invalid recorded HP")
          check(players.include?(b["owner_id"]) || (data["mode"] == "coop_boss" && b["owner_id"] == "boss"), "Invalid recorded owner")
          check(b["status"].is_a?(String) && %w[NONE SLEEP POISON BURN PARALYSIS FROZEN].include?(b["status"]), "Invalid recorded status")
          Snapshot.registry(:Species, b["species"])
          check(b["name"].nil? || (b["name"].is_a?(String) && b["name"].length <= 32), "Invalid replay nickname")
          check(!b.key?("level") || Snapshot.number(b["level"], 1, 100), "Invalid replay level")
        end
        if state.key?("visuals")
          check(defined?(BattleVisuals), "Public visual decoder is unavailable")
          begin
            visuals = BattleVisuals.validate(state["visuals"], state)
            check(visuals["seq"] > visual_sequence, "Replay visual sequence is damaged")
            visual_sequence = visuals["seq"]
            visuals["battlers"].each do |pokemon|
              battler = state["battlers"].find { |entry| entry["index"] == pokemon["slot"] }
              %w[species hp totalhp status level party_index].each do |key|
                check(!battler.key?(key) || battler[key] == pokemon[key], "Replay visual state differs from its authoritative frame")
              end
            end
          rescue StandardError => error
            raise error if error.is_a?(Error) && error.code == "invalid_replay"
            raise Error.new("Invalid replay public visual data", "invalid_replay")
          end
        end
        check(state["events"].is_a?(Array) && state["events"].length <= 256 && state["events"].all? { |text| text.is_a?(String) && text.length <= 2048 }, "Invalid replay event text")
        check(update["random_tape"].is_a?(Array) && update["random_tape"].length <= 10000, "Invalid replay random trace")
        update["random_tape"].each do |roll|
          check(roll.is_a?(Hash) && Snapshot.number(roll["limit"], 1, 2147483647) && Snapshot.number(roll["value"], 0, roll["limit"] - 1), "Invalid replay random result")
        end
      end
      result = data["result"]
      check(result.is_a?(Hash) && result == replay["result"] && result["id"].is_a?(String) && (result["winner_id"].nil? || players.include?(result["winner_id"])), "Replay final result is inconsistent")
      data
    end
  end

  def self.play_replay(client, replay, automatic = false)
    original_update = client.wait_update
    original_scene = $scene
    client.wait_update = nil
    data = ReplayData.validate(replay, client.compatibility)
    BattleIsolation.with do
      begin
        # Message windows call pbUpdateSceneMap. Cloning save globals alone
        # does not clone the map/player/events held by the original Scene_Map.
        $scene = Object.new
        data["updates"].each do |update|
          board = nil
          begin
            board = BattleBoard.new(update["state"])
            battle_event("replay_frame", {"replay_id" => replay["id"], "turn" => update["turn"], "state" => update["state"]})
            if automatic
              3.times { client.pump }
            else
              text = "回放 · 阶段 #{update['turn']}\n" + update["state"]["events"].map { |line| battle_text(line) }.join("\n")
              pbMessage(text.empty? ? "下一阶段" : text)
            end
          ensure
            board.dispose if board
          end
        end
        battle_event("replay_finished", {"replay_id" => replay["id"], "result" => data["result"]})
        pbMessage("回放结束：#{battle_text(data['result']['reason'])}\n不会修改存档或发放奖励。") unless automatic
      ensure
        $scene = original_scene
      end
    end
    data["result"]
  ensure
    client.wait_update = original_update if defined?(original_update)
  end

  def self.open_replay_menu(client)
    ui = UI.new(client)
    ui.connect
    loop do
      choice = ui.choose("战斗回放分享\n结束后双方同意才发布，可能公开完整配招。\n已下载副本无法撤回。", ["从已结束战斗创建", "我的回放 / 公开回放", "输入分享编号", "返回"])
      return if choice < 0 || choice == 3
      ui.perform do
        case choice
        when 0
          id = ui.enter("输入已结束的战斗编号", "", 80)
          next if id.empty?
          replay = client.request("POST", "/v1/replays", {"battle_id" => id})["replay"]
        when 1
          replays = client.request("GET", "/v1/replays")["replays"]
          raise Error, "没有可访问的回放。" if replays.empty?
          index = ui.choose("回放列表", replays.map { |r| "#{r['id']} · #{r['status']} · #{r['consents'].length}/2同意" } + ["返回"])
          next unless index.between?(0, replays.length - 1)
          replay = replays[index]
        when 2
          id = ui.enter("输入回放编号", "", 80)
          next if id.empty?
          replay = client.request("GET", "/v1/replays/#{id}")["replay"]
        end
        action = ui.choose("#{display_text(replay['id'])}\n#{display_text(replay['status'])} · 同意#{replay['consents'].length}/2", ["观看", "同意公开完整记录", "撤回同意 / 下架", "发布（创建者）", "返回"])
        path = "/v1/replays/#{replay['id']}"
        case action
        when 0
          downloaded = client.request("POST", path + "/download", {"compatibility" => client.compatibility})["replay"]
          play_replay(client, downloaded)
        when 1
          client.request("POST", path + "/consent", {"consent" => true}) if pbConfirmMessage("同意公开双方初始配置、指令、随机记录与结果？")
        when 2
          client.request("POST", path + "/consent", {"consent" => false})
        when 3
          client.request("POST", path + "/publish", {"visibility" => "unlisted"})
          pbMessage("已发布分享编号：#{display_text(replay['id'])}")
        end
      end
    end
  end
end
