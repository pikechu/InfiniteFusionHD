module KIFMultiplayer
  module OnlineMode
    class << self
      attr_reader :cloud
      attr_accessor :world, :chatting
      def active?; @mode == :online && !!@cloud; end
      def offline?; @mode == :offline; end
      def directory; active? ? @cloud.directory : nil; end
      def selection_needed?; @selection_needed != false; end
      def request_selection!; @selection_needed = true; end
      def loading?; !!@loading; end
      def safe_to_save?(force = false)
        active? && !@loading && defined?($scene) && (force || $scene.is_a?(Scene_Map) || @chatting) &&
          defined?($Trainer) && $Trainer && $Trainer.name != "Unnamed" &&
          $game_temp && !$game_temp.in_battle && (force || !$game_temp.message_window_showing) &&
          !$game_temp.player_transferring && !pbMapInterpreterRunning? && !$game_player.moving?
      end
      def start(client)
        @loading = true
        session = CloudSession.new(client)
        session.open
        @cloud, @mode, @selection_needed = session, :online, false
        @world = WorldSession.new(client, session.compatibility, session.session_id) if defined?(WorldSession)
        reload_bootup
        true
      rescue Exception
        session.close if session
        @cloud, @world, @mode = nil, nil, nil
        raise
      ensure
        @loading = false
      end
      def offline
        @mode, @selection_needed = :offline, false
        reload_bootup
      end
      def reload_bootup
        # Bootup runs before the title. Switching accounts/modes must reload
        # that mode's settings without carrying the previous player's globals.
        SaveData.instance_variable_get(:@values).each { |value| value.mark_as_unloaded }
        Game.set_up_system
      end
      def stop
        return unless active?
        @cloud.capture(true)
        @cloud.finalize_deferred
        @loading = true
        until @cloud.flush
          choice = pbMessage("在线进度尚未上传，已保留在本机待同步。", ["重试上传", "保留本地记录并返回"], 2)
          break unless choice == 0
        end
        @world.close if @world
        @cloud.close
      ensure
        @cloud, @world, @mode, @loading = nil, nil, nil, false
      end
      def tick
        return unless active? && !@loading && !@ticking
        @ticking = true
        begin
          @cloud.tick
          @world.tick if @world
        ensure
          @ticking = false
        end
      end
      def check_session
        return true unless active? && @cloud.fatal
        unless @session_warning
          @session_warning = true
          KIFMultiplayer.with_ui_fonts do
            pbMessage("在线会话已失效，游戏已暂停。进度保留在本机，请返回登录界面恢复。\n#{KIFMultiplayer.display_text(@cloud.error.message)}")
          end
          $game_temp.to_title = true
        end
        false
      end
      def choose
        stop if active?
        @session_warning = false
        KIFMultiplayer.with_ui_fonts do
          ui = UI.new(KIFMultiplayer.client)
          loop do
            choice = ui.choose("选择游戏模式", ["在线模式（登录与云存档）", "离线模式（本地存档）", "设置服务器", "退出游戏"])
            case choice
            when 0
              return true if login(ui)
            when 1
              offline
              return true
            when 2
              ui.perform do
                url = ui.enter("服务器地址", KIFMultiplayer.client.server, 120)
                KIFMultiplayer.client.profile.server = url unless url.empty?
              end
            else
              return false
            end
          end
        end
      end
      def login(ui)
        client = KIFMultiplayer.client
        client.transport.enable_online_network
        loop do
          choices = ["登录账号", "注册账号", "返回"]
          cached = client.profile.account["username"] && client.token
          choices.unshift("继续登录 #{KIFMultiplayer.display_text(client.profile.account['username'])}") if cached
          choice = ui.choose("在线模式\n#{KIFMultiplayer.display_text(client.server)}", choices)
          return false if choice < 0 || choice == choices.length - 1
          value = ui.perform do
            if cached && choice == 0
              identity = client.request("GET", "/v1/identity")["identity"]
              raise Error, "需要使用账号密码重新登录。" unless identity.is_a?(Hash) && identity["username"] == client.profile.account["username"]
            else
              action = (choice - (cached ? 1 : 0)) == 0 ? "login" : "register"
              username = ui.enter("账号（3至32位字母、数字或下划线）", client.profile.account["username"].to_s, 32)
              next false if username.empty?
              password = pbMessageFreeText("密码（8至128位）", "", true, 128).to_s
              next false if password.empty?
              if action == "register"
                confirm = pbMessageFreeText("再次输入密码", "", true, 128).to_s
                raise Error, "两次输入的密码不一致。" unless password == confirm
                nickname = ui.enter("昵称", username, 32)
              end
              client.authenticate(action, username, password, nickname && !nickname.empty? ? nickname : nil)
              password = confirm = nil
            end
            start(client)
          end
          return true if value
        end
      end
    end
  end

  module OnlineLoadEntry
    def initialize(scene)
      if OnlineMode.selection_needed?
        unless OnlineMode.choose
          $scene = nil
          @kif_cancelled = true
          return
        end
      end
      super
    end
    def pbStartLoadScreen
      return if @kif_cancelled
      super
    end
  end

  module OnlineChatEntry
    def pbShowCommands(commands)
      return super unless OnlineMode.active? && OnlineMode.world
      choices = commands + ["聊天"]
      loop do
        result = super(choices)
        return result unless result == commands.length
        pbHideMenu
        KIFMultiplayer.open_chat
        pbShowMenu
      end
    end
  end

  module OnlineSavePaths
    def get_full_path(name)
      return super unless OnlineMode.active?
      raise Error, "非法在线存档文件名。" unless name.is_a?(String) && name.length.between?(1, 180) && name !~ /[\\\/:\x00-\x1f]/ && !name.include?("..")
      File.join(OnlineMode.directory, name + ".rxdata")
    end
    def move_old_windows_save
      return if OnlineMode.active?
      super
    end
    def get_newest_save_slot
      return super unless OnlineMode.active?
      slots = (SaveData::AUTO_SLOTS + SaveData::MANUAL_SLOTS).select { |slot| OnlineMode.cloud.available?(slot) && File.file?(get_full_path(slot)) }
      slots.max_by { |slot| File.mtime(get_full_path(slot)) }
    end
    def each_slot
      return super unless OnlineMode.active?
      (SaveData::AUTO_SLOTS + SaveData::MANUAL_SLOTS).each { |slot| yield slot if OnlineMode.cloud.available?(slot) }
    end
    def get_next_slot(files, name)
      return super unless OnlineMode.active?
      available = files.select { |slot| OnlineMode.cloud.available?(slot) }
      return name if available.empty?
      index = available.index(name) || -1
      available[(index + 1) % available.length]
    end
    def delete_file(*args)
      raise Error, "在线存档保存在服务器，请使用其他空槽位创建角色。" if OnlineMode.active?
      super
    end
  end

  module OnlineGameSaves
    def save(slot = nil, auto = false, safe: false)
      result = super
      if result && OnlineMode.active?
        name = slot || $Trainer.save_slot
        begin
          OnlineMode.cloud.defer_save(name)
          if OnlineMode.safe_to_save?
            OnlineMode.cloud.queue_save(name, SaveData.compile_save_hash)
          else
            # An event may be mid-script in a manual save. Periodic idle saves
            # capture it once the installed event finishes, avoiding cloud code.
            OnlineMode.cloud.record_error(Error.new("已保存到本机；事件结束后自动同步云端。", "cloud_waiting_for_map"))
            OnlineMode.cloud.defer_save(name)
          end
        rescue StandardError => error
          OnlineMode.cloud.record_error(error)
        end
      end
      result
    end
  end

  module OnlineGraphics
    def update(*args)
      result = super
      OnlineMode.tick
      result
    end
  end
  module OnlineTitleEntry
    def pbCallTitle
      if OnlineMode.active?
        OnlineMode.cloud.capture(true)
        OnlineMode.cloud.finalize_deferred
      end
      OnlineMode.request_selection!
      super
    end
  end
  module OnlineMapGuard
    def update
      if OnlineMode.check_session
        super
      elsif $game_temp.to_title
        $game_temp.to_title = false
        SaveData.mark_values_as_unloaded
        $scene = pbCallTitle
      end
    end
  end
  module OnlineIdentityGuard
    def assert_identity_change_safe!(*args)
      raise Error, "在线游戏中请先保存并返回模式选择，再更换账号或服务器。" if OnlineMode.active?
      super
    end
  end
  module OnlineDisconnectGuard
    def disconnect
      raise Error, "请先保存并退出在线游戏，再选择离线模式。" if OnlineMode.active?
      super
    end
    def recover_identity(*args)
      raise Error, "在线模式使用账号密码登录，请先返回模式选择。" if OnlineMode.active?
      super
    end
  end
end

PokemonLoadScreen.prepend(KIFMultiplayer::OnlineLoadEntry) if defined?(PokemonLoadScreen)
PokemonPauseMenu_Scene.prepend(KIFMultiplayer::OnlineChatEntry) if defined?(PokemonPauseMenu_Scene)
SaveData.singleton_class.prepend(KIFMultiplayer::OnlineSavePaths) if defined?(SaveData)
Game.singleton_class.prepend(KIFMultiplayer::OnlineGameSaves) if defined?(Game)
Graphics.singleton_class.prepend(KIFMultiplayer::OnlineGraphics) if defined?(Graphics)
Object.prepend(KIFMultiplayer::OnlineTitleEntry)
Scene_Map.prepend(KIFMultiplayer::OnlineMapGuard) if defined?(Scene_Map)
KIFMultiplayer.singleton_class.prepend(KIFMultiplayer::OnlineIdentityGuard)
KIFMultiplayer::Client.prepend(KIFMultiplayer::OnlineDisconnectGuard)
