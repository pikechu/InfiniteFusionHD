# Test display-time menu routing; real rendering/HTTP is verified separately.
root = File.expand_path("../..", __dir__)
Dir.chdir(root)
module KIFMultiplayer
  @routes = []
  def self.routes; @routes; end
  def self.open_trading_menu(client); @routes << [:market, client]; end
  def self.open_nearby_trades; @routes << [:nearby]; end
  class UI
    def initialize(client); @client = client; end
    def perform; yield; end
  end
  module OnlineMode
    class << self
      attr_accessor :world, :online
      def active?; @online; end
    end
  end
end
module PokemonPCList
  @pcs = []
  def self.registerPC(pc); @pcs << pc; end
  def self.pcs; @pcs; end
end
class PokemonPauseMenu_Scene
  attr_reader :shown, :hide_count, :show_count
  def initialize(actions)
    @actions, @shown, @hide_count, @show_count = actions, [], 0, 0
  end
  def pbShowCommands(commands); @shown << commands.dup; @actions.shift; end
  def pbHideMenu; @hide_count += 1; end
  def pbShowMenu; @show_count += 1; end
end
load "Data/Scripts/054_Multiplayer/023_TradingEntries.rb"
KIFMultiplayer.define_singleton_method(:open_nearby_trades) { KIFMultiplayer.routes << [:nearby] }
checks = 0
assert = lambda do |condition, description|
  raise "TRADING_ENTRIES_FAIL #{description}" unless condition
  checks += 1
  puts "PASS #{description}"
end
client = Object.new
KIFMultiplayer::OnlineMode.world = Struct.new(:client).new(client)
KIFMultiplayer::OnlineMode.online = true
original = ["背包", "保存"]
scene = PokemonPauseMenu_Scene.new([2, 3, 0])
assert.call(scene.pbShowCommands(original) == 0, "original pause command index survives added trading routes")
assert.call(original == ["背包", "保存"], "caller command array remains unchanged")
assert.call(scene.shown.all? { |commands| commands == ["背包", "保存", "交易中心", "附近玩家"] }, "trading commands append without reordering originals")
assert.call(KIFMultiplayer.routes == [[:market, client], [:nearby]], "pause routes use the active world's actual client")
assert.call(scene.hide_count == 2 && scene.show_count == 2, "pause window restores after each route")
pc = PokemonPCList.pcs.first
assert.call(pc && pc.shouldShow? && pc.name == "全球交易市场", "registered PC entry appears in online mode")
pc.access
assert.call(KIFMultiplayer.routes.last == [:market, client], "PC route uses world client without an OnlineMode.client method")
KIFMultiplayer::OnlineMode.online = false
offline = PokemonPauseMenu_Scene.new([1])
assert.call(offline.pbShowCommands(original) == 1 && offline.shown == [original], "offline pause menu preserves original choices")
assert.call(!pc.shouldShow?, "offline PC menu hides online market")
load "Data/Scripts/054_Multiplayer/001_Client.rb"
module KIFMultiplayer
  def self.display_text(value); value.to_s; end
  class TradingClient
    def initialize(client); end
  end
end
load "Data/Scripts/054_Multiplayer/022_TradingUI.rb"
filter_ui = KIFMultiplayer::TradingUI.new(client)
actions = [12, 2, 14]
filter_ui.define_singleton_method(:choose) { |_title, _choices| actions.shift }
assert.call(filter_ui.filters_menu({})["gender"] == 1, "market gender selector sends the female enum rather than the menu index")
actions = [12, 4, 14]
assert.call(filter_ui.filters_menu({"gender" => 1})["gender"] == 1, "cancelled gender selection preserves the existing filter")
puts "TRADING_ENTRIES_TEST_PASS checks=#{checks} (routing contract, not device UI acceptance)"
