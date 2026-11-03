module KIFMultiplayer
  module ShopWorldPosition
    def position
      result = super
      result["appearance"] = ShopState.base if result && ShopState.current?
      result
    end
    def validate_world(world)
      super
      world["players"].each do |player|
        next unless player["appearance"]
        begin
          ShopData.appearance(player["appearance"])
        rescue Error
          # A different/missing resource version uses the established base avatar.
          player.delete("appearance")
        end
      end
      world
    end
  end
  WorldSession.prepend(ShopWorldPosition)

  if defined?(RemoteCharacter)
    module ShopRemoteCharacter
      attr_reader :shop_appearance
      def adopt(player)
        super
        @shop_appearance = player["appearance"]
      end
    end
    RemoteCharacter.prepend(ShopRemoteCharacter)
    module ShopRemoteSprite
      def refresh
        @shop_bitmap.dispose if @shop_bitmap
        @shop_bitmap = nil
        super
        appearance = @character.shop_appearance
        if appearance
          @shop_bitmap = ShopVisual.bitmap(appearance)
          @shop_key = WireJSON.dump(appearance)
        else
          @shop_key = nil
        end
      rescue Error, StandardError => error
        @shop_key = @character.shop_appearance && WireJSON.dump(@character.shop_appearance)
        KIFMultiplayer.log_error(error)
      end
      def update
        appearance = @character.shop_appearance
        key = appearance && WireJSON.dump(appearance)
        refresh if key != @shop_key
        super
        if @shop_bitmap
          self.bitmap = @shop_bitmap
          width, height = bitmap.width / 4, bitmap.height / 4
          self.src_rect.set(@character.pattern * width, (@character.direction / 2 - 1) * height, width, height)
          self.ox, self.oy = width / 2, height
        end
      end
      def dispose
        @shop_bitmap.dispose if @shop_bitmap
        @shop_bitmap = nil
        super
      end
    end
    RemoteSprite.prepend(ShopRemoteSprite)
  end

  class ShopCardFrame
    def initialize(decoration)
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 99997
      @canvas = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      bitmap = @canvas.bitmap
      frame = decoration["frame"]
      if frame
        color = Color.new(*frame["color"])
        x, y, width, height = Graphics.width / 2 - 72, 35, 144, Graphics.height / 2 - 29
        bitmap.fill_rect(x, y, width, 3, color)
        bitmap.fill_rect(x, y + height, width, 3, color)
        bitmap.fill_rect(x, y, 3, height, color)
        bitmap.fill_rect(x + width - 3, y, 3, height, color)
      end
      title = decoration["title"]
      if title
        bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
        bitmap.font.size = 18
        bitmap.font.color = Color.new(*title["color"])
        bitmap.draw_text(0, 8, Graphics.width, 27, title["name"], 1)
      end
    end
    def dispose
      @canvas.dispose if @canvas
      @viewport.dispose if @viewport
    end
  end
  module ShopCardDisplay
    def show_card(card)
      decoration = card["decoration"] || {}
      local = ShopData.local["entitlements"].values
      raise Error, "名片装饰资源无效。" unless decoration.is_a?(Hash) && (decoration.keys - %w[frame title]).empty? && decoration.values.all? { |value| local.include?(value) }
      frame = ShopCardFrame.new(decoration) unless decoration.empty?
      super
    ensure
      frame.dispose if frame
    end
  end
  CardUI.prepend(ShopCardDisplay) if defined?(CardUI)
end
