# Installed-data battle declarations. Never evaluate a client script or object.
module KIFServerStory
  class Unsupported < StandardError; end
  BATTLES=%w[pbWildBattle pbWildBattleID pbWildBattleSpecific pbWildDoubleBattleSpecific pbDoubleWildBattle pbTripleWildBattle pb1v3WildBattle customTrainerBattle pbTrainerBattle pbDoubleTrainerBattle pbTripleTrainerBattle].freeze

  # Split only at top-level separators. Nested arrays/calls and quoted strings
  # remain data; Ruby interpolation, eval and arbitrary method dispatch are absent.
  def self.split(text,separators=',')
    values=[];value='';depth=0;quote=nil;escaped=false;comment=false
    text.each_char do |char|
      if comment
        next unless char=="\n"
        comment=false
      end
      if quote
        value<<char
        if escaped;escaped=false
        elsif char=='\\';escaped=true
        elsif char==quote;quote=nil
        end
      elsif char=='#'
        comment=true
      elsif ['"',"'"].include?(char)
        quote=char;value<<char
      elsif '([{'.include?(char)
        depth+=1;value<<char
      elsif ')]}'.include?(char)
        depth-=1;raise Unsupported,'Unbalanced installed expression' if depth<0
        value<<char
      elsif depth==0 && separators.include?(char)
        values<<value.strip unless value.strip.empty?;value=''
      else
        value<<char
      end
    end
    raise Unsupported,'Incomplete installed expression' if quote || depth!=0
    values<<value.strip unless value.strip.empty?
    values
  end

  class Resolver
    attr_reader :battles,:issues,:partners
    def initialize(party)
      @party,@locals,@variables,@battles,@rules=party,{}, {},[],{}
      @issues=[]
      @partners=[]
    end
    def value(text,depth=0)
      raise Unsupported,'Installed expression exceeds limit' if depth>12 || text.length>4096
      text=text.strip
      return text.to_i if text =~ /\A-?\d+\z/
      return true if ['true','TRUE'].include?(text)
      return false if ['false','FALSE'].include?(text)
      return nil if ['nil','NIL'].include?(text)
      return text[1..-2].gsub(/\\(["'\\])/, '\\1') if text =~ /\A(?:"[^"#]*"|'[^'#]*')\z/m
      return text[1..].to_sym if text =~ /\A:[A-Za-z0-9_]+\z/
      return text.split('::').last.to_sym if text =~ /\A(?:PBSpecies|PBMoves|PBItems|PBAbilities|PBTrainers)::[A-Za-z0-9_]+\z/
      return KIFServerStory.split(text[1..-2]).map { |entry| value(entry,depth+1) } if text.start_with?('[') && text.end_with?(']')
      return @locals.fetch(text) { raise Unsupported,"Unresolved installed local #{text}" } if text =~ /\A[a-z_]\w*\z/
      return @party if text=='$Trainer.party'
      return @party.fetch($1.to_i) if text =~ /\A\$Trainer\.party\[(\d+)\]\z/
      return @variables.fetch($1.to_i) { raise Unsupported,'Unresolved installed game variable' } if text =~ /\A\$game_variables\[(\d+)\]\z/
      if text =~ /\A(.+)\.(level|species|totalhp)\z/
        expression,field=$1,$2;pokemon=value(expression,depth+1)
        raise Unsupported,'Expected an authoritative Pokemon' unless pokemon.is_a?(Pokemon)
        return pokemon.public_send(field)
      end
      if text =~ /\A([A-Za-z_][\w:.]*)\s*\((.*)\)\z/m
        method,args=$1,KIFServerStory.split($2).map { |entry| value(entry,depth+1) }
        case method
        when 'Pokemon.new','PokeBattle_Pokemon.new','pbGenerateWildPokemon'
          species=species(args[0]);level=level(args[1])
          pokemon=Pokemon.new(species,level);pokemon.reset_moves;pokemon.calc_stats;pokemon.heal
          return pokemon
        when 'PBMove.new','Pokemon::Move.new'
          return Pokemon::Move.new(KIFServerEngine.registered(:Move,args[0].to_s))
        when 'pbGet'
          return @variables.fetch(args[0]) { raise Unsupported,'Unresolved installed game variable' }
        when 'pbGetPokemon'
          return @party.fetch(@variables.fetch(args[0],0))
        when 'getFusedPokemonIdFromSymbols'
          return getFusedPokemonIdFromSymbols(species(args[0]),species(args[1]))
        when 'rand'
          limit=args[0];raise Unsupported,'Invalid installed random bound' unless limit.is_a?(Integer) && limit.between?(1,10000)
          return rand(limit)
        end
      end
      raise Unsupported,"Unsupported installed expression: #{text[0,100]}"
    end
    def species(id)
      if id.is_a?(Integer)
        raise Unsupported,'Unknown installed dex entry' unless GameData::Species::DATA.key?(id) || id.between?(NB_POKEMON+1,NB_POKEMON*(NB_POKEMON+1))
        return GameData::Species.get(id).id
      end
      KIFServerEngine.registered(:Species,id.to_s)
    end
    def level(number)
      raise Unsupported,'Invalid installed encounter level' unless number.is_a?(Integer) && number.between?(1,100)
      number
    end
    def variables(command)
      data=command.parameters
      return unless data[2]==0 && data[0]==data[1]
      result=case data[3]
             when 0 then data[4]
             when 1 then @variables[data[4]]
             when 2 then rand(data[4]..data[5])
             else nil
             end
      @variables[data[0]]=result unless result.nil?
    end
    def statement(text,index)
      text=text.sub(/\A(?:if|unless)\s+(?=(?:#{BATTLES.join('|')})\s*\()/,'')
      text=text.sub(/\A[a-z_]\w*\s*=\s*(?=(?:#{BATTLES.join('|')})\s*\()/,'')
      if text =~ /\A(?:([a-z_]\w*)|(\$game_variables\[(\d+)\]))\s*=\s*(.+)\z/m
        name,var_id,expression=$1,$3,$4
        result=value(expression)
        var_id ? @variables[var_id.to_i]=result : @locals[name]=result
      elsif text =~ /\A([a-z_]\w*)\.(ability|item|hp|level)\s*=\s*(.+)\z/m
        name,field,expression=$1,$2,$3
        pokemon=@locals.fetch(name);raise Unsupported,'Expected Pokemon definition' unless pokemon.is_a?(Pokemon)
        result=value(expression)
        if field=='ability';result=KIFServerEngine.registered(:Ability,result.to_s)
        elsif field=='item';result=KIFServerEngine.registered(:Item,result.to_s) if result
        elsif field=='level';result=level(result)
        elsif field=='hp';raise Unsupported,'Invalid installed health' unless result.is_a?(Integer) && result.between?(0,pokemon.totalhp)
        end
        pokemon.public_send(field+'=',result);pokemon.calc_stats if field=='level'
      elsif text =~ /\A([a-z_]\w*)\.forget_all_moves(?:\(\))?\z/
        @locals.fetch($1).moves.clear
      elsif text =~ /\A([a-z_]\w*)\.learn_move\((.+)\)\z/m
        @locals.fetch($1).learn_move(KIFServerEngine.registered(:Move,value($2).to_s))
      elsif text =~ /\A(setPokemonMoves|pbSet|setBattleRule|pbRegisterPartner)\s*\((.*)\)\z/m
        method,args=$1,KIFServerStory.split($2).map { |entry| value(entry) }
        case method
        when 'pbSet';@variables[args[0]]=args[1]
        when 'pbRegisterPartner';@partners<<{'trainer_type'=>args[0].to_s,'trainer_name'=>args[1],'trainer_version'=>args[2] || 0}
        when 'setPokemonMoves';args[0].moves=args[1].map { |move| Pokemon::Move.new(KIFServerEngine.registered(:Move,move.to_s)) }
        when 'setBattleRule'
          args.each { |rule| @rules[rule.to_s.downcase]=true if %w[single double triple cannotrun canrun canlose nomoney noexp birdboss].include?(rule.to_s.downcase) }
        end
      elsif text =~ /\A(#{BATTLES.join('|')})\s*\((.*)\)\z/m
        method,raw=$1,$2
        args=KIFServerStory.split(raw).map { |entry| value(entry) }
        descriptor={'command_index'=>index,'rules'=>@rules.dup,'method'=>method}
        if %w[pbWildBattle pbWildBattleID pbDoubleWildBattle pbTripleWildBattle pb1v3WildBattle].include?(method)
          count={'pbDoubleWildBattle'=>2,'pbTripleWildBattle'=>3,'pb1v3WildBattle'=>3}.fetch(method,1)
          descriptor['rules']['birdboss']=true if method=='pb1v3WildBattle'
          descriptor['foes']=(0...count).map { |i| Pokemon.new(species(args[i*2]),level(args[i*2+1])) }
          descriptor['can_run']=args[count*2+1]!=false;descriptor['can_lose']=args[count*2+2]==true
        elsif method=='pbWildBattleSpecific' || method=='pbWildDoubleBattleSpecific'
          count=method=='pbWildBattleSpecific' ? 1 : 2
          descriptor['foes']=args.first(count)
          raise Unsupported,'Expected compiled Pokemon declarations' unless descriptor['foes'].all? { |pokemon| pokemon.is_a?(Pokemon) }
          descriptor['can_run']=args[count+1]!=false;descriptor['can_lose']=args[count+2]==true
        elsif method=='customTrainerBattle'
          trainer=NPCTrainer.new(args[0],KIFServerEngine.registered(:TrainerType,args[1].to_s))
          trainer.party=args[2].map { |entry| entry.is_a?(Pokemon) ? entry : Pokemon.new(species(entry),level(args[3] || 50),trainer) }
          descriptor['trainers']=[trainer];descriptor['foes']=trainer.party
        else
          count={'pbDoubleTrainerBattle'=>2,'pbTripleTrainerBattle'=>3}.fetch(method,1)
          trainers=(0...count).map do |i|
            start=i*4;type=KIFServerEngine.registered(:TrainerType,args[start].to_s);name=args[start+1];version=args[start+2].is_a?(Integer) ? args[start+2] : 0
            raise Unsupported,'Unknown compiled trainer' unless GameData::Trainer::DATA.key?([type,name,version])
            pbLoadTrainer(type,name,version)
          end
          descriptor['trainers']=trainers;descriptor['foes']=trainers.flat_map(&:party)
        end
        descriptor=Marshal.load(Marshal.dump(descriptor))
        @battles<<descriptor
      end
    rescue Unsupported,KeyError,IndexError,TypeError,RuntimeError=>error
      # UI, text, local quest state and unsupported expressions are never run.
      # A battle that depends on unresolved data is absent from this catalogue.
      @issues<<{'command_index'=>index,'expression'=>text[0,140],'error'=>error.message[0,150]}
      nil
    end
    def commands(list,seen=[],origin_index=nil)
      index=0
      while index<list.length
        command=list[index]
        if command.code==122;variables(command)
        elsif command.code==117 && !seen.include?(command.parameters[0]) && seen.length<8
          id=command.parameters[0];common=load_data('Data/CommonEvents.rxdata')[id]
          commands(common.list,seen+[id],origin_index || index) if common
        elsif command.code==355
          script=command.parameters[0].to_s
          while list[index+1] && [355,655].include?(list[index+1].code)
            index+=1;script+="\n"+list[index].parameters[0].to_s
          end
          KIFServerStory.split(script,"\n;").each { |line| statement(line,origin_index || index) }
        end
        index+=1
      end
    end
  end

  def self.resolve(params,party)
    context=params.fetch('story')
    map=load_data('Data/Map%03d.rxdata' % params.fetch('map_id'))
    event=map.events.fetch(context.fetch('event_id'));page=event.pages.fetch(context.fetch('page'))
    resolver=Resolver.new(party);resolver.commands(page.list)
    matches=resolver.battles.select { |battle| battle['command_index']==context.fetch('command_index') }
    raise Unsupported,'Battle does not belong to this installed event command' if matches.empty?
    descriptor=matches.fetch(context.fetch('occurrence',0))
    raise Unsupported,'Compiled encounter exceeds verified level cap' if descriptor['foes'].any? { |pokemon| pokemon.level>params.fetch('level_cap') }
    descriptor
  end

  def self.catalog(party=[])
    entries=[]
    Dir['Data/Map[0-9]*.rxdata'].sort.each do |path|
      map_id=File.basename(path)[/\d+/].to_i
      map=load_data(path)
      map.events.each_value do |event|
        event.pages.each_with_index do |page,page_index|
          script=page.list.select { |command| [355,655].include?(command.code) }.map { |command| command.parameters[0].to_s }.join("\n")
          next unless script =~ /pb(?:WildBattle|DoubleWildBattle|TripleWildBattle|TrainerBattle|DoubleTrainerBattle|TripleTrainerBattle|Safari|BugContest|RegisterPartner)|Pokemon\.new|pbGenerateWildPokemon/
          resolver=Resolver.new(party)
          resolver.commands(page.list)
          descriptions=resolver.battles.map { |battle| {'method'=>battle['method'],'command_index'=>battle['command_index'],'foes'=>battle['foes'].map { |pokemon| {'species'=>pokemon.species.to_s,'level'=>pokemon.level} }} }
          entries << {'map_id'=>map_id,'event_id'=>event.id,'page'=>page_index,'source'=>script[0,2800],'battles'=>descriptions,'issues'=>resolver.issues.first(15),'partners'=>resolver.partners}
          return {'entries'=>entries,'truncated'=>true} if entries.length>=400
        end
      end
    end
    {'entries'=>entries,'truncated'=>false}
  end
end
