# The Android UI owns a separate latched key queue. Physical keyboards and
# controllers continue through mkxp's original Input methods.
module KIF
  class AndroidInputBackend
    CODES = [2, 4, 6, 8, 11, 12, 13, 14, 15, 16, 17, 18].freeze
    DIRECTIONS = [2, 4, 6, 8].freeze
    MASK = CODES.inject(0) { |mask, code| mask | (1 << code) }
    DIRECTION_MASK = DIRECTIONS.inject(0) { |mask, code| mask | (1 << code) }
    OTHER_DIRECTIONS = { 2 => [4, 6, 8], 4 => [2, 8, 6],
      6 => [2, 8, 4], 8 => [4, 6, 2] }.freeze
    DIAGONALS = { [2, 4] => 1, [2, 6] => 3, [2, 8] => 0,
      [4, 2] => 1, [4, 8] => 7, [4, 6] => 0,
      [6, 2] => 3, [6, 8] => 9, [6, 4] => 0,
      [8, 4] => 7, [8, 6] => 9, [8, 2] => 0 }.freeze
    REPEAT_START = 23
    REPEAT_INTERVAL = 6

    def self.install(input, bridge)
      existing = input.instance_variable_get(:@kif_android_input_backend)
      return existing if existing
      backend = new(input, bridge)
      backend.install_methods
      input.instance_variable_set(:@kif_android_input_backend, backend)
      backend
    end

    def initialize(input, bridge)
      @input = input
      @bridge = bridge
      @native = {}
      [:update, :press?, :trigger?, :repeat?, :dir4, :dir8].each do |name|
        @native[name] = input.method(name)
      end
      @native[:release?] = input.method(:release?) if input.respond_to?(:release?)
      clear_virtual_state
      @previous_direction = 0
    end

    def install_methods
      # Capture Method objects before replacing names. Later scripts may alias
      # these wrappers; no super/prepend or re-looked-up native alias can recurse.
      backend = self
      @input.define_singleton_method(:update) { backend.update }
      [:press?, :trigger?, :repeat?, :release?].each do |name|
        next unless @native.key?(name)
        native = @native.fetch(name)
        @input.define_singleton_method(name) do |code|
          native.call(code) || backend.virtual_query(name, code)
        end
      end
      @input.define_singleton_method(:dir4) { backend.direction(4) }
      @input.define_singleton_method(:dir8) { backend.direction(8) }
    end

    def update
      result = @native.fetch(:update).call
      begin
        snapshot = @bridge.input_poll
        unless snapshot.is_a?(Array) && snapshot.length == 3 &&
            snapshot.all? { |mask| mask.is_a?(Integer) && mask >= 0 }
          raise ArgumentError, "Invalid Android input snapshot"
        end
        @pressed, @triggered, @released = snapshot.map { |mask| mask & MASK }
        @repeated = @triggered # A down+up between polls still confirms once.
        CODES.each do |code|
          bit = 1 << code
          if (@pressed & bit) == 0
            @held_updates.delete(code)
          elsif (@triggered & bit) != 0
            @held_updates[code] = 0
          else
            count = @held_updates.key?(code) ? @held_updates[code] + 1 : 0
            @held_updates[code] = count
            @repeated |= bit if count >= REPEAT_START && (count + 1) % REPEAT_INTERVAL == 0
          end
        end
        update_directions
        @last_error = nil
      rescue StandardError => error
        clear_virtual_state # Never leave a held virtual key after a bad poll.
        if @last_error != error.class && defined?(System) && System.respond_to?(:puts)
          System.puts("KIF Android input poll unavailable (#{error.class}); native input remains active")
        end
        @last_error = error.class
      end
      result
    end

    def virtual_query(name, code)
      return false unless code.is_a?(Integer) && CODES.include?(code)
      mask = case name
      when :press? then @pressed
      when :trigger? then @triggered
      when :repeat? then @repeated
      when :release? then @released
      else 0
      end
      (mask & (1 << code)) != 0
    end

    def direction(size)
      # Preserve all native direction/history behavior when no touch direction is held.
      return @native.fetch(size == 4 ? :dir4 : :dir8).call if (@pressed & DIRECTION_MASK) == 0
      size == 4 ? @dir4 : @dir8
    end

    private

    def clear_virtual_state
      @pressed = @triggered = @released = @repeated = 0
      @held_updates = {}
      @dir4 = @dir8 = 0
      @previous_direction = 0
    end

    def update_directions
      held = {}
      DIRECTIONS.each do |code|
        held[code] = @native.fetch(:press?).call(code) || virtual_query(:press?, code)
      end
      flags = DIRECTIONS.inject(0) { |mask, code| held[code] ? mask | (1 << code) : mask }
      if flags == ((1 << 2) | (1 << 8)) || flags == ((1 << 4) | (1 << 6))
        @dir4 = 0
      elsif @previous_direction != 0 && held[@previous_direction] &&
          (other = OTHER_DIRECTIONS.fetch(@previous_direction).find { |code| held[code] })
        @dir4 = other
      else
        @dir4 = DIRECTIONS.find { |code| held[code] } || 0
        @previous_direction = @dir4
      end
      @dir8 = 0
      DIRECTIONS.each do |code|
        next unless held[code]
        other = OTHER_DIRECTIONS.fetch(code).find { |candidate| held[candidate] }
        @dir8 = other ? DIAGONALS.fetch([code, other]) : code
        break
      end
    end
  end
end
