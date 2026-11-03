module KIFMultiplayer
  # These projections implement the original tile renderer's read interface.
  # They never create an interpreter or execute local map events.
  class OriginalMapProjection
    attr_reader :map_id, :data, :width, :height, :tileset_name, :autotile_names, :priorities, :terrain_tags, :origin
    attr_accessor :display_x, :display_y
    def initialize(entry, tilesets)
      @map_id, @width, @height, @origin = entry.values_at("id", "width", "height", "origin")
      if entry["full"]
        @data = Table.new(@width, @height, entry["layers"])
      else
        source = load_data(sprintf("Data/Map%03d.rxdata", @map_id))
        raise Error, "地图资源版本不一致。" unless source.width == @width && source.height == @height && source.tileset_id == entry["tileset"]
        @base_data = source.data
        @data = Marshal.load(Marshal.dump(source.data))
      end
      tileset = tilesets[entry["tileset"]]
      raise Error, "地图图块资源缺失。" unless tileset
      @tileset_name, @autotile_names, @priorities, @terrain_tags = tileset.tileset_name, tileset.autotile_names, tileset.priorities, tileset.terrain_tags
      apply(entry)
    end
    def apply(entry)
      changed = @last_tiles != entry["tiles"] || @origin != entry["origin"]
      @origin = entry["origin"]
      return false unless changed
      if @base_data
        (@last_tiles || []).each do |index, _|
          z, offset = index.divmod(@width * @height)
          y, x = offset.divmod(@width)
          @data[x,y,z] = @base_data[x,y,z]
        end
      end
      entry["tiles"].each do |index, value|
        z, offset = index.divmod(@width * @height)
        y, x = offset.divmod(@width)
        @data[x,y,z] = value
      end
      @last_tiles = entry["tiles"]
      true
    end
  end
  class OriginalMapFactoryProjection
    attr_reader :maps
    def initialize(maps); @maps = maps; end
    def getRelativePos(first, x1, y1, second, x2, y2)
      a = @maps.find { |map| map.map_id == first }
      b = @maps.find { |map| map.map_id == second }
      return nil unless a && b
      [b.origin[0] - a.origin[0] + x2 - x1, b.origin[1] - a.origin[1] + y2 - y1]
    end
  end
  class OriginalWorldRenderer
    attr_reader :viewport
    def connection_status=(value)
      return if @connection_status == value
      @connection_status, @overlay_key = value, nil
    end
    def initialize
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 99990
      @sprites, @bitmaps, @pictures, @maps = {}, {}, {}, {}
      @tilesets = load_data("Data/Tilesets.rxdata")
      @overlay = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
      @overlay.z = 99999
    end
    def within_map
      previous_map, previous_factory = $game_map, $MapFactory
      previous_bridge = $PokemonGlobal.bridge
      $game_map, $MapFactory = @maps.fetch(@world["map_id"]), @factory
      $PokemonGlobal.bridge = @world["bridge"] || 0
      yield
    ensure
      $game_map, $MapFactory = previous_map, previous_factory
      $PokemonGlobal.bridge = previous_bridge
    end
    def adopt(view, character)
      world = view.fetch("world")
      changed_map = !@world || world["map_id"] != @world["map_id"]
      @world, @character = world, character
      ids = world["maps"].map { |entry| entry["id"] }
      @maps.delete_if { |id, _| !ids.include?(id) }
      world["maps"].each do |entry|
        if @maps[entry["id"]]
          @maps[entry["id"]].apply(entry)
        else
          @maps[entry["id"]] = OriginalMapProjection.new(entry, @tilesets)
        end
      end
      @factory = OriginalMapFactoryProjection.new(@maps.values)
      if changed_map
        @tilemap.dispose if @tilemap
        @tilemap = TilemapRenderer.new(@viewport)
        @loaded_tilesets, @loaded_autotiles = {}, {}
      end
      @maps.each_value do |map|
        unless @loaded_tilesets[map.tileset_name]
          @tilemap.add_tileset(map.tileset_name)
          @loaded_tilesets[map.tileset_name] = true
        end
        map.autotile_names.each do |name|
          next if name.empty? || @loaded_autotiles[name]
          @tilemap.add_autotile(name)
          @loaded_autotiles[name] = true
        end
      end
      @tilemap.refresh
      @tilemap.tone = Tone.new(*world.fetch("tone", [0,0,0,0]))
      trainer = view.fetch("trainer")
      appearance = {"skin_tone" => trainer["skin"], "clothes" => trainer["clothes"], "hair" => trainer["hair"], "hat" => trainer["hat"],
        "clothes_color" => trainer["clothes_color"], "hair_color" => trainer["hair_color"], "hat_color" => trainer["hat_color"]}
      player_key = WireJSON.dump(appearance)
      if @player_key != player_key
        @player_bitmap.dispose if @player_bitmap
        @player_bitmap = appearance["clothes"].is_a?(String) && !appearance["clothes"].empty? ? ShopVisual.bitmap(appearance) : nil
        @player_key = player_key
      end
      @player ||= Sprite.new(@viewport)
      @player.bitmap = @player_bitmap
      @player.visible = !world["transparent"] && !!@player_bitmap
      sync_quiz(view["quiz_picture"])
      if world["darkness_radius"]
        @darkness ||= DarknessSprite.new(@viewport)
        @darkness.radius = world["darkness_radius"] if @darkness.radius != world["darkness_radius"]
      elsif @darkness
        @darkness.dispose; @darkness = nil
      end
      sync_events
      sync_pictures
      update
    end
    def sync_quiz(quiz)
      key = quiz && [quiz["head"],quiz["body"],quiz["obscured"]]
      return if @quiz_key == key
      @quiz_key = key
      @quiz_sprite&.dispose
      @quiz_bitmap&.dispose
      @quiz_sprite = @quiz_bitmap = nil
      return unless quiz
      raise Error, "融合问答图片编号无效。" unless [quiz["head"],quiz["body"]].all? { |value| value.is_a?(Integer) && value.between?(1,Settings::NB_POKEMON) }
      head, body = quiz["head"], quiz["body"]
      paths = [Settings::CUSTOM_BATTLERS_FOLDER_INDEXED+"#{head}/#{head}.#{body}.png", Settings::BATTLERS_FOLDER+"#{head}/#{head}.#{body}.png", Settings::DEFAULT_SPRITE_PATH]
      path = paths.find { |candidate| pbResolveBitmap(candidate) }
      @quiz_bitmap = AnimatedBitmap.new(path).recognizeDims()
      @quiz_sprite = Sprite.new(@viewport)
      @quiz_sprite.bitmap = @quiz_bitmap.bitmap
      @quiz_sprite.x, @quiz_sprite.y, @quiz_sprite.z = 100,30,99990
      @quiz_sprite.color = Color.new(255,255,255,200) if quiz["obscured"]
    end
    def sync_events
      ids = @world["events"].map { |entry| entry["id"] }
      @sprites.keys.each do |id|
        next if ids.include?(id)
        @sprites.delete(id).dispose
        @bitmaps.delete(id)&.dispose
      end
      @world["events"].each do |entry|
        id = entry["id"]
        sprite = @sprites[id] ||= Sprite.new(@viewport)
        key = [entry["graphic"], entry["tile"], entry["hue"], entry["width"], entry["height"]]
        if sprite.instance_variable_get(:@original_asset_key) != key
          @bitmaps.delete(id)&.dispose
          bitmap = nil
          if entry["tile"] >= 384
            map = @maps.fetch(@world["map_id"])
            bitmap = pbGetTileBitmap(map.tileset_name, entry["tile"], entry["hue"] || 0, entry["width"], entry["height"])
          elsif !entry["graphic"].empty?
            bitmap = AnimatedBitmap.new("Graphics/Characters/" + entry["graphic"], entry["hue"] || 0)
          end
          @bitmaps[id] = bitmap if bitmap
          sprite.bitmap = bitmap.is_a?(AnimatedBitmap) ? bitmap.bitmap : bitmap
          sprite.instance_variable_set(:@original_asset_key, key)
        end
        sprite.visible = !entry["transparent"] && !!sprite.bitmap
        sprite.opacity = entry["opacity"] || 255
        sprite.blend_type = entry["blend_type"] || 0
      end
    end
    def sync_pictures
      ids = @world["pictures"].map { |entry| entry["id"] }
      @pictures.keys.each do |id|
        next if ids.include?(id)
        sprite, bitmap = @pictures.delete(id)
        sprite.dispose; bitmap.dispose
      end
      @world["pictures"].each do |entry|
        pair = @pictures[entry["id"]]
        if pair && pair[0].instance_variable_get(:@original_name) != entry["name"]
          pair.each(&:dispose); pair = nil
        end
        unless pair
          bitmap = AnimatedBitmap.new("Graphics/Pictures/" + entry["name"])
          sprite = Sprite.new(@viewport)
          sprite.bitmap = bitmap.bitmap
          sprite.instance_variable_set(:@original_name, entry["name"])
          pair = @pictures[entry["id"]] = [sprite, bitmap]
        end
        sprite = pair[0]
        sprite.x, sprite.y = entry.values_at("x", "y")
        sprite.z = 10000 + entry["id"]
        sprite.ox = entry["origin"] == 1 ? sprite.bitmap.width / 2 : 0
        sprite.oy = entry["origin"] == 1 ? sprite.bitmap.height / 2 : 0
        sprite.zoom_x, sprite.zoom_y = entry["zoom_x"] / 100.0, entry["zoom_y"] / 100.0
        sprite.opacity, sprite.blend_type, sprite.angle = entry.values_at("opacity", "blend_type", "angle")
        sprite.tone = Tone.new(*entry["tone"])
      end
    end
    def place(sprite, entry, tile = false)
      return unless sprite && sprite.bitmap
      width = tile ? sprite.bitmap.width : sprite.bitmap.width / 4
      height = tile ? sprite.bitmap.height : sprite.bitmap.height / 4
      pattern = tile ? 0 : (entry["pattern"] || (KIFMultiplayer.monotonic * 5).to_i % 4)
      sprite.src_rect.set(pattern * width, tile ? 0 : (entry["direction"] / 2 - 1) * height, width, height)
      sprite.ox, sprite.oy = width / 2, height
      sprite.x = entry["x"] * 32 + 16 - @world["camera"][0]
      sprite.y = entry["y"] * 32 + 32 - @world["camera"][1]
      sprite.z = sprite.y + 32
    end
    def update
      return unless @world
      camera_x, camera_y = @world["camera"]
      @maps.each_value do |map|
        map.display_x = (camera_x - map.origin[0] * 32) * Game_Map::X_SUBPIXELS
        map.display_y = (camera_y - map.origin[1] * 32) * Game_Map::Y_SUBPIXELS
      end
      within_map { @tilemap.update }
      @bitmaps.each_value { |bitmap| bitmap.update if bitmap.is_a?(AnimatedBitmap) }
      @world["events"].each { |entry| place(@sprites[entry["id"]], entry, entry["tile"] >= 384) }
      place(@player, @world)
      @pictures.each_value { |_, bitmap| bitmap.update }
      key = [@character["revision"], @world["map_id"]]
      return if @overlay_key == key
      @overlay_key = key
      @overlay.bitmap.clear
      @overlay.bitmap.fill_rect(0, 0, Graphics.width, 28, Color.new(0,0,0,175))
      @overlay.bitmap.font.name = "Noto Sans SC" if Font.exist?("Noto Sans SC")
      @overlay.bitmap.font.size = 16
      @overlay.bitmap.font.color = Color.new(255,255,255)
      @overlay.bitmap.draw_text(8,0,Graphics.width-16,28, KIFMultiplayer.display_text(@world["name"]) + " · GOLD #{@character['wallet']['balance']}#{@connection_status ? ' · '+@connection_status : ''}")
    end
    def visible=(value); @viewport.visible = value; end
    def dispose
      @tilemap.dispose if @tilemap
      @sprites.each_value(&:dispose)
      @bitmaps.each_value(&:dispose)
      @pictures.each_value { |pair| pair.each(&:dispose) }
      @player.dispose if @player
      @player_bitmap.dispose if @player_bitmap
      @overlay.dispose if @overlay
      @quiz_sprite&.dispose
      @quiz_bitmap&.dispose
      @darkness.dispose if @darkness
      @viewport.dispose if @viewport
    end
  end
end
