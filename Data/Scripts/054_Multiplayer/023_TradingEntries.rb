module KIFMultiplayer
  def self.open_nearby_trades
    raise Error, "请先进入在线地图。" unless defined?(OnlineMode) && OnlineMode.active? && OnlineMode.world
    with_trading_scene do
      world = OnlineMode.world
      client = world.client
      ui, trading = UI.new(client), TradingClient.new(client)
      loop do
        position = world.position
        raise Error, "当前地图位置不可用。" unless position
        players = world.players.select { |player| [(player["x"] - position["x"]).abs, (player["y"] - position["y"]).abs].max <= 5 }
        selected = ui.choose("附近玩家 · 同地图五格内\n#{players.length} 人；收到邀请可从交易中心恢复。", players.map { |player| display_text(player["nickname"]) } + ["刷新", "返回"])
        break if selected < 0 || selected >= players.length + 1
        if selected == players.length
          world.tick
          next
        end
        player = players[selected]
        next unless pbConfirmMessage("向 #{display_text(player['nickname'])} 发起交易邀请？")
        session = trading.invite_nearby(player["id"])
        TradingUI.new(client).exchange_menu(session)
      end
    end
  end

  module TradingPauseEntry
    def pbShowCommands(commands)
      return super unless defined?(OnlineMode) && OnlineMode.active?
      choices = commands + ["交易中心", "附近玩家"]
      loop do
        result = super(choices)
        return result unless result == commands.length || result == commands.length + 1
        pbHideMenu
        begin
          UI.new(OnlineMode.world.client).perform do
            result == commands.length ? KIFMultiplayer.open_trading_menu(OnlineMode.world.client) : KIFMultiplayer.open_nearby_trades
          end
        ensure
          pbShowMenu
        end
      end
    end
  end

  class TradingPC
    def shouldShow?; defined?(OnlineMode) && OnlineMode.active? && OnlineMode.world; end
    def name; "全球交易市场"; end
    def access
      UI.new(OnlineMode.world.client).perform { KIFMultiplayer.open_trading_menu(OnlineMode.world.client) }
    end
  end
end

PokemonPauseMenu_Scene.prepend(KIFMultiplayer::TradingPauseEntry) if defined?(PokemonPauseMenu_Scene)
PokemonPCList.registerPC(KIFMultiplayer::TradingPC.new) if defined?(PokemonPCList)
