# frozen_string_literal: true
# Native presenters retain stock, prices, affordability, ownership and bag rules.
# The server only replaces windows and input collection.
def playOutfitChangeAnimation
  KIFNative.scene.events << {"kind" => "outfit_changed"}
end
def playOutfitRemovedAnimation; playOutfitChangeAnimation; end
class PokemonMart_Scene
  def pbStartBuyOrSellScene(buying, stock, adapter)
    @buying, @stock, @adapter = buying, stock, adapter
    pbUnlockEggs if $game_temp.fromkurayshop
  end
  def pbStartSellScene(bag, adapter)
    @buying, @adapter = false, adapter
  end
  def pbChooseBuyItem
    labels = @stock.map do |item|
      if @adapter.is_a?(OutfitsMartAdapter) && item.is_a?(Symbol)
        @adapter.getSpecialItemCaption(item)
      else
        "#{@adapter.getDisplayName(item)} #{@adapter.getDisplayPrice(item)}"
      end
    end
    selected = KIFNative.scene.pbShowCommands(@buying ? "Stock" : "Inventory", labels + ["Cancel"])
    return nil if selected < 0 || selected == @stock.length
    @stock.fetch(selected)
  end
  def pbChooseSellItem
    @stock = GameData::Item::DATA.values.uniq.select { |item| @adapter.getQuantity(item.id) > 0 }.map(&:id)
    pbChooseBuyItem
  end
  def pbChooseNumber(text, _item, maximum)
    KIFNative.scene.ask("number", {"text" => text, "minimum" => 0, "maximum" => maximum})
  end
  def pbDisplay(text, *); KIFNative.scene.pbDisplay(text); end
  def pbDisplayPaused(text, &block); KIFNative.scene.pbDisplayMessage(text, &block); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  %i[update pbRefresh pbShowMoney pbHideMoney pbEndBuyScene pbEndSellScene].each do |name|
    define_method(name) { nil }
  end
end

class ClothesShopView
  def pbStartBuyOrSellScene(buying, stock, adapter)
    @buying, @stock, @adapter = buying, stock, adapter
  end
  def pbChooseBuyItem
    loop do
      item = super
      return item unless item.is_a?(Symbol)
      @adapter.doSpecialItemAction(item)
    end
  end
  def pbEndBuyScene
    @adapter.reset_player_clothes
  end
  def pbRefresh; end
  def update; end
end
