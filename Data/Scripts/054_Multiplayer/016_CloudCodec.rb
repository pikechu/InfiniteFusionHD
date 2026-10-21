# Cloud saves contain a bounded JSON object graph, never network Marshal data.
# Executable event/map/interpreter state is rebuilt from installed game assets.
module KIFMultiplayer
  module CloudCodec
    MAX_JSON = 32 * 1024 * 1024
    MAX_COMPRESSED = 1024 * 1024
    MAX_OBJECTS = 100_000
    CLASSES = %w[Player Player::Pokedex Pokemon Pokemon::Owner Pokemon::Move
      PokemonBag PokemonStorage PokemonBox PokemonGlobalMetadata PokemonMapMetadata
      PokemonSystem Game_System Game_Switches Game_Variables Game_SelfSwitches
      Game_Screen Game_Picture SafariState BugContestState PokemonMail
      Pokemon::Mail Pokemon::MoveRelearner PokemonSelection RPG::AudioFile].freeze
    SKIP = %w[@map_interpreter @battle_interpreter @interpreter @move_route
      @original_move_route @map @list @event @common_events].freeze

    # The embedded Ruby runtime has pack/unpack but no base64 stdlib file.
    module Base64
      def self.strict_encode64(bytes); [bytes].pack("m0"); end
      def self.strict_decode64(text)
        raise ArgumentError, "invalid base64" unless text.is_a?(String) && text.bytesize % 4 == 0 && text =~ /\A[A-Za-z0-9+\/]*={0,2}\z/
        text.unpack1("m0")
      end
    end

    def self.check(value, message)
      raise Error.new(message, "invalid_cloud_save") unless value
    end

    def self.classes
      # Lookup only these hard-coded local names, never a class from the wire.
      @classes ||= CLASSES.each_with_object({}) do |name, result|
        begin
          klass = name.split("::").inject(Object) { |scope, part| scope.const_get(part, false) }
          result[name] = klass if klass.is_a?(Class)
        rescue NameError
          nil
        end
      end
    end

    def self.pack(save_data)
      require "zlib"
      require "digest/sha2"
      graph = Encoder.new.encode(save_data)
      json = WireJSON.encode(graph, 0)
      check(json.bytesize <= MAX_JSON, "存档超过云端格式大小限制。")
      compressed = Zlib::Deflate.deflate(json)
      check(compressed.bytesize <= MAX_COMPRESSED, "压缩存档超过云端大小限制。")
      {"format" => "kif-save-json-v1", "game_version" => Settings::GAME_VERSION.to_s,
       "payload" => Base64.strict_encode64(compressed), "sha256" => Digest::SHA256.hexdigest(compressed)}
    end

    def self.unpack(document)
      require "zlib"
      require "digest/sha2"
      check(document.is_a?(Hash) && document["format"] == "kif-save-json-v1", "云存档格式不支持。")
      check(document["game_version"] == Settings::GAME_VERSION.to_s, "云存档与游戏版本不同，请使用相同版本。")
      check(document["payload"].is_a?(String) && document["payload"].bytesize <= (MAX_COMPRESSED * 4 / 3 + 4), "云存档过大。")
      compressed = Base64.strict_decode64(document["payload"])
      check(compressed.bytesize <= MAX_COMPRESSED && Digest::SHA256.hexdigest(compressed) == document["sha256"], "云存档校验失败。")
      json = "".b
      inflater = Zlib::Inflate.new
      begin
        inflater.inflate(compressed) do |chunk|
          check(json.bytesize + chunk.bytesize <= MAX_JSON, "云存档解压大小超限。")
          json << chunk
        end
        check(inflater.finished? && inflater.total_in == compressed.bytesize, "云存档压缩数据不完整。")
      ensure
        inflater.close
      end
      graph = WireJSON.parse(json, MAX_JSON, 2_000_000)
      value = Decoder.new.decode(graph)
      check(value.is_a?(Hash) && SaveData.valid?(value), "云存档缺少必需的游戏数据。")
      value
    rescue ArgumentError, Zlib::Error => error
      raise Error.new("云存档损坏：#{error.class}", "invalid_cloud_save")
    end

    class Encoder
      def encode(root)
        @nodes, @ids, @queue = [], {}, []
        reference = ref(root)
        index = 0
        while index < @queue.length
          @nodes[index] = node(@queue[index])
          index += 1
        end
        {"version" => 1, "root" => reference, "nodes" => @nodes}
      end

      def ref(value)
        return value if value.nil? || value.equal?(true) || value.equal?(false) || value.is_a?(Integer)
        if value.is_a?(Float)
          CloudCodec.check(value.finite?, "存档包含非法数字。")
          return value
        end
        return {"symbol" => value.to_s} if value.is_a?(Symbol)
        index = @ids[value.object_id]
        unless index
          CloudCodec.check(@queue.length < MAX_OBJECTS, "存档对象过多。")
          index = @queue.length
          @ids[value.object_id] = index
          @queue << value
        end
        {"ref" => index}
      end

      def node(value)
        case value
        when String
          {"type" => "string", "bytes" => Base64.strict_encode64(value.b), "encoding" => value.encoding.name}
        when Array
          {"type" => "array", "items" => value.map { |v| ref(v) }}
        when Hash
          CloudCodec.check(!value.default_proc, "含动态默认值的存档字段暂不支持云同步。")
          {"type" => "hash", "items" => value.map { |k, v| [ref(k), ref(v)] }, "default" => ref(value.default)}
        when Time
          {"type" => "time", "seconds" => value.to_i, "nsec" => value.nsec}
        else
          name = value.class.name
          if name == "PokemonMapFactory"
            # No map scripts, event commands, or saved interpreter stacks cross
            # the network. Game.load_map rebuilds this map from local resources.
            {"type" => "map_factory", "map_id" => value.map.map_id}
          elsif name == "Game_Player"
            {"type" => "player_position", "ivars" => ivars(value)}
          elsif %w[Color Tone].include?(name)
            fields = name == "Color" ? [:red, :green, :blue, :alpha] : [:red, :green, :blue, :gray]
            {"type" => name.downcase, "values" => fields.map { |field| value.send(field) }}
          elsif %w[GameData::Species GameData::FusedSpecies].include?(name)
            {"type" => "species", "id" => value.id.to_s}
          else
            CloudCodec.check(CloudCodec.classes[name] == value.class, "存档包含暂不支持的字段类型：#{name}")
            {"type" => "object", "class" => name, "ivars" => ivars(value)}
          end
        end
      end

      def ivars(value)
        value.instance_variables.each_with_object({}) do |key, result|
          next if SKIP.include?(key.to_s)
          # Actor movement routes can execute Ruby. Reset them on cloud resume.
          next if value.class.name == "Game_Player" && %w[@move_route_forcing @original_move_route_index @move_route_index].include?(key.to_s)
          result[key.to_s] = ref(value.instance_variable_get(key))
        end
      end
    end

    class Decoder
      def decode(graph)
        check(graph.is_a?(Hash) && graph["version"] == 1 && graph["nodes"].is_a?(Array) && graph["nodes"].length <= MAX_OBJECTS)
        @nodes = graph["nodes"]
        @objects = @nodes.map { |node| allocate(node) }
        @nodes.each_with_index { |node, index| fill(@objects[index], node) }
        @objects.each { |object| object.rehash if object.is_a?(Hash) }
        read(graph["root"])
      end

      def check(value); CloudCodec.check(value, "云存档结构不合法。"); end
      def int(value, low, high); check(value.is_a?(Integer) && value.between?(low, high)); value; end
      def read(value)
        return value if value.nil? || value.equal?(true) || value.equal?(false) || value.is_a?(Integer)
        return value if value.is_a?(Float) && value.finite?
        check(value.is_a?(Hash) && value.length == 1)
        if value.key?("ref")
          @objects[int(value["ref"], 0, @objects.length - 1)]
        else
          text = value["symbol"]
          check(text.is_a?(String) && text.bytesize.between?(1, 128) && text !~ /[\x00-\x1f]/)
          text.to_sym
        end
      end

      def allocate(node)
        check(node.is_a?(Hash))
        case node["type"]
        when "array" then []
        when "hash" then {}
        when "string"
          check(node["bytes"].is_a?(String) && %w[UTF-8 ASCII-8BIT US-ASCII].include?(node["encoding"]))
          value = Base64.strict_decode64(node["bytes"]).force_encoding(node["encoding"])
          check(value.valid_encoding?)
          value
        when "time"
          Time.at(int(node["seconds"], -62135596800, 253402300799), int(node["nsec"], 0, 999999999), :nanosecond)
        when "color", "tone"
          values = node["values"]
          check(values.is_a?(Array) && values.length == 4 && values.all? { |v| v.is_a?(Numeric) && v.finite? && v.between?(-255, 255) })
          node["type"] == "color" ? Color.new(*values) : Tone.new(*values)
        when "species"
          check(node["id"].is_a?(String) && node["id"] =~ /\A[A-Za-z0-9_]{1,80}\z/)
          GameData::Species.get(node["id"])
        when "map_factory"
          id = int(node["map_id"], 1, 99999)
          check(File.file?(sprintf("Data/Map%03d.rxdata", id)))
          map = Game_Map.new
          map.map_id = id
          map.instance_variable_set(:@map, load_data(sprintf("Data/Map%03d.rxdata", id)))
          factory = PokemonMapFactory.allocate
          {:@maps => [map], :@mapIndex => 0, :@fixup => false, :@mapChanged => true}.each { |key, v| factory.instance_variable_set(key, v) }
          factory
        when "player_position" then Game_Player.new
        when "object"
          klass = CloudCodec.classes[node["class"]]
          check(klass)
          node["class"] == "Game_System" ? klass.new : klass.allocate
        else
          check(false)
        end
      end

      def fill(value, node)
        case node["type"]
        when "array"
          check(node["items"].is_a?(Array))
          node["items"].each { |entry| value << read(entry) }
        when "hash"
          check(node["items"].is_a?(Array))
          node["items"].each do |entry|
            check(entry.is_a?(Array) && entry.length == 2)
            value[read(entry[0])] = read(entry[1])
          end
          value.default = read(node["default"])
        when "object", "player_position"
          check(node["ivars"].is_a?(Hash) && node["ivars"].length <= 1024)
          node["ivars"].each do |key, entry|
            check(key.is_a?(String) && key =~ /\A@[A-Za-z_][A-Za-z0-9_]{0,100}\z/ && !SKIP.include?(key))
            check(!%w[@move_route_forcing @original_move_route_index @move_route_index].include?(key)) if node["type"] == "player_position"
            value.instance_variable_set(key, read(entry))
          end
          value.magic_number = -1 if node["class"] == "Game_System"
        end
      end
    end
  end
end
