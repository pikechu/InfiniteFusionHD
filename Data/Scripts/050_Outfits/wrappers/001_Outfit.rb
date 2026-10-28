class Outfit
  attr_accessor :id
  attr_writer :name
  attr_writer :description
  attr_accessor :tags
  attr_accessor :price

  def initialize(id, name, description = '',price=0, tags = [])
    @id = id
    @name = name
    @description = description
    @tags = tags
    @price = price
  end

  def name
    return @name.is_a?(String) ? _INTL(@name) : @name
  end

  def description
    return @description.is_a?(String) ? _INTL(@description) : @description
  end

  def trainer_sprite_path()
    return nil
  end
end