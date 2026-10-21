# Published gyms contain versioned JSON Pokemon snapshots, never scripts. A
# downloaded challenge uses the existing AI and isolated temporary parties.
module KIFMultiplayer
  class << self
    attr_accessor :gym_controller, :gym_observer
    def gym_event(event, payload)
      @gym_observer.call(event, payload) if @gym_observer
    end
  end

  class GymSession
    attr_reader :client
    def initialize(client); @client = client; end
    def journal; client.profile.account["gym_session"]; end

    def remember(challenge)
      raise Error, "Challenge belongs to another identity" unless challenge["owner_id"] == client.player_id && challenge["id"].is_a?(String) && challenge["id"] =~ /\Agc_[a-f0-9]{32}\z/
      client.profile.account["gym_session"] = {"id" => challenge["id"], "owner_id" => client.player_id}
      client.profile.save
    end

    def finish(challenge, outcome, turns, summary)
      remember(challenge) unless journal
      raise Error, "Restore the original challenge identity first" unless journal["owner_id"] == client.player_id && journal["id"] == challenge["id"]
      body = journal["report"] ||= {"outcome" => outcome, "turns" => turns, "summary" => summary,
                                     "request_id" => KIFMultiplayer.operation_id}
      client.profile.save # The exact report survives a lost response/restart.
      result = client.request("POST", "/v1/gym-challenges/#{challenge['id']}/result", body)["challenge"]
      reward = nil
      if result.dig("result", "outcome") == "win"
        reward = client.request("POST", "/v1/gym-challenges/#{challenge['id']}/claim", {})["reward"]
        raise Error, "Invalid Gym medal receipt" unless reward.is_a?(Hash) && reward["owner_id"] == client.player_id && reward["kind"] == "gym_medal"
      end
      client.profile.account.delete("gym_session")
      client.profile.save
      KIFMultiplayer.gym_event("gym_report", {"challenge" => result, "reward" => reward})
      {"challenge" => result, "reward" => reward}
    end

    def adopt_recovered_challenge(discover = false)
      return journal if journal
      operation = client.profile.account["last_recovered_operation"]
      if operation.is_a?(Hash) && operation["path"].to_s =~ /\A\/v1\/gyms\/[A-F0-9]{8}\/challenge\z/
        challenge = operation.dig("response", "challenge")
        if challenge.is_a?(Hash) && challenge["owner_id"] == client.player_id
          remember(challenge)
          client.profile.account.delete("last_recovered_operation")
          client.profile.save
        end
      end
      if !journal && discover
        # A different recovered operation may have replaced the one local
        # receipt slot before this menu was opened. Discover the original
        # server-owned active challenge instead of creating a second attempt.
        challenges = client.request("GET", "/v1/gym-challenges")["challenges"]
        raise Error, "Invalid AI Gym challenge list" unless challenges.is_a?(Array)
        candidate = challenges.find do |challenge|
          challenge.is_a?(Hash) && challenge["status"] == "active" &&
            challenge["owner_id"] == client.player_id && challenge["id"].is_a?(String) &&
            challenge["id"] =~ /\Agc_[a-f0-9]{32}\z/
        end
        remember(candidate) if candidate
      end
      journal
    end

    def recover
      client.recover_pending
      adopt_recovered_challenge(true)
      return nil unless journal
      raise Error, "Restore the identity owning this Gym challenge" unless journal["owner_id"] == client.player_id
      challenge = client.request("GET", "/v1/gym-challenges/#{journal['id']}")["challenge"]
      report = journal["report"]
      if report
        finish(challenge, report["outcome"], report["turns"], report["summary"])
      elsif challenge["status"] == "finished"
        report = challenge["result"]
        finish(challenge, report["outcome"], report["turns"], report["summary"])
      else
        finish(challenge, "abnormal", 0, "Local challenge process ended before a result was saved")
      end
    end
  end

  previous_identity_guard = identity_change_guard
  self.identity_change_guard = proc do |profile|
    previous_identity_guard.call(profile) if previous_identity_guard
    pending = profile.data.fetch("servers", {}).values.any? { |account| account.is_a?(Hash) && account["gym_session"] }
    raise Error.new("Recover the pending Gym report before changing servers or identities.", "identity_switch_pending") if pending
  end

  def self.run_gym_challenge(client, challenge)
    raise Error, "Invalid AI Gym challenge" unless challenge.is_a?(Hash) && challenge["status"] == "active" &&
      challenge["owner_id"] == client.player_id && challenge["team"].is_a?(Array) && challenge["team"].length == 3 &&
      challenge["defender_team"].is_a?(Array) && challenge["defender_team"].length.between?(1, 6)
    session = GymSession.new(client)
    raise Error, "Recover the pending Gym challenge first" if session.journal && session.journal["id"] != challenge["id"]
    session.remember(challenge)
    old_update = client.wait_update
    summary, rounds, decision = [], 0, 0
    begin
      decision = BattleIsolation.with do
        parties = [challenge["team"], challenge["defender_team"]].map do |team|
          team.map do |snapshot|
            pokemon = Snapshot.import(snapshot, 50)
            pokemon.name = battle_text(pokemon.name)
            pokemon
          end
        end
        $Trainer.party = parties[0]
        opponent = NPCTrainer.new(battle_text(challenge["gym_name"] || "AI Gym")[0, 32], $Trainer.trainer_type)
        opponent.party = parties[1]
        scene = pbNewBattleScene
        engine = KIFMultiplayerAIBattle.new(scene, parties[0], parties[1], $Trainer, opponent, @gym_controller)
        engine.intro_text = battle_text(challenge["intro"])
        client.wait_update = proc { scene.pbUpdate }
        gym_event("gym_engine_started", {"id" => challenge["id"], "gym_version" => challenge["gym_version"]})
        result = BattlePresentation.with(scene) do
          pbBGMPlay(pbGetTrainerBattleBGM(opponent))
          engine.pbStartBattle
        end
        rounds = engine.round_count
        summary = engine.report_events
        result
      end
    rescue StandardError, BattleInterrupted => error
      client.wait_update = old_update
      session.finish(challenge, "abnormal", rounds, "#{error.class}: #{error.message}".gsub(/[\x00-\x1f]/, " ")[0, 1000])
      raise(error.is_a?(BattleInterrupted) ? error.original : error)
    ensure
      client.wait_update = old_update
    end
    outcome = {1 => "win", 2 => "loss", 3 => "abandon", 4 => "abandon", 5 => "loss"}.fetch(decision, "abnormal")
    gym_event("gym_engine_finished", {"id" => challenge["id"], "decision" => decision, "turns" => rounds})
    session.finish(challenge, outcome, rounds, summary.join(" ")[0, 1800])
  end

  def self.open_gym_menu(client)
    ui = UI.new(client)
    ui.connect
    GymSession.new(client).adopt_recovered_challenge(true)
    loop do
      choice = ui.choose("玩家配置的 AI 道馆\n馆主无需在线；战果是休闲上报，不参与可信排名。", ["道馆目录 / 收藏", "编辑 / 发布我的道馆", "我的挑战与战报", "恢复待提交战报", "返回"])
      return if choice < 0 || choice == 4
      ui.perform do
        case choice
        when 0
          gyms = client.request("GET", "/v1/gyms")["gyms"]
          raise Error, "目前没有可访问的道馆。" if gyms.empty?
          index = ui.choose("道馆目录", gyms.map { |gym| "#{gym['favorite'] ? '★' : ' '} #{display_text(gym['name'])} v#{gym['version']}#{gym['active'] ? '' : '（已关闭）'}" } + ["返回"])
          next unless index.between?(0, gyms.length - 1)
          gym = gyms[index]
          roster = gym["team_preview"].map { |p| p["species"] }.join(" / ")
          action = ui.choose("#{display_text(gym['name'])} v#{gym['version']}\n#{display_text(gym['description'])}\n#{display_text(roster)}\n统一50级、禁背包物品、使用临时队伍。", ["挑战 AI 道馆", gym["favorite"] ? "取消收藏" : "收藏", "下架（馆主）", "返回"])
          case action
          when 0
            raise Error, "请先恢复待提交的道馆战报。" if GymSession.new(client).journal
            team = ui.choose_party_snapshots(3, 3)
            next unless team
            challenge = client.request("POST", "/v1/gyms/#{gym['code']}/challenge", {"compatibility" => client.compatibility, "team" => team})["challenge"]
            result = run_gym_challenge(client, challenge)
            pbMessage("挑战完成：#{display_text(result['challenge']['result']['outcome'])}\n#{result['reward'] ? '首次通关纪念章已登记；重复挑战不重复发放。' : '原精灵和背包保持不变。'}")
          when 1
            client.request("POST", "/v1/gyms/#{gym['code']}/favorite", {"favorite" => !gym["favorite"]})
          when 2
            raise Error, "只有馆主可以下架。" unless gym["owner_id"] == client.player_id
            client.request("POST", "/v1/gyms/#{gym['code']}/close", {}) if pbConfirmMessage("停止接受新挑战？已经创建的挑战继续使用原版本。")
          end
        when 1
          draft = client.profile.account["gym_draft"] || {}
          name = ui.enter("道馆名称", draft["name"] || "我的 AI 道馆", 48)
          next if name.empty?
          description = ui.enter("道馆介绍", draft["description"] || "", 256)
          intro = ui.enter("开场台词", draft["intro"] || "", 128)
          team = ui.choose_party_snapshots(1, 6)
          next unless team
          draft = {"name" => name, "description" => description, "intro" => intro, "team" => team, "compatibility" => client.compatibility}
          client.profile.account["gym_draft"] = draft
          client.profile.save
          preview = "#{display_text(name)}\n#{display_text(description)}\n#{team.map { |p| p['species'] }.join(' / ')}\n这是AI防守队伍快照，更新生成新版本。"
          next unless pbConfirmMessage(preview + "\n发布？")
          code = client.profile.account["gym_code"]
          path = code ? "/v1/gyms/#{code}/publish" : "/v1/gyms"
          gym = client.request("POST", path, draft)["gym"]
          client.profile.account["gym_code"] = gym["code"]
          client.profile.save
          pbMessage("发布成功：#{display_text(gym['code'])} v#{gym['version']}。草稿已保留。")
        when 2
          reports = client.request("GET", "/v1/gym-challenges")["challenges"]
          lines = reports.take(15).map { |c| "#{display_text(c['gym_name'])} v#{c['gym_version']}：#{c.dig('result', 'outcome') || '未提交'}" }
          pbMessage(lines.empty? ? "尚无挑战记录。" : lines.join("\n"))
        when 3
          result = GymSession.new(client).recover
          pbMessage(result ? "原挑战战报与纪念章状态已恢复。" : "没有待恢复战报。")
        end
      end
    end
  end
end

class KIFMultiplayerAIBattle < PokeBattle_Battle
  attr_reader :report_events
  attr_accessor :intro_text
  def initialize(scene, own, defender, player, opponent, controller = nil)
    super(scene, own, defender, player, opponent)
    @gym_controller, @report_events = controller, []
    @internalBattle, @expGain, @moneyGain = false, false, false
    @canRun, @canLose, @switchStyle = true, true, false
    @backdrop = @backdropBase = "indoora"
    @showAnims = ($PokemonSystem.battlescene == 0)
    setBattleMode("single")
  end
  def round_count; (@turnCount || -1) + 1; end
  def pbGainExp; end
  def pbGainMoney; end
  def pbLoseMoney; end
  def pbSetSeen(_battler); end
  def pbRecordAndStoreCaughtPokemon; end
  def pbCanMegaEvolve?(_index); false; end
  def pbDisplay(text)
    @report_events << text.to_s.gsub(/[\x00-\x1f]/, " ")[0, 400]
    @report_events.shift if @report_events.length > 50
    super
  end
  def pbDisplayPaused(text); pbDisplay(text); end
  def pbStartBattleSendOut(send_outs)
    super
    pbDisplay(@intro_text) unless @intro_text.to_s.empty?
  end
  def pbRunMenu(_index)
    return false unless KIFMultiplayer.battle_confirm("放弃本次 AI 道馆挑战？原精灵和背包不变。")
    @decision = 3
    true
  end
  def input_state(index)
    moves, switches = [], []
    @battlers[index].eachMoveWithIndex do |move, i|
      next unless pbCanChooseMove?(index, i, false)
      moves << {"index" => i, "id" => move.id.to_s, "pp" => move.pp, "targets" => [-1]}
    end
    pbParty(index).each_with_index do |pokemon, i|
      switches << {"party_index" => i, "species" => pokemon.species.to_s} if pbCanSwitchLax?(index, i)
    end
    {"kind" => "command", "turn_count" => @turnCount, "battlers" => @battlers.compact.map { |b| {"index" => b.index, "hp" => b.hp, "totalhp" => b.totalhp, "species" => b.displaySpecies.to_s} }, "moves" => moves, "switches" => switches}
  end
  def pbCommandPhase
    return super unless @gym_controller
    @scene.pbBeginCommandPhase
    @battlers.each_with_index { |b, i| pbClearChoice(i) if b && pbCanShowCommands?(i) }
    if pbCanShowCommands?(0)
      action = @gym_controller.call(input_state(0))
      case action && action["action"]
      when "move"
        move = action["move_index"]
        raise KIFMultiplayer::BattleError, "Illegal AI Gym move" unless move.is_a?(Integer) && (0..3).include?(move) && pbCanChooseMove?(0, move, false) && pbRegisterMove(0, move, false)
        pbRegisterTarget(0, -1)
      when "switch"
        raise KIFMultiplayer::BattleError, "Illegal AI Gym switch" unless action["party_index"].is_a?(Integer) && pbRegisterSwitch(0, action["party_index"])
      when "forced" then pbAutoChooseMove(0, false)
      when "surrender" then @decision = 3; return
      else raise KIFMultiplayer::BattleError, "Invalid AI Gym test controller input"
      end
    end
    @battleAI.pbDefaultChooseEnemyCommand(1) if pbCanShowCommands?(1)
  end
  def pbSwitchInBetween(index, lax = false, can_cancel = false)
    return super unless @gym_controller && index.even?
    state = input_state(index).merge("kind" => "switch")
    action = @gym_controller.call(state)
    party = action && action["party_index"]
    legal = party.is_a?(Integer) && (lax ? pbCanSwitchLax?(index, party) : pbCanSwitch?(index, party))
    raise KIFMultiplayer::BattleError, "Illegal AI Gym replacement" unless action && action["action"] == "switch" && legal
    party
  end
  def pbBattleLoop
    @turnCount = 0
    loop do
      pbCommandPhase
      break if @decision > 0
      pbAttackPhase
      break if @decision > 0
      pbEndOfRoundPhase
      break if @decision > 0
      @turnCount += 1
    end
    pbEndOfBattle
  end
  def pbEndOfBattle
    @scene.pbEndBattle(@decision)
    @decision
  end
end
