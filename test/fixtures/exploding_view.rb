require 'mustache'

# A view whose deep getters raise, used to verify that a failed render
# does not leak section frames onto the shared context stack.
class ExplodingView < Mustache
  class Deep
    def outer
      'stale-deep'
    end

    def boom
      raise ArgumentError, 'deep getter exploded'
    end
  end

  class Middle
    def outer
      'stale-middle'
    end

    def deep
      Deep.new
    end
  end

  def outer
    'outer-value'
  end

  def middle
    Middle.new
  end

  def items
    [Middle.new]
  end

  def exploding_lambda
    lambda { |_| '{{#middle}}{{#deep}}{{boom}}{{/deep}}{{/middle}}' }
  end

  def partial(name)
    '{{#middle}}{{#deep}}{{boom}}{{/deep}}{{/middle}}'
  end
end
