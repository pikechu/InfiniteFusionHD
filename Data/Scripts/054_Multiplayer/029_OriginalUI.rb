module KIFMultiplayer
  module OriginalPresentation
    def self.with
      previous = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables,
                  $game_temp, $game_system, $PokemonTemp, $scene]
      resolution = [Graphics.width, Graphics.height]
      Graphics.resize_screen(Settings::SCREEN_WIDTH, Settings::SCREEN_HEIGHT) if resolution != [Settings::SCREEN_WIDTH, Settings::SCREEN_HEIGHT]
      $Trainer ||= Player.new("Online", :POKEMONTRAINER_Red)
      $PokemonBag ||= PokemonBag.new
      $PokemonGlobal ||= PokemonGlobalMetadata.new
      $PokemonSystem ||= PokemonSystem.new
      $game_switches ||= Game_Switches.new
      $game_variables ||= Game_Variables.new
      $game_temp = Game_Temp.new
      $game_system = Game_System.new
      $PokemonTemp = PokemonTemp.new
      BattleIsolation.with { yield }
    ensure
      $Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables,
        $game_temp, $game_system, $PokemonTemp, $scene = previous
      Graphics.resize_screen(*resolution) if resolution && [Graphics.width, Graphics.height] != resolution
    end
  end
  class OriginalUI < UI
    def main(id = nil)
      controlled = ControlledClient.new(@client)
      loop do
        return unless perform { controlled.refresh }
        if id
          selected = controlled.character(id)
        else
          rows = controlled.characters
          selected_index = choose("原版在线角色\n服务器保存剧情、精灵和资产。", rows.map { |row| "#{text(row['name'])} · GOLD #{row['wallet']['balance']}" } + ["新建角色", "返回"])
          return unless selected_index.is_a?(Integer) && selected_index.between?(0, rows.length)
          if selected_index == rows.length
            name = enter("原版角色名称", @client.identity["nickname"].to_s[0,20], 20)
            next if name.empty?
            selected = perform { controlled.create(name) }
            next unless selected
          else
            selected = rows[selected_index]
          end
        end
        model = OriginalClient.new(@client)
        next unless perform { model.refresh(selected["id"]) }
        unless model.original["active"]
          migration = model.original["migration"]
          if migration && migration["active_battle"]
            if pbConfirmMessage("此角色有尚未结束的旧对局。先继续或放弃该对局，再迁移到原版主线？")
              ControlledAdventureUI.new(@client).finish_historical(selected["id"])
            end
            return if id
            next
          end
          if migration && migration["required"]
            if pbConfirmMessage("迁移此服务器旧角色？保留 GOLD、背包、精灵编号、等级、基因和招式；旧章节归档，原版剧情从开场开始。\n能力值和解除融合按原版计算，蛋的剩余时间转换为孵化步数。仅迁移服务器已有资产。")
              next unless perform { model.act("migrate", {"policy" => migration["policy"]}) }
            else
              return if id
              next
            end
          else
          return if id && !pbConfirmMessage("开始此角色的原版主线？服务器保存，旧本地存档不导入。")
          next unless perform { model.act("activate") }
          end
        end
        OriginalPresentation.with { OriginalWorldScene.new(model, self).run }
        return if id
      end
    end
    def prompt_value(prompt)
      title = text(prompt["text"] || "请选择")
      case prompt["kind"]
      when "credits"
        previous_scene = $scene
        begin
          $PokemonGlobal.creditsPlayed = prompt["played"] == true
          $scene = Scene_Credits.new
          $scene.main
        ensure
          $scene = previous_scene
        end
        true
      when "movie"
        raise Error, "原版影片参数无效。" unless prompt["path"].is_a?(String) && prompt["path"].start_with?("Graphics/Pictures/") && !prompt["path"].split("/").include?("..") && prompt["frames"].is_a?(Integer) && prompt["frames"].between?(1,10000)
        viewport = Viewport.new(0,0,Graphics.width,Graphics.height)
        viewport.z = 100005
        begin
          Movie.new(prompt["path"],prompt["bgm"],prompt["frames"],prompt["can_stop"]).playInViewPort(viewport)
        ensure
          viewport.dispose
        end
        true
      when "fishing"
        remaining = @current_model.original.fetch("prompt_remaining", prompt["seconds"])
        window = Window_AdvancedTextPokemon.new(prompt["phase"] == "wait" ? "等待鱼讯……\n按确认或返回可收竿。" : "上钩了！立即按确认键拉竿！")
        window.width, window.height, window.z = Graphics.width, 128, 99999
        window.y = Graphics.height-window.height
        finish = KIFMultiplayer.monotonic + remaining
        begin
          loop do
            Graphics.update
            Input.update
            window.update
            @client.pump
            return "use" if Input.trigger?(Input::USE)
            return "back" if Input.trigger?(Input::BACK)
            return nil if KIFMultiplayer.monotonic >= finish
          end
        ensure
          window.dispose
        end
      when "gallery"
        raise Error, "画展素材编号无效。" unless prompt["species"].to_s =~ /\A[A-Z0-9_]{1,64}\z/ && prompt["alt"].to_s =~ /\A[a-zA-Z]*\z/ && ["BASE", "CUSTOM", "AUTOGEN"].include?(prompt["type"])
        sprite = PIFSprite.new(prompt["type"].to_sym, prompt["head"], prompt["body"], prompt["alt"])
        sprite.local_path = check_for_local_sprite(sprite)
        if sprite.local_path
          displaySpriteWindowWithMessage(sprite, title, 90, -10, 201)
        else
          pbMessage(title + "\n#{prompt['species']} · 此画作素材尚未安装。")
        end
        true
      when "voltorb"
        board = prompt["tiles"].each_slice(5).map.with_index { |row, index| row.map { |value| value.nil? ? "·" : value.to_s }.join(" ") + "  #{prompt['rows'][index].join('/')}" }.join("\n")
        action = choose("霹雳电球翻牌 Lv.#{prompt['level']}\n#{board}\n本局 #{prompt['points']} · 代币 #{prompt['coins']}", ["翻牌", "标记", "结束并结算"])
        return {"row" => -1, "column" => -1, "mark" => false} unless action && action.between?(0,1)
        row = choose("选择行 · 数字总和 / 电球数", prompt["rows"].each_with_index.map { |clue, index| "第#{index+1}行 #{clue.join('/')}" })
        column = choose("选择列 · 数字总和 / 电球数", prompt["columns"].each_with_index.map { |clue, index| "第#{index+1}列 #{clue.join('/')}" })
        {"row" => row || -1, "column" => column || -1, "mark" => action == 1}
      when "slot"
        icons = ["樱桃", "小磁怪", "大舌贝", "皮卡丘", "可达鸭", "红7", "蓝7", "重玩"]
        reels = prompt["reels"].map { |reel| reel.map { |symbol| icons.fetch(symbol) }.join(" / ") }.join("\n")
        choices = prompt["mode"] == "stop" ? ["停止当前转轴"] : ["投入一枚代币", "开始", "离开"]
        pbMessage("代币 #{prompt['credit']} · 投入 #{prompt['wager']}\n#{reels}", choices, 0)
      when "region_map"
        pbShowMap(prompt["region"], prompt["wallmap"])
        true
      when "choice"
        pbMessage(title, prompt["choices"].map { |value| text(value) }, prompt.fetch("cancel", -1))
      when "confirm" then pbConfirmMessage(title)
      when "name"
        pbEnterText(title, 0, prompt.fetch("maximum", Pokemon::MAX_NAME_SIZE), "")
      when "number"
        params = ChooseNumberParams.new
        params.setRange(prompt["minimum"], prompt["maximum"])
        params.setDefaultValue(prompt.fetch("default", prompt["minimum"]))
        params.setCancelValue(prompt["cancellation"]) if prompt.key?("cancellation")
        pbMessageChooseNumber(title, params)
      when "pokemon"
        rows = @current_model.original["view"]["party"]
        choice = choose(title, rows.map { |monster| "#{text(monster['name'])} Lv.#{monster['level']}" } + ["返回"])
        choice && choice < rows.length ? choice : -1
      when "forget_move"
        monster = @current_model.original["view"]["party"].find { |row| row["species"] == prompt["species"] }
        choices = (monster && monster["moves"] || []).map { |move| move_name(move["id"]) }
        choice = choose("替换哪个招式？", choices + ["放弃学习"])
        choice && choice < choices.length ? choice : -1
      when "storage"
        choices = prompt["boxes"].map { |box| text(box["name"]) } + ["队伍", "箱子设置", "关闭电脑"]
        box = choose("选择储存区域#{prompt['held'] ? ' · 正携带 ' + text(prompt['held']['name']) : ''}", choices)
        return {"box" => -3, "slot" => 0} unless box && box.between?(0, choices.length - 2)
        return {"box" => -4, "slot" => 0} if box == prompt["boxes"].length + 1
        if box == prompt["boxes"].length
          rows = prompt["party"]
          labels = (0...6).map { |index| rows[index] ? "#{index + 1}: #{text(rows[index]['name'])} Lv.#{rows[index]['level']}" : "#{index + 1}: 空位" }
          box_id = -1
        else
          entry = prompt["boxes"].fetch(box)
          labels = (0...entry["size"]).map do |slot|
            row = entry["pokemon"].find { |value| value["slot"] == slot }
            row ? "#{slot + 1}: #{text(row['monster']['name'])} Lv.#{row['monster']['level']}" : "#{slot + 1}: 空位"
          end
          box_id = entry["id"]
        end
        slot = choose("选择位置", labels + ["返回"])
        slot && slot.between?(0, labels.length - 1) ? {"box" => box_id, "slot" => slot} : {"box" => -3, "slot" => 0}
      else raise Error, "当前原版交互类型无法显示：#{prompt['kind']}"
      end
    end
    def current_model=(model); @current_model = model; end
    def move_name(id)
      GameData::Move.exists?(id.to_sym) ? text(GameData::Move.get(id.to_sym).name) : text(id)
    end
    def pause_menu(model)
      case choose("#{text(model.character['name'])} · GOLD #{model.character['wallet']['balance']}\n#{model.character['id']}", ["队伍与培养", "背包与关键道具", "刷新服务器状态", "返回游戏", "退出角色", "原版交易中心", "任务记录", "保存检查点"])
      when 0 then party_menu(model)
      when 1
        items = model.character["inventory"]
        selected = choose("背包 · 由服务器执行原版使用规则", items.map { |item| "#{item_name(item['item'])} × #{item['quantity']}" } + ["返回"])
        model.act("field_item", {"item" => items[selected]["item"]}) if selected && selected.between?(0,items.length-1)
      when 2 then model.refresh
      when 4 then return :exit
      when 5 then OriginalCommerceUI.new(@client).main(model)
      when 6
        quests = model.original["view"].fetch("quests", [])
        selected = choose("任务记录", quests.map { |quest| "#{quest['completed'] ? '✓' : '□'} #{text(quest['name'])}" } + ["返回"])
        if selected && selected.between?(0,quests.length-1)
          quest = quests[selected]
          pbMessage("#{text(quest['name'])}\n#{text(quest['description'])}\n#{text(quest['npc'])} · #{text(quest['location'])}")
        end
      when 7 then model.act("save")
      end
      nil
    end
    def item_name(id)
      GameData::Item.exists?(id.to_sym) ? text(GameData::Item.get(id.to_sym).name) : text(id)
    end
    def party_menu(model)
      rows = model.original["view"]["party"]
      return pbMessage("队伍中还没有精灵。") if rows.empty?
      index = choose("原版队伍", rows.map { |row| "#{text(row['name'])} Lv.#{row['level']} HP #{row['hp']}/#{row['max_hp']}" } + ["返回"])
      return unless index && index.between?(0, rows.length - 1)
      monster = rows[index]
      choice = choose("#{text(monster['name'])}\n#{text(monster['ability'])} · #{text(monster['nature'])}\n经验 #{monster['exp']} · 亲密度 #{monster['happiness']}\nIV #{monster['iv'].values.join('/')}\nEV #{monster['ev'].values.join('/')}", ["查看招式", "使用道具", "给予携带物", "取下携带物", "返回", "使用场外招式", "设为队首"])
      case choice
      when 0 then pbMessage(monster["moves"].map { |move| "#{move_name(move['id'])} PP #{move['pp']}/#{move['total_pp']}" }.join("\n"))
      when 1, 2
        items = model.character["inventory"]
        item_index = choose("选择已拥有的道具", items.map { |item| "#{item_name(item['item'])} × #{item['quantity']}" } + ["返回"])
        if item_index && item_index.between?(0, items.length - 1)
          model.act(choice == 1 ? "use_item" : "give_item", {"monster_id" => monster["id"], "item" => items[item_index]["item"]})
        end
      when 3 then model.act("take_item", {"monster_id" => monster["id"]})
      when 5
        moves = monster["moves"].select { |move| HiddenMoveHandlers.hasHandler(move["id"].to_sym) }
        selected = choose("选择已掌握的场外招式", moves.map { |move| move_name(move["id"]) } + ["返回"])
        model.act("field_move", {"monster_id" => monster["id"], "move" => moves[selected]["id"]}) if selected && selected.between?(0,moves.length-1)
      when 6
        model.act("reorder", {"party" => [monster["id"]] + rows.map { |row| row["id"] }.reject { |id| id == monster["id"] }})
      end
    end
  end
  class OriginalWorldScene
    def initialize(model, ui)
      @model, @ui = model, ui
      @ui.current_model = model
    end
    def run
      previous_scene, previous_update = $scene, @model.client.wait_update
      $scene = self
      @renderer = OriginalWorldRenderer.new
      @model.client.wait_update = proc { capture_input; @renderer.update }
      adopt
      last_wait = KIFMultiplayer.monotonic
      loop do
        Graphics.update
        Input.update
        @renderer.update
        if @model.original["view"]["battle"]
          @pending_back = @pending_use = false
          break if battle_loop == :exit
          adopt
          next
        elsif @model.original["prompt"]
          @pending_back = @pending_use = false
          break if respond == :exit
          next
        end
        now = KIFMultiplayer.monotonic
        if @pending_back || Input.trigger?(Input::BACK)
          @pending_back = @pending_use = false
          break if @ui.pause_menu(@model) == :exit
          adopt
        elsif now < (@busy_until || 0)
          @model.client.pump
        elsif @pending_use || Input.trigger?(Input::USE)
          @pending_use = false
          act("interact")
        elsif Input.dir4 != 0 && now >= @model.move_ready_at
          act("move", {"direction" => Input.dir4})
        elsif now - last_wait >= 0.25
          act("wait")
          last_wait = KIFMultiplayer.monotonic
        end
        @renderer.connection_status = "心跳暂未送达，连接恢复后重试" if @model.heartbeat == false
      end
    ensure
      @renderer.dispose if @renderer
      @model.client.wait_update = previous_update
      $scene = previous_scene
    end
    def adopt
      @renderer.adopt(@model.original["view"], @model.character)
    end
    def capture_input
      return if @model.original["prompt"] || @model.original["view"]["battle"]
      @pending_back ||= Input.trigger?(Input::BACK)
      @pending_use ||= Input.trigger?(Input::USE)
    end
    def events(response)
      (response["events"] || []).each { |event| pbMessage(KIFMultiplayer.display_text(event["text"])) if event["kind"] == "message" }
    end
    def act(kind, arguments = {})
      response = @ui.perform do
        begin
          if @needs_refresh
            @model.refresh
            @needs_refresh = false
            {"events" => []}
          else
            @model.act(kind, arguments)
          end
        rescue UncertainRequest
          # Refresh recovers the persisted operation ID before another intent.
          raise unless kind == "wait"
          @needs_refresh = true
          @busy_until = KIFMultiplayer.monotonic+1.0
          @renderer.connection_status = "连接中断，正在查询上次操作"
          nil
        rescue Error => error
          raise unless %w[original_rules_busy service_busy request_rate_limited original_movement_rate].include?(error.code)
          @busy_until = KIFMultiplayer.monotonic+0.4
          @renderer.connection_status = "服务器忙，稍后重试"
          nil
        end
      end
      if response
        @busy_until = nil
        @renderer.connection_status = nil
        adopt
        events(response) unless @model.original["view"]["battle"]
      else
        return nil if @busy_until
        @ui.perform { @model.refresh }
        adopt
      end
      response
    end
    def respond
      response = @ui.perform do
        value = @ui.prompt_value(@model.original["prompt"])
        @model.choose(value)
      end
      unless response
        return :exit unless @ui.choose("服务器已保留此交互。", ["重新读取并继续", "退出角色，稍后继续"]) == 0
        return :exit unless @ui.perform { @model.refresh }
      end
      adopt
      events(response) if response
    end
    def battle_loop
      @renderer.visible = false
      session = OriginalVisualSession.new(@model)
      presenter_class = @model.original["view"]["battle"]["mode"] == "safari" ? OriginalSafariPresenter : OriginalBattlePresenter
      presenter_class.with(session) do |presenter|
        presenter.accept_original({})
        while @model.original["view"]["battle"] && @model.original["prompt"]
          value = presenter.prompt_value(@model.original["prompt"], @ui)
          response = @ui.perform { @model.choose(value) }
          if response
            presenter.accept_original(response)
          else
            return :exit unless @ui.choose("战斗与未确认操作已保留。", ["重新读取并继续", "退出角色，稍后继续"]) == 0
            return :exit unless @ui.perform { @model.refresh }
          end
        end
      end
    ensure
      @renderer.visible = true
    end
  end
end
