# Tests for the DSL overall, including Tone, Mixer, Multiplier
RSpec.describe(MB::Sound::GraphNode, aggregate_failures: true) do
  it 'can create a complex signal graph' do
    graph = (1.hz.square.at_rate(20).at(1) - 2.hz.square.at_rate(20).at(0.5) - 5 + 3 + 2) * 0.5.hz.square.at_rate(20).at(2..1) * 3 + 1
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(2.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(5.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-3.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-0.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(4))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(10))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-8))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-2))
  end

  it 'resets default durations on tones added or multiplied to a graph' do
    graph = (100.hz.for(2) + 33.hz.or_for(0.1) + 25.hz.or_for(0.1) - 11.hz.or_for(0.1)) * 10.hz.or_for(0.1) * 15.hz.or_for(0.1) - 5.hz.or_for(0.1)

    # Expect exactly two full seconds of audio despite potentially shorter tones mixed in
    20.times do
      expect(graph.sample(4800)).to be_a(Numo::SFloat)
    end
    expect(graph.sample(4800)).to eq(nil)
  end

  it 'resets default amplitudes on tones multiplied to a graph' do
    graph = 0.hz.square.at(2) * 0.hz.square.or_at(0) * 0.hz.square.or_at(0)

    # If the amplitude was not reset this would return 0
    expect(graph.sample(100)).to eq(Numo::SFloat.zeros(100).fill(2))
  end

  describe '#tone' do
    it 'creates tones using graph nodes as frequency value' do
      ref = 1000.hz
      test = 1000.constant.tone

      expect(ref.sample(480)).to eq(test.sample(480))
    end
  end

  describe '#tee' do
    it 'returns as many branches as requested' do
      expect(1.constant.tee.count).to eq(2)
      expect(1.constant.tee(5).count).to eq(5)
    end

    it 'produces branches that yield duplicate copies of the incoming data' do
      a, b, c = 5000.hz.ramp.at(2..3).tee(3)
      expect(a.sample(1)[0].round(4)).to eq(2.5)
      expect(b.sample(1)[0].round(4)).to eq(2.5)
      expect(c.sample(1)[0].round(4)).to eq(2.5)
      expect(a.sample(1)[0].round(4)).not_to eq(2.5)
      expect(b.sample(1)[0].round(4)).not_to eq(2.5)
      expect(c.sample(1)[0].round(4)).not_to eq(2.5)
    end
  end

  pending '#get_sampler'

  describe 'proc-based arithmetic' do
    let(:nilnode) { MB::Sound::ArrayInput.new(data: Numo::SFloat[]) }
    let(:shortnode) { MB::Sound::ArrayInput.new(data: Numo::SComplex[1, 2, 3]) }
    let(:longnode) { MB::Sound::ArrayInput.new(data: Numo::DFloat[1,2,3,4,5,6,7,8,9,10]) }
    let(:emptynode) {
      nilnode.dup.tap { |n|
        allow(n).to receive(:sample).and_return(Numo::DFloat[])
      }
    }

    shared_examples_for 'an arithmetic operator' do
      it 'can operate on a graph node and a number' do
        n = 15.constant.send(operator, 5)
        expect(n.sample(10)).to eq(expected_graph_number)
      end

      it 'can operate on two graph nodes' do
        n = 15.constant.send(operator, longnode)
        expect(n.sample(10)).to eq(expected_graph_graph)
      end

      it 'can operate on a number and a graph node' do
        n = 4.send(operator, 2.constant)
        expect(n.sample(10)).to eq(expected_number_graph)
      end

      it 'returns nil for nil' do
        expect(nilnode.send(operator, shortnode).sample(3)).to eq(nil)
        expect(shortnode.send(operator, nilnode).sample(3)).to eq(nil)
      end

      it 'returns nil for empty arrays' do
        expect(emptynode.send(operator, shortnode).sample(3)).to eq(nil)
        expect(shortnode.send(operator, emptynode).sample(3)).to eq(nil)
      end

      it 'truncates short reads from self' do
        expect(shortnode.send(operator, longnode).sample(10)).to eq(expected_short_long)
      end

      it 'truncates short reads from other' do
        expect(longnode.send(operator, shortnode).sample(10)).to eq(expected_long_short)
      end
    end

    describe '#/' do
      let(:operator) { :/ }
      let(:expected_graph_number) { Numo::SFloat[*([3] * 10)] }
      let(:expected_graph_graph) { Numo::DFloat[15, 7.5, 5, 3.75, 3, 15.0 / 6, 15.0 / 7, 1.875, 15.0 / 9, 1.5] }
      let(:expected_number_graph) { Numo::SFloat[*([2] * 10)] }
      let(:expected_short_long) { Numo::SFloat[1,1,1] }
      let(:expected_long_short) { expected_short_long }

      it_behaves_like 'an arithmetic operator'
    end

    describe '#**' do
      let(:operator) { :** }
      let(:expected_graph_number) { Numo::SFloat[*([759375] * 10)] }
      let(:expected_graph_graph) { 15 ** Numo::DFloat.linspace(1, 10, 10) }
      let(:expected_number_graph) { Numo::DFloat[*([16] * 10)] }
      let(:expected_short_long) { Numo::SFloat[1, 4, 27] }
      let(:expected_long_short) { expected_short_long }

      it_behaves_like 'an arithmetic operator'
    end
  end

  describe '#log' do
    it 'takes the natural logarithm of a graph node' do
      n = Math::E.constant.log
      expect(MB::M.round(n.sample(10), 6)).to eq(Numo::SFloat.ones(10))
    end
  end

  describe '#log2' do
    it 'takes the base-2 logarithm of a graph node' do
      n = 16.constant.log2
      expect(n.sample(10)).to eq(Numo::SFloat.zeros(10).fill(4))
    end
  end

  describe '#log10' do
    it 'takes the base-10 logarithm of a graph node' do
      n = 100.constant.log10
      expect(n.sample(10)).to eq(Numo::SFloat.zeros(10).fill(2))
    end
  end

  describe '#real' do
    it 'converts complex values to real' do
      n = (5 - 3i).constant.real
      expect(n.sample(3)).to eq(Numo::SFloat[5, 5, 5])

      n = (-2 + 3i).constant.real
      expect(n.sample(3)).to eq(Numo::SFloat[-2, -2, -2])
    end

    it 'preserves real values as is' do
      n = -4.constant.real
      expect(n.sample(3)).to eq(Numo::SFloat[-4, -4, -4])
    end

    it 'returns a graph node' do
      expect(4.constant.real).to be_a(MB::Sound::GraphNode)
    end
  end

  describe '#imag' do
    it 'converts complex values to their imaginary value' do
      n = (5 - 3i).constant.imag
      expect(n.sample(3)).to eq(Numo::SFloat[-3, -3, -3])

      n = (1 + 4.25i).constant.imag
      expect(n.sample(3)).to eq(Numo::SFloat[4.25, 4.25, 4.25])
    end

    it 'turns real values into zeros' do
      n = -4.constant.imag
      expect(n.sample(3)).to eq(Numo::SFloat[0, 0, 0])
    end

    it 'returns a graph node' do
      expect(4.constant.imag).to be_a(MB::Sound::GraphNode)
    end
  end

  describe '#abs' do
    it 'converts complex values to their magnitude' do
      n = (3 - 4i).constant.abs
      expect(n.sample(3)).to eq(Numo::SFloat[5, 5, 5])

      n = (-5 + 12i).constant.abs
      expect(n.sample(3)).to eq(Numo::SFloat[13, 13, 13])
    end

    it 'takes the absolute value of real values' do
      n = -4.constant.abs
      expect(n.sample(3)).to eq(Numo::SFloat[4, 4, 4])

      n = 3.constant.abs
      expect(n.sample(3)).to eq(Numo::SFloat[3, 3, 3])
    end

    it 'returns a graph node' do
      expect(4.constant.abs).to be_a(MB::Sound::GraphNode)
    end
  end

  describe '#arg' do
    it 'converts complex values to their argument' do
      n = (1 - 1i).constant.arg
      expect(n.sample(1)).to eq(Numo::SFloat[-Math::PI / 4])

      n = (-5 + 5i).constant.arg
      expect(n.sample(2)).to eq(Numo::SFloat[Math::PI * 0.75, Math::PI * 0.75])
    end

    it 'converts the sign of real values to 0 or pi' do
      n = -4.constant.arg
      expect(n.sample(3)).to eq(Numo::SFloat[Math::PI, Math::PI, Math::PI])

      n = 3.constant.arg
      expect(n.sample(3)).to eq(Numo::SFloat[0, 0, 0])
    end

    it 'returns a graph node' do
      expect(4.constant.arg).to be_a(MB::Sound::GraphNode)
    end
  end

  context 'rounding and truncation methods' do
    let(:data) { Numo::SFloat[-1.9, -1.1, -0.7, -0.3, 0.3, 0.7, 1.1, 1.9] }
    let(:node) { MB::Sound::ArrayInput.new(data: [data]) }

    describe '#floor' do
      it 'rounds down to integers' do
        g = node.floor
        expect(g.sample(data.length)).to eq(Numo::SFloat[-2, -2, -1, -1, 0, 0, 1, 1])
      end
    end

    describe '#ceil' do
      it 'rounds up to integers' do
        g = node.ceil
        expect(g.sample(data.length)).to eq(Numo::SFloat[-1, -1, -0, -0, 1, 1, 2, 2])
      end
    end

    describe '#round' do
      it 'rounds to the nearest integer' do
        g = node.round
        expect(g.sample(data.length)).to eq(Numo::SFloat[-2, -1, -1, 0, 0, 1, 1, 2])
      end
    end
  end

  describe '#softclip' do
    it 'can apply softclipping' do
      graph = (1.hz.square.at_rate(20).at(10) + 9.75).softclip(0.5, 1)
      expect(graph.sample(10).mean).to be_between(0.5, 1.0)
      expect(graph.sample(10).mean.round(6)).to eq(-0.25)
    end
  end

  describe '#adsr' do
    it 'multiplies the node by an envelope' do
      node = 5.hz.adsr(0.5, 1, 0.25, 2)
      expect(node).to be_a(MB::Sound::GraphNode::Multiplier)
      expect(node.sources.any?(MB::Sound::ADSREnvelope)).to eq(true)

      env = node.sources.select { |s| s.is_a?(MB::Sound::ADSREnvelope) }.first
      expect(env.attack_time).to eq(0.5)
      expect(env.decay_time).to eq(1.0)
      expect(env.sustain_level).to eq(0.25)
      expect(env.release_time).to eq(2)
    end

    it 'can create a logarithmic envelope' do
      linear = 1.constant.adsr(0.5, 1, 0.25, 2)
      log = 1.constant.adsr(0.5, 1, 0.25, 2, log: -30)
      expect(log.sample(30)[-1]).to be < linear.sample(30)[-1]
    end

    it 'triggers the envelope' do
      node = 1.constant.at_rate(12345).adsr(0.00001, 0.00001, 1.0, 0.1)
      expect(node.sample(100)[-90..]).to eq(Numo::SFloat.ones(90))
      # TODO: change this from multi_sample to sample when ADSREnvelope can release mid-buffer
      expect(node.multi_sample(500, 1000)[-1]).to eq(0)
    end

    it 'copies the sample rate from the source node' do
      expect(500.hz.at_rate(12345).adsr(1, 1, 1, 1).sample_rate).to eq(12345)
    end
  end

  describe '#filter' do
    it 'can apply filtering' do
      graph = 400.hz.at(1).filter(400.hz.lowpass(quality: 5))
      expect(graph.sample(48000).max.round(6)).to eq(5)
    end

    it 'can create a dynamic filter' do
      graph = 500.hz.filter(:highpass, cutoff: MB::Sound.adsr(0.2, 0.0, 1.0, 0.75, auto_release: 0.5) * 1000 + 100, quality: MB::Sound.adsr(0.3, 0.3, 1.0, 1.0, auto_release: 0.7) * -5 + 6)

      # Ensure the correct types were created and stored
      expect(graph).to be_a(MB::Sound::Filter::Cookbook::CookbookWrapper)
      expect(graph.audio).to be_a(MB::Sound::Tone)
      expect(graph.cutoff).to be_a(MB::Sound::GraphNode::Mixer)
      expect(graph.quality).to be_a(MB::Sound::GraphNode::Mixer)

      # Ensure 500Hz tone gets quieter as filter frequency rises
      attack = graph.sample(2000).abs.max
      graph.sample(14000)
      sustain = graph.sample(10000).abs.max
      expect(sustain).to be < (0.25 * attack)

      # Expect tone to get louder as frequency falls again
      graph.sample(12000)
      release = graph.sample(2000).abs.max
      expect(release).to be > (1.5 * sustain)
    end
  end

  describe '#hilbert_iir' do
    it 'removes negative frequencies' do
      # Validation of indices for positive and negative frequencies
      data = MB::Sound.fft(3200.hz.at(1).sample(48000))
      expect(data[3200].abs).to be > -0.5.dB
      expect(data[-3200].abs).to be > -0.5.dB

      # Validation of suppressed negative frequency
      data = MB::Sound.fft(3200.hz.at(1).hilbert_iir.sample(48000))
      expect(data[3200].abs).to be > -0.5.dB
      expect(data[-3200].abs).to be < -40.dB
    end
  end

  describe '#named?' do
    it 'returns false before and true after a node is given a name' do
      n = 50.hz.proc {}
      expect(n.graph_node_name).not_to be_nil # make sure named? and graph_node_name are independent
      expect(n.named?).to eq(false)
      n.named('test')
      expect(n.named?).to eq(true)
      expect(n.graph_node_name).to eq('test')
    end
  end

  describe '#clip' do
    # FIXME: the first sample is repeated without the with_phase option
    let(:cliposc) { 24000.hz.square.at(10).with_phase(0.0000001) }

    it 'can clip values to a range' do
      expect(cliposc.sample(4)).to eq(Numo::SFloat[10, -10, 10, -10])

      n = cliposc.clip(-4.5, 2.5)
      expect(n.sample(4)).to eq(Numo::SFloat[2.5, -4.5, 2.5, -4.5])
    end

    it 'can clip without a lower bound' do
      n = cliposc.clip(nil, 2.5)
      expect(n.sample(4)).to eq(Numo::SFloat[2.5, -10, 2.5, -10])
    end

    it 'can clip without an upper bound' do
      n = cliposc.clip(0.5, nil)
      expect(n.sample(4)).to eq(Numo::SFloat[10, 0.5, 10, 0.5])
    end
  end

  pending '#smooth'
  pending '#clip_rate'
  pending '#multitap'

  describe '#coerce' do
    it 'allows signal nodes to be preceded by numeric values in multiplication' do
      expect(5 * 5.constant).to be_a(MB::Sound::GraphNode::Multiplier)
    end

    it 'allows signal nodes to be preceded by numeric values in addition' do
      expect(5 + 5.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end

    it 'allows signal nodes to be preceded by numeric values in subtraction' do
      expect(5 - 5.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end
  end

  describe '#proc' do
    it 'can apply Ruby code within a signal chain' do
      graph = 0.hz.square.at(1).proc { |buf| buf * 3 }
      expect(graph.sample(10)).to eq(Numo::SFloat.new(10).fill(3))
    end

    it 'copies the source sample rate' do
      expect(1.hz.at_rate(51234).proc{}.sample_rate).to eq(51234)
    end
  end

  describe '#and_then' do
    pending 'with full-sized buffers followed by nil'
    pending 'with a short read'
  end

  describe '#multi_sample' do
    it 'does the same thing as sample if times is 1' do
      expect(123.hz.multi_sample(17, 1)).to eq(123.hz.sample(17))
    end

    it 'gives the same concatenated result as a single large sample' do
      expect(637.hz.multi_sample(5, 7)).to eq(637.hz.sample(35))
    end

    it 'raises an error if count or times are zero' do
      expect { 123.hz.multi_sample(0, 1) }.to raise_error(/Count.*positive/)
      expect { 123.hz.multi_sample(1, 0) }.to raise_error(/Times.*positive/)
    end

    it 'returns nil at end of stream' do
      expect(123.hz.for(0).multi_sample(100, 1)).to eq(nil)
    end

    it 'handles end of stream part way through concatenation' do
      result = 123.hz.for(5.0 / 48000).multi_sample(2, 10)
      expect(result.length).to eq(5)
    end
  end

  describe '#resample' do
    it 'appends a resample node' do
      expect(1.hz.resample(12000)).to be_a(MB::Sound::GraphNode::Resample)
    end

    it 'can change the resampling mode' do
      expect(1.hz.resample(15000, mode: :ruby_linear).mode).to eq(:ruby_linear)
    end

    it 'defaults to the current frequency' do
      expect(1.hz.at_rate(1515).resample.sample_rate).to eq(1515)
    end

    it 'allows changing the downstream rate later' do
      a = 1.hz.at_rate(1515)
      b = a.resample

      b.sample_rate = 5432

      expect(a.sample_rate).to eq(1515)
      expect(b.sample_rate).to eq(5432)
    end
  end

  describe '#oversample' do
    it 'changes the upstream sample rate without changing the output rate' do
      a = 15.hz.at_rate(48000)

      b = nil
      expect { b = a.oversample(4) }.to change { a.sample_rate }.to(192000)

      expect(b).to be_a(MB::Sound::GraphNode::Resample)
      expect(b.sample_rate).to eq(48000)
    end

    it 'can change the resampling mode' do
      expect(15.hz.oversample(4).mode).to eq(:libsamplerate_best)
      expect(15.hz.oversample(4, mode: :ruby_linear).mode).to eq(:ruby_linear)
    end
  end

  describe '#spy' do
    it 'calls a block when the sample method is called' do
      b = nil
      p = ->(buf) { b = buf.dup }

      ref = 456.hz.spy(&p).sample(100)
      expect(ref.abs.max).not_to eq(0)
      expect(b).not_to equal(ref)
      expect(b).to eq(ref)
    end

    it 'can call multiple blocks' do
      b = nil
      p = ->(buf) { b = buf.dup }

      absmax = nil
      p2 = ->(buf) { absmax = buf.abs.max }

      ref = 456.hz.spy(&p).spy(&p2).sample(100)
      expect(ref.abs.max).not_to eq(0)
      expect(b).not_to equal(ref)
      expect(b).to eq(ref)
      expect(absmax).to eq(ref.abs.max)
    end
  end

  describe '#clear_spies' do
    it 'does nothing if there are no spies' do
      expect(0.hz.clear_spies.sample(5)).to eq(Numo::SFloat.zeros(5))
    end

    it 'removes active spies' do
      b = nil
      p = ->(buf) { b = buf.dup }

      456.hz.spy(&p).clear_spies.sample(100)
      expect(b).to eq(nil)
    end
  end

  pending '#forever'

  pending '#for'

  context 'implementations' do
    context 'provide a sample_rate' do
      ObjectSpace.each_object.select { |o| o.is_a?(Class) && o.ancestors.include?(MB::Sound::GraphNode) }.each do |cl|
        example "#{cl.name} defines #sample_rate" do
          expect(cl.public_instance_methods).to include(:sample_rate)
        end
      end
    end
  end

  describe '#graph' do
    it 'returns an ordered list of nodes in a graph without duplicates' do
      a = 50.hz.ramp.named('a')
      b = 3.hz.at(120..650).named('b')
      # FIXME: both d and c refer to b, but this will lead to repeated
      # sampling.  Can this be prevented?  Either a graph would need a
      # container to keep track of nodes, or nodes would need to be notified
      # when they are connected, or the sample method would need to validate
      # the graph once before playback.  But then Tee allows duplication, so
      # then somehow a directly teed node can be allowed N times?
      # Could add a method that generates a new Tee that all downstream nodes
      # will use when referencing upstream nodes.
      c = (b * 0.01).named('c')
      d = a.filter(:lowpass, cutoff: b, quality: c).named('d')
      e = (d * 3).named('e')

      expected = [
        e,
        d,
        a,
        c,
        50,
        3,
        b,
        0.01,
      ]

      expect(e.graph).to eq(expected)
    end

    it 'does not get lost in feedback loops' do
      a = 10.hz.named('a')
      b = 20.hz.named('b')
      c = 30.hz.named('c')

      expect(a).to receive(:sources).exactly(3).times.and_return([c])
      expect(b).to receive(:sources).exactly(3).times.and_return([a])
      expect(c).to receive(:sources).exactly(3).times.and_return([b])

      expect(a.graph).to eq([c, b, a])
      expect(b.graph).to eq([a, c, b])
      expect(c.graph).to eq([b, a, c])
    end
  end
end
