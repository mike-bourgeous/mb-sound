# Round-trip checks for MB::Sound::RubyValue (printers-1): a printed value
# reloads as an equal value of the same class, in the console's context
# (MB::Sound's constants and methods, like take scripts) and through the
# graph document loader.
module RubyValueCheck
  module_function

  # The value +text+ makes, evaluated inside MB::Sound (take scripts and the
  # console resolve names there).
  def reload(text)
    MB::Sound.module_eval(text)
  end

  # The value +text+ makes as an expression in a graph document's body
  # (GraphIO's loader walking the Prism tree, no eval).
  def load_value(text)
    require 'prism'
    loader = MB::Sound::GraphIO::Loader.new("graph #{MB::Sound::GraphIO::FORMAT}\n#{text}\n")
    loader.send(:fresh_limits!)
    node = Prism.parse(text).value.statements.body[0]
    loader.send(:eval_node, node, MB::Sound::GraphIO::Loader::Scope.new)
  end

  # A comparable key for +v+: equal keys for equal values of the same class
  # (Pitches compare by identity, so by frequency here).
  def key(v)
    case v
    when Array then [Array, v.map { |x| key(x) }]
    when Hash then [Hash, v.map { |k, x| [key(k), key(x)] }]
    when Range then [v.class, key(v.begin), key(v.end), v.exclude_end?]
    when MB::Sound::Pitch then [v.class, v.frequency, v.constant? ? nil : v.freq.class]
    when MB::Sound::Param::Ranged then [v.class, key(v.range), key(v.default)]
    when MB::Sound::Scale then [v.class, v.offsets, v.root, v.period]
    when MB::Sound::Curve, MB::Sound::Generative::Value then [v.class, MB::Sound::RubyValue.to_ruby(v)]
    when Float then [Float, v.nan? ? :nan : v]
    when MB::Sound::Length::Seconds, MB::Sound::Length::Samples then [v.class, key(v.value)]
    else [v.class, v]
    end
  end

  # Whether +a+ and +b+ are equal values of the same class (all the way
  # down).
  def same?(a, b)
    key(a) == key(b)
  end

  # Plain values in the recorded calls of +graph+ (arguments, keyword
  # values, and receivers that aren't graph objects), with where they were
  # found, for the recipe sweep.
  def leaves(graph)
    recipe = MB::Sound::GraphNode::Recipe
    found = []
    seen = {}.compare_by_identity
    visit_call = nil
    visit = ->(o) {
      next if o.nil? || seen.key?(o)
      seen[o] = true
      calls = [recipe.record_of(o)&.call, *recipe.config_of(o)].compact
      calls.each { |c| visit_call.(c) }
    }
    visit_call = ->(c) {
      values = [*c.args, *(c.kwargs || {}).values]
      values << c.receiver unless c.receiver.is_a?(Module)
      values.each do |v|
        if recipe.graph_object?(v)
          visit.(v)
        elsif plain?(v)
          found << [c.name, v]
        end
      end
      (c.invocations || []).each { |inv| visit.(inv.result) if recipe.graph_object?(inv.result) }
    }
    nodes = graph.respond_to?(:graph) ? graph.graph : [graph]
    nodes.each { |n| visit.(n) }
    visit.(graph)
    found
  end

  # A value with no graph objects, Procs, or files in it (one the sweep
  # can print with RubyValue alone).
  def plain?(v)
    case v
    when Array then v.all? { |x| plain?(x) }
    when Hash then v.all? { |k, x| plain?(k) && plain?(x) }
    when Range then plain?(v.begin) && plain?(v.end)
    when Proc, Module, MB::Sound::GraphNode, MB::Sound::GraphNode::Knob::Reader, MB::Sound::Generative::Value then false
    when MB::Sound::Pitch then v.constant?
    when String then false # (file names print as assets in bundles)
    else !MB::Sound::RubyValue.text(v).nil?
    end
  rescue StandardError
    false
  end
end
