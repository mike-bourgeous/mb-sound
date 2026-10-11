# Helpers for graph-io recipe specs (GraphNode#to_ruby round trips).
module RecipeHelpers
  # Evaluates Ruby printed by #to_ruby in the MB::Sound context (as the
  # console would), with +inputs+ as local variables.
  def self.eval_recipe(code, inputs = {})
    b = MB::Sound.module_eval('binding', __FILE__, __LINE__)
    inputs.each { |k, v| b.local_variable_set(k, v) }
    b.eval(code, '(to_ruby)')
  end

  # Samples every output of +graph+ in turn; returns one SFloat (real part)
  # per output.
  def self.render(graph, buffers: 60, size: 512)
    outs = graph.respond_to?(:outputs) ? graph.outputs.to_a : graph.to_a
    bufs = outs.map { [] }
    buffers.times do
      done = false
      outs.each_with_index do |o, i|
        b = o.sample(size)
        if b.nil?
          done = true
          next
        end
        b = b.real if b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex)
        bufs[i] << Numo::DFloat.cast(b)
      end
      break if done
    end
    bufs.map { |b| b.empty? ? Numo::DFloat[] : Numo::DFloat.zeros(0).concatenate(*b) }
  end

  # The largest absolute difference between two renders (Infinity if their
  # lengths differ).
  def self.max_diff(a, b)
    return Float::INFINITY if a.length != b.length || a.zip(b).any? { |x, y| x.length != y.length }
    a.zip(b).map { |x, y| x.length == 0 ? 0 : (x - y).abs.max }.max || 0
  end
end
