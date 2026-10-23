unless ENV["KIF_SERVER_ENGINE"] == "1"
  module KIFMultiplayer
    module Mainline
      class << self
        def character_id
          defined?($Trainer) && $Trainer && $Trainer.instance_variable_get(:@kif_mainline_character_id)
        end
        def active?
          !Thread.current[:kif_mainline_casual_browse] && defined?(OnlineMode) && OnlineMode.active? && character_id.is_a?(String) && OnlineMode.world &&
            $Trainer.instance_variable_get(:@kif_mainline_owner_id) == OnlineMode.world.client.player_id
        end
        def projecting?; !!Thread.current[:kif_mainline_projection]; end
        def synchronizing?; !!@refreshing; end
        def with_projection
          previous = Thread.current[:kif_mainline_projection]
          Thread.current[:kif_mainline_projection] = true
          yield
        ensure
          Thread.current[:kif_mainline_projection] = previous
        end
        def asset_id(pokemon)
          pokemon && pokemon.instance_variable_get(:@kif_mainline_asset_id)
        end
        def item_id(item)
          value=item.respond_to?(:id) ? item.id : item
          return nil unless GameData::Item::DATA.key?(value) || value.is_a?(String) && GameData::Item::DATA.key?(value.to_sym)
          GameData::Item.get(value).id.to_s
        end
        def approved_item?(item)
          id=item_id(item)
          id && ($Trainer.instance_variable_get(:@kif_mainline_catalog_ids) || []).include?(id)
        end
        def use_item(item,pokemon,scene=nil)
          id=item_id(item);asset=asset_id(pokemon)
          raise Error,"请使用联机库存中可用的道具。" unless id && asset && approved_item?(item)
          params={"item_id"=>id};operation="use_item"
          vitamins={"HPUP"=>"HP","PROTEIN"=>"ATTACK","IRON"=>"DEFENSE","CALCIUM"=>"SPECIAL_ATTACK","ZINC"=>"SPECIAL_DEFENSE","CARBOS"=>"SPEED"}
          if id=="RARECANDY"
            operation="train";params={"count"=>1}
          elsif vitamins[id]
            operation="ev";params={"stat"=>vitamins[id],"count"=>1}
          elsif GameData::Item.get(id).is_evolution_stone?
            operation="evolve";params={"method"=>"item","item_id"=>id}
            preview=sdk.operate(character_id,"preview_evolution",[asset],params)
            return false unless pbConfirmMessage("进化为 #{KIFMultiplayer.display_text(preview['result']['preview']['species'])} 并消耗所选道具？")
          end
          KIFMultiplayer.with_trading_scene(true) { sdk.operate(character_id,operation,[asset],params) }
          refresh
          scene.pbHardRefresh if scene && scene.respond_to?(:pbHardRefresh)
          true
        rescue Error=>error
          pbMessage(KIFMultiplayer.display_text(error.message));false
        end
        def client; OnlineMode.world.client; end
        def canonical_system
          @canonical_system ||= PokemonSystem.new
        end
        def casual_storage
          originals=[$Trainer.party,$PokemonBag,$Trainer.money]
          previous=Thread.current[:kif_mainline_casual_browse]
          Thread.current[:kif_mainline_casual_browse]=true
          $Trainer.party=$Trainer.instance_variable_get(:@kif_mainline_casual_party) || []
          $PokemonBag=BattleIsolation.copy(originals[1])
          ($Trainer.instance_variable_get(:@kif_mainline_catalog_ids) || []).each do |id|
            count=$PokemonBag.pbQuantity(id.to_sym)
            $PokemonBag.pbDeleteItem(id.to_sym,count) if count>0
          end
          ($Trainer.instance_variable_get(:@kif_mainline_casual_items) || {}).each { |id,quantity| $PokemonBag.pbStoreItem(id.to_sym,quantity) }
          $Trainer.instance_variable_set(:@money,$Trainer.instance_variable_get(:@kif_mainline_casual_money) || 0)
          yield
        ensure
          if originals
            $Trainer.instance_variable_set(:@kif_mainline_casual_party,$Trainer.party)
            ids=$Trainer.instance_variable_get(:@kif_mainline_catalog_ids) || []
            $Trainer.instance_variable_set(:@kif_mainline_casual_items,ids.each_with_object({}) { |id,values| count=$PokemonBag.pbQuantity(id.to_sym);values[id]=count if count>0 })
            $Trainer.instance_variable_set(:@kif_mainline_casual_money,$Trainer.money)
            casual_bag=$PokemonBag
            $Trainer.party,$PokemonBag=originals[0,2]
            $PokemonBag.pockets.flatten(1).dup.each do |entry|
              next unless entry.is_a?(Array) && entry.length==2
              $PokemonBag.pbDeleteItem(entry[0],entry[1]) unless ids.include?(entry[0].to_s)
            end
            casual_bag.pockets.flatten(1).each do |entry|
              next unless entry.is_a?(Array) && entry.length==2
              $PokemonBag.pbStoreItem(entry[0],entry[1]) unless ids.include?(entry[0].to_s)
            end
            $Trainer.instance_variable_set(:@money,originals[2])
          end
          Thread.current[:kif_mainline_casual_browse]=previous
        end
        def sdk; MainlineClient.new(client); end
        def safe?
          active? && !projecting? && $game_temp && !$game_temp.in_battle && !$game_temp.player_transferring && !pbMapInterpreterRunning?
        end
        def import(full)
          BattleIsolation.with { TradeCodec.import(full) }
        end
        def apply(character, inventory)
          raise Error, "角色身份与当前存档不一致。" unless character["id"] == character_id && character["owner_id"] == client.player_id
          TradingClient.new(client).validate_inventory(inventory)
          version = [character["revision"], character["wallet"]["version"], inventory["version"]]
          previous = $Trainer.instance_variable_get(:@kif_mainline_sync_version)
          if previous && previous["character_id"] == character_id && previous["epoch"] == character["authority_epoch"]
            return if version.each_with_index.any? { |value, index| value < previous["version"][index] }
          end
          with_projection do
            existing = {}
            $Trainer.party.each { |pokemon| existing[asset_id(pokemon)] = pokemon if asset_id(pokemon) }
            casual = $Trainer.instance_variable_get(:@kif_mainline_casual_party) || []
            $Trainer.party.each { |pokemon| casual << pokemon unless asset_id(pokemon) || casual.any? { |entry| entry.equal?(pokemon) } }
            $Trainer.instance_variable_set(:@kif_mainline_casual_party, casual)
            party = character["party"].map do |asset|
              fresh = import(asset["full"])
              target = existing[asset["id"]] || fresh
              if target != fresh
                target.instance_variables.each { |key| target.remove_instance_variable(key) }
                fresh.instance_variables.each { |key| target.instance_variable_set(key, fresh.instance_variable_get(key)) }
              end
              target.instance_variable_set(:@kif_mainline_asset_id, asset["id"])
              target.instance_variable_set(:@kif_mainline_asset_version, asset["version"] || 1)
              target
            end
            $Trainer.party = party
            $Trainer.instance_variable_set(:@money, character["wallet"]["available"])
            $Trainer.instance_variable_set(:@kif_mainline_revision, character["revision"])
            $Trainer.instance_variable_set(:@kif_mainline_catalog_ids, ((inventory["catalog_ids"] || []) + inventory["items"].map { |entry| entry["item_id"] }).uniq)
            projected = $Trainer.instance_variable_get(:@kif_mainline_projected_items) || {}
            casual_items = $Trainer.instance_variable_get(:@kif_mainline_casual_items) || {}
            ids = ((inventory["catalog_ids"] || []) + projected.keys + inventory["items"].map { |entry| entry["item_id"] }).uniq
            ids.each do |id|
              current = $PokemonBag.pbQuantity(id.to_sym)
              difference = current - projected.fetch(id, 0)
              casual_items[id] = casual_items.fetch(id, 0) + difference if difference > 0
              $PokemonBag.pbDeleteItem(id.to_sym, current) if current > 0
            end
            inventory["items"].each { |entry| $PokemonBag.pbStoreItem(entry["item_id"].to_sym, [entry["available"], 999].min) if entry["available"] > 0 }
            $Trainer.instance_variable_set(:@kif_mainline_casual_items, casual_items)
            $Trainer.instance_variable_set(:@kif_mainline_projected_items, inventory["items"].each_with_object({}) { |entry, hash| hash[entry["item_id"]] = [entry["available"], 999].min })
            $Trainer.instance_variable_set(:@kif_mainline_sync_version, {"character_id" => character_id, "epoch" => character["authority_epoch"], "version" => version})
          end
        end
        def refresh
          return unless active?
          return if @refreshing
          acquired_refresh=@refreshing=true
          @io.cancel if @io
          @pending=nil
          KIFMultiplayer.with_trading_scene(true) do
            snapshot=sdk.sync(character_id)
            apply(snapshot['character'],snapshot['inventory'])
          end
        ensure
          @refreshing=false if acquired_refresh
        end
        def invalidate_loaded_projection
          with_projection do
            $Trainer.party=[]
            $Trainer.instance_variable_set(:@money,0)
            projected=$Trainer.instance_variable_get(:@kif_mainline_projected_items) || {}
            ids=(($Trainer.instance_variable_get(:@kif_mainline_catalog_ids) || [])+projected.keys).uniq
            ids.each do |id|
              count=$PokemonBag.pbQuantity(id.to_sym)
              $PokemonBag.pbDeleteItem(id.to_sym,count) if count>0
            end
            $Trainer.instance_variable_set(:@kif_mainline_projected_items,{})
            $Trainer.instance_variable_set(:@kif_mainline_sync_version,nil)
          end
        end
        def tick
          return if @ticking || @refreshing
          acquired_tick=@ticking=true
          unless active?
            @io.cancel if @io
            @io, @pending, @binding = nil, nil, nil
            return
          end
          binding = [client.server, client.player_id, character_id]
          if @binding != binding
            @io.cancel if @io
            @io, @pending, @next_poll, @binding = AsyncRequest.new(client), nil, 0, binding
          end
          if @io.pending? && !@io.busy?
            value = @io.take
            @pending = [sdk.validate_character(value["character"]), value["inventory"]]
          end
          if @pending && safe?
            apply(*@pending)
            @pending = nil
          end
          return if @io.pending? || @pending || KIFMultiplayer.monotonic < @next_poll || !safe?
          @io.start("/v1/mainline/characters/#{character_id}/sync", {"compatibility" => client.compatibility})
          @next_poll = KIFMultiplayer.monotonic + 2
        rescue Error => error
          KIFMultiplayer.log_error(error)
          @next_poll = KIFMultiplayer.monotonic + 5
        ensure
          @ticking=false if acquired_tick
        end
        def mount(selected_client, character)
          raise Error, "请在安全地图从暂停菜单进入角色。" unless OnlineMode.active? && !$game_temp.in_battle && !$game_temp.player_transferring && !pbMapInterpreterRunning?
          if character_id == character["id"]
            refresh
            return
          end
          raise Error, "请先为角色选择至少一只队伍精灵。" if character["party"].empty?
          old_slot = $Trainer.save_slot || SaveData::MANUAL_SLOTS.first
          slots = SaveData::MANUAL_SLOTS.reject { |slot| slot==old_slot || OnlineMode.cloud.available?(slot) || File.file?(SaveData.get_full_path(slot)) }
          raise Error, "在线手动槽位已满，请先整理角色槽。" if slots.empty?
          return unless pbConfirmMessage("进入 #{KIFMultiplayer.display_text(character['name'])}？\n当前角色保留在 #{old_slot}，托管角色使用独立槽 #{slots.first}。")
          $Trainer.save_slot = old_slot
          TradeSave.new.persist
          OnlineMode.cloud.queue_save(old_slot, SaveData.compile_save_hash)
          raise Error, "请先同步当前角色，再建立独立槽。" unless OnlineMode.cloud.flush
          originals = [$Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables, $PokemonStorage]
          committed = false
          begin
            with_projection do
            copies = BattleIsolation.copy(originals)
            $Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables, $PokemonStorage = copies
            $Trainer.save_slot = slots.first
            $Trainer.name = character["name"]
            $Trainer.instance_variable_set(:@kif_mainline_character_id, character["id"])
            $Trainer.instance_variable_set(:@kif_mainline_owner_id, selected_client.player_id)
            $Trainer.instance_variable_set(:@kif_mainline_casual_party, $Trainer.party.dup)
            $Trainer.instance_variable_set(:@kif_mainline_casual_money,$Trainer.money)
            $Trainer.party = []
            apply(character, TradingClient.new(selected_client).inventory)
            TradeSave.new.persist
            committed = true
            OnlineMode.cloud.queue_save(slots.first, SaveData.compile_save_hash)
            LocalJournal.change(selected_client.profile) { (selected_client.profile.account["mainline_slots"] ||= {})[character["id"]] = slots.first }
            end
            pbMessage("托管角色已建立在独立槽，队伍与联机库存已连接。")
          ensure
            $Trainer, $PokemonBag, $PokemonGlobal, $PokemonSystem, $game_switches, $game_variables, $PokemonStorage = originals unless committed
          end
        end
      end
    end

    module MainlineGraphics
      def update(*args)
        value = super
        Mainline.tick
        value
      end
    end
    module MainlineCloudSaveBarrier
      def safe_to_save?(*args)
        return false if Mainline.projecting? || Mainline.synchronizing?
        super
      end
    end
    module MainlineGameLoad
      def load(*args)
        value = super
        if Mainline.active?
          Mainline.invalidate_loaded_projection
          Mainline.refresh
        end
        value
      end
    end
    module MainlineMoneyGuard
      def money=(value)
        return super unless Mainline.active? && !Mainline.projecting?
        @money
      end
      def heal_party
        return super unless Mainline.active? && !Mainline.projecting? && equal?($Trainer)
        ids=Mainline.sdk.character(Mainline.character_id)['party'].map { |asset| asset['id'] }
        return if ids.empty?
        KIFMultiplayer.with_trading_scene(true) { Mainline.sdk.operate(Mainline.character_id,'heal',ids) }
        Mainline.refresh
      end
    end
    module MainlineBagGuard
      def pbStoreItem(item,qty=1)
        return super unless Mainline.active? && !Mainline.projecting? && equal?($PokemonBag) && Mainline.approved_item?(item)
        id=Mainline.item_id(item)
        values=$Trainer.instance_variable_get(:@kif_mainline_casual_items) || {}
        values[id]=values.fetch(id,0)+qty
        $Trainer.instance_variable_set(:@kif_mainline_casual_items,values)
        true
      end
      def pbDeleteItem(item,qty=1)
        return super unless Mainline.active? && !Mainline.projecting? && equal?($PokemonBag) && Mainline.approved_item?(item)
        id=Mainline.item_id(item)
        Mainline.client.request("POST","/v1/mainline/inventory/consume",{"item_id"=>id,"quantity"=>qty})
        Mainline.refresh
        true
      rescue Error=>error
        KIFMultiplayer.log_error(error)
        false
      end
    end
    module MainlineItemHooks
      def pbUseItemOnPokemon(item,pokemon,scene)
        return super unless Mainline.active? && Mainline.asset_id(pokemon) && !Mainline.projecting?
        Mainline.use_item(item,pokemon,scene)
      end
      def pbUseItem(bag,item,bagscene=nil)
        return super unless Mainline.active? && !Mainline.projecting? && GameData::Item.get(item).field_use==1
        party=$Trainer.party
        selected=UI.new(Mainline.client).choose("使用在谁身上？",party.map { |pokemon| KIFMultiplayer.display_text(pokemon.name) }+["返回"])
        return 0 if selected<0 || selected>=party.length
        Mainline.use_item(item,party[selected],bagscene) ? 1 : 0
      end
      def pbGiveItemToPokemon(item,pokemon,scene,pkmnid=0)
        return super unless Mainline.active? && Mainline.asset_id(pokemon) && !Mainline.projecting?
        Mainline.sdk.operate(Mainline.character_id,"equip",[Mainline.asset_id(pokemon)],{"item_id"=>Mainline.item_id(item)})
        Mainline.refresh;true
      end
      def pbTakeItemFromPokemon(pokemon,scene)
        return super unless Mainline.active? && Mainline.asset_id(pokemon) && !Mainline.projecting?
        Mainline.sdk.operate(Mainline.character_id,"equip",[Mainline.asset_id(pokemon)],{"item_id"=>nil})
        Mainline.refresh;true
      end
      def pbPokemonMart(stock,speech=nil,cantsell=false)
        return super unless Mainline.active? && !Mainline.projecting?
        KIFMultiplayer.with_trading_scene { MainlineUI.new(Mainline.client).shop }
      end
      def pbPCItemStorage(*args)
        return super unless Mainline.active?
        pbMessage("联机道具保存在账号库存中。休闲 PC 道具取出后仍保留休闲来源。")
        Mainline.casual_storage { super }
      end
    end
    module MainlineStorageHook
      def access
        return super unless Mainline.active?
        selected=UI.new(Mainline.client).choose("精灵存储",["联机队伍与 PC","休闲精灵存储","返回"])
        if selected==0
          KIFMultiplayer.with_trading_scene { MainlineUI.new(Mainline.client).party(Mainline.sdk.character(Mainline.character_id)) }
          Mainline.refresh
        elsif selected==1
          Mainline.casual_storage { super }
        end
      end
    end
    module MainlineSystemRules
    end
    if defined?(PokemonSystem)
      PokemonSystem.new.instance_variables.each do |field|
        name=field.to_s.delete_prefix("@").to_sym
        next if BattleIsolation::PRESENTATION.include?(name) || !PokemonSystem.method_defined?(name)
        original_getter=PokemonSystem.instance_method(name)
        MainlineSystemRules.define_method(name) do
          Mainline.active? ? original_getter.bind(Mainline.canonical_system).call : super()
        end
      end
    end
  end
  Graphics.singleton_class.prepend(KIFMultiplayer::MainlineGraphics) if defined?(Graphics)
  KIFMultiplayer::OnlineMode.singleton_class.prepend(KIFMultiplayer::MainlineCloudSaveBarrier)
  Game.singleton_class.prepend(KIFMultiplayer::MainlineGameLoad) if defined?(Game)
  Player.prepend(KIFMultiplayer::MainlineMoneyGuard) if defined?(Player)
  PokemonBag.prepend(KIFMultiplayer::MainlineBagGuard) if defined?(PokemonBag)
  PokemonSystem.prepend(KIFMultiplayer::MainlineSystemRules) if defined?(PokemonSystem)
  StorageSystemPC.prepend(KIFMultiplayer::MainlineStorageHook) if defined?(StorageSystemPC)
  Object.prepend(KIFMultiplayer::MainlineItemHooks)
end
