RSpec.describe(MB::Sound::GraphNode::Reverb) do
  it 'has feedback sources if show_internals is true' do
    # Using fewer channels and stages to reduce the exponential path explosion that causes warnings about infinite loops
    expect(100.hz.reverb(channels: 2, stages: 1, show_internals: true).graph_edges(feedback: true)).not_to be_empty
  end

  it 'does not have feedback sources if show_internals is false' do
    expect(100.hz.reverb.graph_edges(feedback: true)).to be_empty
  end

  describe 'fused network' do
    def render(preset, inputs:, outputs:, show_internals:, buffers: 60, **params)
      srcs = Array.new(inputs) { |i| (113 + 71 * i).hz.ramp.at(0.5) * (0.7 + i).hz.lfo.at(0..1) }
      rev = MB::Sound::GraphNode::Reverb.reverb(preset, input: srcs, output_channels: outputs, show_internals: show_internals, **params)
      outs = outputs > 1 ? rev.to_a : [rev]
      Array.new(buffers) { outs.map { |o| o.sample(800).dup } }
    end

    [
      [:hall, 1, 1, {}],
      [:space, 2, 2, { predelay: 0.02 }],
      [:default, 3, 5, {}],
      [:room, 1, 2, { feedback_enabled: false }],
      [:hall, 2, 1, { stages: 0 }],
    ].each do |preset, inputs, outputs, params|
      it "sounds identical to the node graph for #{preset} with #{inputs} in, #{outputs} out, #{params}" do
        fused = render(preset, inputs: inputs, outputs: outputs, show_internals: false, **params)
        graph = render(preset, inputs: inputs, outputs: outputs, show_internals: true, **params)
        expect(fused).to eq(graph)
      end
    end

    it 'has a reverb tail' do
      dry = render(:hall, inputs: 1, outputs: 1, show_internals: false, wet: 0).flatten
      wet = render(:hall, inputs: 1, outputs: 1, show_internals: false).flatten
      expect(wet.zip(dry).map { |w, d| (w - d).abs.max }.max).to be > 0.01
    end

    it 'returns nil when its input ends' do
      rev = MB::Sound.silence(0.05).and_then(MB::Sound.silence(0)).reverb(:hall, extra_time: 0)
      expect(Array.new(10) { rev.sample(800) }.last).to be_nil
    end
  end
end
