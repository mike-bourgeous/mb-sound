# Oscillators and constants play forever, so specs that need a source that
# ends use finite(node, seconds): +node+ for +seconds+ (at the node's sample
# rate when sampled), then the end of the stream (a short last buffer, then
# nil).
class SpecFiniteNode
  include MB::Sound::GraphNode

  attr_reader :seconds

  def initialize(node, seconds)
    @node = node
    @seconds = seconds
    @elapsed = 0
    @node_type_name = 'Finite'
  end

  def sample(count)
    remaining = (@seconds * @node.sample_rate).round - @elapsed
    return nil if remaining <= 0

    count = remaining if count > remaining
    @elapsed += count
    @node.sample(count)
  end

  def sample_rate
    @node.sample_rate
  end

  def sample_rate=(rate)
    @node.sample_rate = rate
    self
  end
  alias at_rate sample_rate=

  def sources
    { input: @node }
  end
end

module SpecFinite
  def finite(node, seconds)
    SpecFiniteNode.new(node, seconds)
  end
end

RSpec.configure do |c|
  c.include SpecFinite
end
