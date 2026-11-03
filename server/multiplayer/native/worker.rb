# frozen_string_literal: true
# Private RPC worker. It has no listener and reads no player saves.
protocol_output = $stdout
protocol_output.binmode
$stdin.binmode
$stdout = $stderr # native diagnostics cannot corrupt the JSON response
require_relative "world"
require_relative "migration"
require_relative "commerce"
require_relative "rollback"
KIFNative.capture_global_baseline
rules_hash = KIFNative.source_hash
item_catalog = GameData::Item::DATA.values.uniq.map { |item| {"id" => item.id, "name" => item.name,
  "price" => item.price, "pocket" => item.pocket, "important" => item.is_important?} }
loop_mode = ARGV.include?("--stdio-loop")
loop do
begin
  raw = loop_mode ? $stdin.gets(KIFNative::STATE_LIMIT * 2 + 1) : $stdin.read(KIFNative::STATE_LIMIT * 2 + 1)
  break if raw.nil? || raw.empty?
  raise ArgumentError, "native_request_limit" if raw.bytesize > KIFNative::STATE_LIMIT * 2
  KIFNative.reset_global_baseline
  request = JSON.parse(raw)
  raise ArgumentError, "native_protocol_version" unless request.fetch("protocol") == 1
  if request["rules_hash"] && request["rules_hash"] != rules_hash
    raise ArgumentError, "native_rules_changed"
  end
  operation = request.fetch("operation")
  result = case operation
           when "catalog"
             {"moves" => GameData::Move::DATA.values.uniq.map { |move| {"id" => move.id, "name" => move.real_name, "function" => move.function_code} },
              "abilities" => GameData::Ability::DATA.values.uniq.length,
              "items" => GameData::Item::DATA.values.uniq.length, "item_catalog" => item_catalog,
              "species" => GameData::Species::DATA.values.uniq.length,
              "evolution_methods" => GameData::Evolution::DATA.length,
              "trainers" => GameData::Trainer::DATA.values.uniq.length}
           when "create"
             KIFNative.reset(time: request.fetch("time"), seed: request.fetch("seed"))
             species = request.fetch("starter")
             raise ArgumentError, "invalid_starter" unless %w[BULBASAUR CHARMANDER SQUIRTLE].include?(species)
             $Trainer.name = request.fetch("name").gsub(/[\\\p{Cc}\p{Cf}]/, "")
             $Trainer.money = request.fetch("money")
             KIFNative.begin_identities(request.fetch("seed"))
             $Trainer.party = [Pokemon.new(species.to_sym, 5)]
             KIFNative.identify
             {"state" => KIFNative.export_state, "view" => KIFNative.view}
           when "world_create", "world_migrate"
             KIFNative.reset(time: request.fetch("time"), seed: request.fetch("seed"))
             KIFNative.initialize_world
             $Trainer.name = request.fetch("name").gsub(/[\\\p{Cc}\p{Cf}]/, "")
             $Trainer.money = request.fetch("money")
             if operation == "world_migrate"
               KIFNative.begin_identities(request.fetch("seed"))
               KIFNative.migrate_managed_v1(request).merge("item_catalog" => item_catalog)
             else
               {"state" => KIFNative.export_state, "view" => KIFNative.world_view, "item_catalog" => item_catalog}
             end
           when "inventory_adjust"
             KIFNative.import_state(request.fetch("state"))
             KIFNative.clock = request.fetch("time")
             KIFNative.wallet_baseline(request)
             item = request.fetch("item").to_sym
             raise ArgumentError, "unknown_native_item" unless GameData::Item::DATA.key?(item)
             amount = request.fetch("amount")
             raise ArgumentError, "native_inventory_amount" unless amount.is_a?(Integer) && amount != 0 && amount.abs <= 999
             if amount > 0
               raise ArgumentError, "native_inventory_capacity" unless $PokemonBag.pbStoreItem(item, amount)
             else
               raise ArgumentError, "native_inventory_quantity" unless $PokemonBag.pbQuantity(item) >= -amount && $PokemonBag.pbDeleteItem(item, -amount)
             end
             {"state" => KIFNative.export_state, "view" => KIFNative.world_view}
           when "world_step"
             raise ArgumentError, "native_history_limit" unless request.fetch("world").fetch("inputs").length <= 8192
             KIFNative.world_step(request.fetch("world"))
           when "view"
             KIFNative.import_state(request.fetch("state"))
             {"view" => KIFNative.view}
           when "battle"
             raise ArgumentError, "native_history_limit" unless request.fetch("battle").fetch("inputs").length <= 8192
             KIFNative.battle(request.fetch("battle"))
           when "cultivate"
             raise ArgumentError, "native_history_limit" unless request.fetch("cultivation").fetch("inputs").length <= 8192
             KIFNative.cultivate(request.fetch("cultivation"))
           when "asset_exchange"
             KIFNative.asset_exchange(request.fetch("exchange"))
           when "trade_finish"
             KIFNative.trade_finish(request.fetch("trade"))
           when "rollback"
             KIFNative.rollback(request.fetch("restore"))
           else
             raise ArgumentError, "unknown_native_operation"
           end
  protocol_output.puts(JSON.generate({"ok" => true, "protocol" => 1, "rules_hash" => rules_hash, "result" => result}))
  protocol_output.flush
rescue StandardError => error
  warn "#{error.class}: #{error.message}\n#{error.backtrace.first(8).join("\n") }"
  protocol_output.puts(JSON.generate({"ok" => false, "protocol" => 1, "error" => error.class.name, "message" => error.message}))
  protocol_output.flush
  exit 1 unless loop_mode
end
break unless loop_mode
end
