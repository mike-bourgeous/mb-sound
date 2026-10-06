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

    # The feedback network used to feed back the previous block, so the
    # loop delays were the line delays plus the caller's buffer size and
    # the sound changed with the buffer size (RT60 of :room 0.11 s at
    # 128-sample buffers, 0.23 s at 800).  Now the loops are the line
    # delays plus FEEDBACK_BLOCK at every buffer size.
    describe 'buffer size independence' do
      # Renders 0.5 s of an impulse through +preset+ (wet only) in +block+
      # sample reads.
      def impulse(preset, block, show_internals: false, outputs: 1, total: 24000)
        imp = Numo::SFloat.zeros(total)
        imp[0] = 1
        src = MB::Sound::ArrayInput.new(data: [imp])
        rev = MB::Sound::GraphNode::Reverb.reverb(preset, input: src, output_channels: outputs, dry: 0, extra_time: 0, show_internals: show_internals)
        outs = outputs > 1 ? rev.to_a : [rev]
        bufs = []
        done = 0
        while done < total
          n = [block, total - done].min
          bufs << outs.map { |o| o.sample(n).dup }
          done += n
        end
        bufs.transpose.map { |c| c[0].concatenate(*c[1..]) }
      end

      [:room, :hall, :space].each do |preset|
        it "gives identical samples at every buffer size for #{preset}" do
          ref = impulse(preset, 1024)
          expect(ref[0].abs.max).to be > 0.001
          [32, 128, 333, 800, 1].each do |block|
            next if block == 1 && preset != :room

            expect(impulse(preset, block)).to eq(ref), "buffer size #{block} differs"
          end
        end
      end

      it 'runs buffers longer than the shortest loop in pieces, with the same samples' do
        rev = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(10)]).reverb(:room)
        limit = rev.feedback_delays.min
        expect(limit).to be_between(1024, 1024 + 0.016 * 48000)
        expect(impulse(:room, limit + 1, outputs: 2)).to eq(impulse(:room, 128, outputs: 2))
        expect(impulse(:room, 24000)).to eq(impulse(:room, 128))
      end

      it 'gives the node graph (show_internals) the same samples at any buffer size' do
        ref = impulse(:hall, 1024)
        expect(impulse(:hall, 333, show_internals: true)).to eq(ref)
        expect(impulse(:hall, 6000, show_internals: true)).to eq(ref)
      end

      it 'keeps the loop time in seconds at other sample rates' do
        rev = 100.hz.ramp.reverb(:room)
        at48 = rev.feedback_delays
        rev.sample_rate = 96000
        expect(rev.feedback_delays.zip(at48).map { |a, b| a - 2 * b }).to all(be_between(-1, 1))
      end
    end

    it 'returns nil when its input ends' do
      rev = MB::Sound.silence(0.05).and_then(MB::Sound.silence(0)).reverb(:hall, extra_time: 0)
      expect(Array.new(10) { rev.sample(800) }.last).to be_nil
    end
  end
end
