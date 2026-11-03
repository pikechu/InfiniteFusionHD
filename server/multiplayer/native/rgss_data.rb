# frozen_string_literal: true
# Data-only RGSS XP types needed to read the trusted installed map resources.
# No rendering, scripting, deserialization hooks from a network save, or guessed
# gameplay methods are provided here.
class Table
  attr_reader :xsize, :ysize, :zsize
  def self._load(raw)
    dimensions, x, y, z, count = raw.unpack("V5")
    raise "invalid_trusted_table" unless (1..3).include?(dimensions) && x * y * z == count && raw.bytesize == 20 + count * 2
    object = allocate
    object.instance_variable_set(:@dimensions, dimensions)
    object.instance_variable_set(:@xsize, x)
    object.instance_variable_set(:@ysize, y)
    object.instance_variable_set(:@zsize, z)
    object.instance_variable_set(:@data, raw.byteslice(20..-1).unpack("s<*"))
    object
  end
  def initialize(x, y = 1, z = 1)
    @dimensions = z > 1 ? 3 : y > 1 ? 2 : 1
    @xsize, @ysize, @zsize = x, y, z
    @data = Array.new(x * y * z, 0)
  end
  def [](x, y = 0, z = 0)
    return nil unless (0...@xsize).include?(x) && (0...@ysize).include?(y) && (0...@zsize).include?(z)
    @data[x + y * @xsize + z * @xsize * @ysize]
  end
  def []=(*arguments)
    value = arguments.pop
    x, y, z = arguments[0], arguments[1] || 0, arguments[2] || 0
    return value unless (0...@xsize).include?(x) && (0...@ysize).include?(y) && (0...@zsize).include?(z)
    @data[x + y * @xsize + z * @xsize * @ysize] = value
  end
  def _dump(*)
    [@dimensions, @xsize, @ysize, @zsize, @data.length].pack("V5") + @data.pack("s<*")
  end
end

module RPG
  class Record
    def method_missing(name, *arguments)
      field = "@#{name.to_s.delete_suffix('=')}"
      if name.to_s.end_with?("=") && arguments.length == 1 && instance_variable_defined?(field)
        instance_variable_set(field, arguments.first)
      elsif arguments.empty? && instance_variable_defined?(field)
        instance_variable_get(field)
      else
        super
      end
    end
    def respond_to_missing?(name, include_private = false)
      instance_variable_defined?("@#{name.to_s.delete_suffix('=')}") || super
    end
  end
  %w[Map MapInfo Event EventCommand MoveRoute MoveCommand Tileset System
     CommonEvent Animation Actor Class Skill Item Weapon Armor Enemy Troop
     State AudioFile].each { |name| const_set(name, ::Class.new(Record)) }
  %w[Page].each { |name| Event.const_set(name, ::Class.new(Record)) }
  %w[Condition Graphic].each { |name| Event::Page.const_set(name, ::Class.new(Record)) }
  %w[Words TestBattler].each { |name| System.const_set(name, ::Class.new(Record)) }
  %w[Frame Timing].each { |name| Animation.const_set(name, ::Class.new(Record)) }
  class AudioFile
    attr_accessor :name, :volume, :pitch
    def initialize(name = "", volume = 100, pitch = 100)
      @name, @volume, @pitch = name, volume, pitch
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code = 0, indent = 0, parameters = [])
      @code, @indent, @parameters = code, indent, parameters
    end
  end
end
