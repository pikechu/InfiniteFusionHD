# Fixed installed code for the server's native engine. No remote Ruby, Marshal
# object graph, class name or file path is executed or deserialized.
job_directory = File.expand_path(ENV.fetch("KIF_ENGINE_JOB_DIR"))
raise "Dedicated native job directory required" unless File.directory?(job_directory) && ENV["KIF_SERVER_ENGINE"] == "1"
System.define_singleton_method(:data_directory) { File.join(job_directory, "cache") + "/" }
require "digest/sha2"
secret = File.binread(ENV.fetch("KIF_ENGINE_SECRET_FILE"))
raise "Invalid native signing key" unless secret.bytesize == 32
loader = lambda do |path|
  names = Dir.entries(path).reject { |name| name == "." || name == ".." }
  files, directories = names.partition { |name| !File.directory?(File.join(path, name)) }
  files.sort.each { |name| load File.join(path, name) }
  directories.sort.each do |name|
    next if path == "Data/Scripts" && name == "999_Main"
    loader.call(File.join(path, name))
  end
end
loader.call("Data/Scripts")
# Server work must fail closed on an engine error. The interactive game's
# exception dialog waits for keyboard input and is unsuitable for a worker.
module PBDebug
  def self.logonerr
    yield
  end
end
module KIFServerEngine
  # KIF replaces several classic trade evolutions with level/item alternatives.
  # Enable their trade trigger only when the target is also in installed data.
  TRADE_ALTERNATIVES={"KADABRA"=>["ALAKAZAM",nil],"MACHOKE"=>["MACHAMP",nil],"GRAVELER"=>["GOLEM",nil],"HAUNTER"=>["GENGAR",nil],"POLIWHIRL"=>["POLITOED","KINGSROCK"],"SLOWPOKE"=>["SLOWKING","KINGSROCK"],"ONIX"=>["STEELIX","METALCOAT"],"SCYTHER"=>["SCIZOR","METALCOAT"],"SEADRA"=>["KINGDRA","DRAGONSCALE"],"PORYGON"=>["PORYGON2","UPGRADE"],"PORYGON2"=>["PORYGONZ","DUBIOUSDISC"],"FEEBAS"=>["MILOTIC","PRISMSCALE"],"RHYDON"=>["RHYPERIOR","PROTECTOR"],"ELECTABUZZ"=>["ELECTIVIRE","ELECTIRIZER"],"MAGMAR"=>["MAGMORTAR","MAGMARIZER"],"DUSCLOPS"=>["DUSKNOIR","REAPERCLOTH"],"BOLDORE"=>["GIGALITH",nil],"GURDURR"=>["CONKELDURR",nil],"PHANTUMP"=>["TREVENANT",nil],"PUMPKABOO"=>["GOURGEIST",nil]}.freeze
  class << self
    attr_accessor :secret, :request, :directory
    def canonical(value)
      ordered = lambda do |item|
        case item
        when Hash then item.keys.sort.each_with_object({}) { |key, hash| hash[key] = ordered.call(item[key]) }
        when Array then item.map { |entry| ordered.call(entry) }
        else item
        end
      end
      KIFMultiplayer::WireJSON.dump(ordered.call(value))
    end
    def hmac(value)
      key = @secret + "\0" * (64 - @secret.bytesize)
      inner = key.bytes.map { |byte| byte ^ 0x36 }.pack("C*")
      outer = key.bytes.map { |byte| byte ^ 0x5c }.pack("C*")
      Digest::SHA256.hexdigest(outer + Digest::SHA256.digest(inner + canonical(value).b))
    end
    def verified(document)
      raise "Invalid signed request" unless document.is_a?(Hash) && document.keys.sort == %w[payload signature] && document["signature"].is_a?(String)
      expected, actual = hmac(document["payload"]), document["signature"]
      raise "Invalid request signature" unless expected.bytesize == actual.bytesize && expected.bytes.zip(actual.bytes).inject(0) { |difference, pair| difference | (pair[0] ^ pair[1]) } == 0
      document["payload"]
    end
    def write(name, payload)
      value = {"payload" => payload, "signature" => hmac(payload)}
      path = File.join(@directory, name)
      File.open(path + ".pending", "wb") { |file| file.write(canonical(value)); file.flush; file.fsync }
      File.rename(path + ".pending", path)
    end
    def check(value, message); raise message unless value; end
    def bounded(value, low, high)
      check(value.is_a?(Integer) && value.between?(low, high), "Integer out of range")
      value
    end
    def import(value)
      if value.is_a?(Hash) && value["preserved"]
        KIFMultiplayer::TradeCodec.import(value)
      else
        KIFMultiplayer::Snapshot.validate(value)
        pokemon = KIFMultiplayer::Snapshot.import(value, value["level"])
        value["moves"].each_with_index { |move, index| pokemon.moves[index].pp = move["pp"] }
        pokemon
      end
    end
    def export(pokemon)
      # Standard appearance is stored by validated IDs/parameters, never by a
      # machine-local path selected by a sprite downloader during construction.
      pokemon.instance_variable_set(:@kuraycustomfile, nil)
      pokemon.instance_variable_set(:@oldkuraycustomfile, nil)
      KIFMultiplayer::TradeCodec.export(pokemon)
    end
    def snapshot(pokemon); export(pokemon)["pokemon"]; end
    def registered(type, value)
      check(value.is_a?(String) && value =~ /\A[A-Za-z0-9_]{1,80}\z/, "Invalid game identifier")
      klass = GameData.const_get(type)
      if type==:Species && value =~ /\AB(\d+)H(\d+)\z/
        check([$1.to_i,$2.to_i].all? { |number| number.between?(1,NB_POKEMON) && klass::DATA.key?(number) },'Unknown fusion component')
        return value.to_sym
      end
      check(klass::DATA.key?(value.to_sym), "Unknown game identifier")
      value.to_sym
    end
    def evolve(pokemon, params, other = nil)
      mode = params.fetch("method", "level")
      item = registered(:Item, params["item_id"]) if mode == "item"
      checker = lambda do |species = nil|
        target=pokemon.check_evolution_internal(species) do |pkmn, new_species, method, parameter|
          evolution = GameData::Evolution.get(method)
          success = case mode
                    when "level" then evolution.call_level_up(pkmn, parameter)
                    when "item" then evolution.call_use_item(pkmn, parameter, item)
                    when "trade" then evolution.call_on_trade(pkmn, parameter, other)
                    else raise "Unknown evolution method"
                    end
          success ? new_species : nil
        end
        if !target && mode=="trade" && !pokemon.hasItem?(:EVERSTONE)
          data=species || pokemon.species_data
          alternative=TRADE_ALTERNATIVES[data.id.to_s]
          if alternative && (!alternative[1] || pokemon.item_id.to_s==alternative[1]) && data.get_evolutions(true).any? { |entry| entry[0].to_s==alternative[0] }
            target=alternative[0].to_sym
            pokemon.item=nil if alternative[1]
          end
        end
        target
      end
      if pokemon.species.to_s =~ /\AB(\d+)H(\d+)\z/
        data = pokemon.species_data
        body, head = checker.call(data.body_pokemon), checker.call(data.head_pokemon)
        branch = params.fetch("branch", "both")
        body = nil if branch == "head"
        head = nil if branch == "body"
        return pokemon if !body && !head && params["optional"]==true
        check(body || head, "No eligible evolution")
        body ||= data.body_pokemon.id
        head ||= data.head_pokemon.id
        target = getFusedPokemonIdFromSymbols(body, head)
      else
        target = checker.call
        return pokemon if !target && params["optional"] == true
        check(target, "No eligible evolution")
      end
      # The callback inspects the old species' evolution methods (held items).
      pokemon.action_after_evolution(target)
      pokemon.species = target
      pokemon.calc_stats
      pokemon
    end
    def execute
      params = @request.fetch("params", {})
      inputs = @request.fetch("inputs", []).map { |entry| import(entry) }
      case @request.fetch("operation")
      when "story_catalog"
        load File.expand_path('native_story.rb',__dir__)
        load File.expand_path('native_battle.rb',__dir__)
        load File.expand_path('native_modes.rb',__dir__)
        KIFServerStory.catalog(inputs).merge('safari_maps'=>KIFServerModes.safari_maps,'contest_maps'=>KIFServerModes.contest_maps,'roamers'=>Settings::ROAMING_SPECIES.each_with_index.map { |data,index| {'index'=>index,'species'=>data[0].to_s,'level'=>data[1],'maps'=>pbRoamingAreas(index).keys} })
      when 'safari_enter','contest_enter','contest_finish','partner_register'
        load File.expand_path('native_battle.rb',__dir__)
        load File.expand_path('native_modes.rb',__dir__)
        if @request['operation']=='partner_register';KIFServerModes.partner(@request,inputs)
        elsif @request['operation']=='contest_finish';KIFServerModes.judge(@request,inputs)
        else;KIFServerModes.entry(@request,inputs)
        end
      when "encounter_catalog"
        maps = []
        GameData::Encounter.each do |data|
          next unless data.version == 0
          types = data.types.each_with_object({}) { |(key, values), hash| hash[key.to_s] = values.map { |entry| entry[2] }.min unless values.empty? }
          maps << {"map_id" => data.map, "types" => types} if types.values.any? { |level| level <= 10 }
        end
        trainers=[]
        GameData::Trainer.each do |data|
          next if data.pokemon.empty? || data.pokemon.any? { |pokemon| pokemon[:level]>10 }
          trainers << {"trainer_type"=>data.trainer_type.to_s,"trainer_name"=>data.real_name,"trainer_version"=>data.version}
          break if trainers.length>=10
        end
        {"maps" => maps.first(50),"trainers"=>trainers}
      when "inspect"
        {"pokemon" => inputs.map { |pokemon| export(pokemon) },"evolutions"=>inputs.map { |pokemon| pokemon.species_data.get_evolutions(true).map { |entry| entry.map { |value| value.is_a?(Symbol) ? value.to_s : value } } }}
      when "starter"
        species = registered(:Species, params.fetch("species"))
        check(%i[BULBASAUR CHARMANDER SQUIRTLE].include?(species), "Choose an approved starter")
        owner = @request.fetch("owner")
        pokemon = Pokemon.new(species, 5, Pokemon::Owner.new(bounded(owner["id"], 0, 0xffffffff), owner["name"], owner.fetch("gender", 0), 0), false, false)
        pokemon.shiny = false
        pokemon.reset_moves
        pokemon.calc_stats
        pokemon.heal
        {"pokemon" => [export(pokemon)]}
      when "train"
        pokemon = inputs.fetch(0)
        count = bounded(params["count"], 1, 99)
        check(pokemon.level + count <= 100, "Level cap exceeded")
        pokemon.level += count
        pokemon.calc_stats
        {"pokemon" => [export(pokemon)]}
      when "ev"
        pokemon = inputs.fetch(0)
        stat = params["stat"]
        check(KIFMultiplayer::Snapshot::STATS.include?(stat), "Unknown stat")
        delta = bounded(params["count"], 1, 25) * 10
        delta = -delta if params["reduce"] == true
        proposed = pokemon.ev[stat.to_sym] + delta
        check(proposed.between?(0, 252) && pokemon.ev.values.sum + delta <= 510, "EV cap exceeded")
        pokemon.ev[stat.to_sym] = proposed
        pokemon.calc_stats
        {"pokemon" => [export(pokemon)]}
      when "learn"
        pokemon = inputs.fetch(0)
        move = registered(:Move, params["move_id"])
        data = pokemon.species_data
        natural = data.moves.any? { |level, id| level <= pokemon.level && id == move }
        check(natural || data.tutor_moves.include?(move), "Move is not available to this species")
        check(!pokemon.moves.any? { |current| current.id == move }, "Move already known")
        slot = bounded(params.fetch("slot", pokemon.moves.length), 0, 3)
        check(slot <= pokemon.moves.length, "Move slot is not contiguous")
        pokemon.moves[slot] = Pokemon::Move.new(move)
        {"pokemon" => [export(pokemon)]}
      when "evolve", "preview_evolution", "trade_evolve"
        {"pokemon" => [export(evolve(inputs.fetch(0), params, inputs[1]))]}
      when "heal"
        inputs.each(&:heal)
        {"pokemon" => inputs.map { |pokemon| export(pokemon) }}
      when "equip"
        pokemon=inputs.fetch(0)
        item=params["item_id"]
        id=item ? registered(:Item,item) : nil
        check(!id || GameData::Item.get(id).can_hold?, "This item cannot be held")
        pokemon.item=id
        {"pokemon"=>[export(pokemon)]}
      when "use_item"
        pokemon=inputs.fetch(0)
        id=registered(:Item,params.fetch("item_id"))
        allowed=%i[POTION SUPERPOTION HYPERPOTION MAXPOTION FULLRESTORE ANTIDOTE PARLYZHEAL PARALYZEHEAL BURNHEAL ICEHEAL AWAKENING FULLHEAL REVIVE MAXREVIVE]
        check(allowed.include?(id),"Use the specific cultivation action for this item")
        scene=Object.new
        scene.define_singleton_method(:pbRefresh) {}
        scene.define_singleton_method(:pbHardRefresh) {}
        scene.define_singleton_method(:pbDisplay) { |_message| }
        used=ItemHandlers::UseOnPokemon.trigger(id,pokemon,scene)
        check(used,"This item has no effect")
        {"pokemon"=>[export(pokemon)]}
      when "breed"
        check(inputs.length == 2, "Choose two breeding parents")
        owner = @request.fetch("owner")
        $Trainer.name, $Trainer.id = owner["name"], owner["id"]
        $Trainer.party = []
        $PokemonGlobal.daycare = [[inputs[0], inputs[0].level], [inputs[1], inputs[1].level]]
        check(pbDayCareGetCompat > 0, "These parents cannot breed")
        pbDayCareGenerateEgg
        egg = $Trainer.party.last
        check(egg && egg.egg?, "Native breeding did not produce an egg")
        steps = egg.steps_to_hatch
        egg.steps_to_hatch = 0
        egg.name = nil
        egg.obtain_method = 1
        egg.timeEggHatched = Time.now.to_i
        egg.calc_stats
        egg.heal
        {"pokemon" => [export(egg)], "hatch_steps" => steps}
      when "battle"
        load File.expand_path("native_battle.rb", __dir__)
        KIFServerBattle.run(@request, inputs)
      when "fuse", "preview_fusion"
        body, head = inputs
        check(body && head && body.species.to_s !~ /\AB\d+H\d+\z/ && head.species.to_s !~ /\AB\d+H\d+\z/, "Fuse two unfused Pokemon")
        species = getFusedPokemonIdFromSymbols(body.species, head.species)
        fused = Pokemon.new(species, (body.level + head.level) / 2, body.owner, false, false)
        fused.name, fused.nature, fused.ability = body.name, body.nature, body.ability_id
        fused.item = body.item_id
        fused.shiny = body.shiny? || head.shiny?
        KIFMultiplayer::Snapshot::STATS.each do |stat|
          key = stat.to_sym
          first, second = %w[HP ATTACK DEFENSE].include?(stat) ? [body, head] : [head, body]
          fused.iv[key] = (first.iv[key] * 2 + second.iv[key]) / 3
          fused.ev[key] = (first.ev[key] * 2 + second.ev[key]) / 3
        end
        if fused.ev.values.sum > 510
          total = fused.ev.values.sum
          KIFMultiplayer::Snapshot::STATS.each { |stat| fused.ev[stat.to_sym] = fused.ev[stat.to_sym] * 510 / total }
          remaining = 510 - fused.ev.values.sum
          KIFMultiplayer::Snapshot::STATS.each do |stat|
            break if remaining <= 0
            key = stat.to_sym
            next if fused.ev[key] >= 252
            fused.ev[key] += 1
            remaining -= 1
          end
        end
        fused.moves = (body.moves + head.moves).uniq { |move| move.id }.first(4).map { |move| copy = Pokemon::Move.new(move.id); copy.ppup = move.ppup; copy.pp = move.pp; copy }
        fused.instance_variable_set(:@exp_when_fused_body, body.exp)
        fused.instance_variable_set(:@exp_when_fused_head, head.exp)
        fused.instance_variable_set(:@exp_gained_since_fused, 0)
        fused.instance_variable_set(:@head_nickname, head.name)
        fused.instance_variable_set(:@head_gender, head.gender)
        fused.calc_stats
        fused.heal
        {"pokemon" => [export(fused)], "lineage" => inputs.map { |pokemon| export(pokemon) }, "fusion_base_exp" => fused.exp}
      when "split"
        fused = inputs.fetch(0)
        lineage = params.fetch("lineage").map { |value| import(value) }
        check(lineage.length == 2 && fused.species.to_s =~ /\AB(\d+)H(\d+)\z/, "No supported fusion lineage")
        body_id, head_id = $1.to_i, $2.to_i
        gain = [fused.exp - params.fetch("fusion_base_exp"), 0].max
        lineage.each_with_index do |pokemon, index|
          id = index == 0 ? body_id : head_id
          check(GameData::Species::DATA.key?(id), "Unknown component species")
          pokemon.species = GameData::Species.get(id).id
          pokemon.exp += index == 0 ? gain / 2 : gain - gain / 2
          pokemon.calc_stats
          pokemon.hp = fused.totalhp > 0 ? pokemon.totalhp * fused.hp / fused.totalhp : 0
          pokemon.status, pokemon.statusCount = fused.status, fused.statusCount
        end
        lineage[0].item = fused.item_id
        {"pokemon" => lineage.map { |pokemon| export(pokemon) }}
      else
        raise "Unsupported native operation"
      end
    end
  end
end

KIFServerEngine.secret, KIFServerEngine.directory = secret, job_directory
passed = false
begin
  raw = File.binread(File.join(job_directory, "request.json"))
  raise "Native input exceeds limit" if raw.bytesize > 2 * 1024 * 1024
  request = KIFServerEngine.verified(KIFMultiplayer::WireJSON.parse(raw))
  KIFServerEngine.request = request
  $POKEMONDATA_QUEUEING = []
  MessageTypes.loadMessageFile("Data/messages.dat")
  PluginManager.runPlugins
  Dir["Mods/*.rb"].sort.each { |file| load File.expand_path(file) }
  Game.initialize
  SaveData.initialize_bootup_values
  SaveData.load_new_game_values
  $scene = Object.new
  $MapFactory = PokemonMapFactory.new($data_system.start_map_id)
  $game_player.moveto($data_system.start_x, $data_system.start_y)
  $PokemonSystem.download_sprites = 1
  actual = KIFMultiplayer::Client.new.compatibility
  raise "Native runtime differs from queued build" unless actual == request.fetch("compatibility")
  result = KIFMultiplayer::BattleIsolation.with { KIFServerEngine.execute }
  KIFServerEngine.write("result.json", {"job_id" => request["job_id"], "nonce" => request["nonce"], "ok" => true, "result" => result})
  passed = true
rescue Exception => error
  File.open(File.join(job_directory, "native-error.log"), "a") { |file| file.puts("#{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
  if defined?(request) && request
    KIFServerEngine.write("result.json", {"job_id" => request["job_id"], "nonce" => request["nonce"], "ok" => false, "error" => error.message.to_s[0, 300]})
  end
ensure
  exit!(passed ? 0 : 1)
end
