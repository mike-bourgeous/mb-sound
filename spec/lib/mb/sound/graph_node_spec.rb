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

  describe '#as_input' do
    # More tests in the GraphNodeInput and GraphNodeArrayMixin specs
    it 'wraps a graph in an Input with a #read method' do
      inp = 1.constant.as_input(buffer_size: 348)
      expect(inp).to respond_to(:read)
      expect(inp.buffer_size).to eq(348)
      expect(inp.read(12)).to eq([Numo::SFloat.ones(12)])
    end

    it 'can duplicate node output to fill a given number of channels' do
      inp = 1.constant.as_input(2, buffer_size: 348)
      expect(inp).to respond_to(:read)
      expect(inp.buffer_size).to eq(348)
      expect(inp.read(12)).to eq([Numo::SFloat.ones(12)] * 2)
    end
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

  describe '#+' do
    it 'returns a mixer' do
      expect(1.constant + 2.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end

    it 'can add two elements' do
      m = 1.constant + 2i.constant
      expect(m.sample(3)).to eq(Numo::SComplex[1+2i,1+2i,1+2i])
    end

    it 'can add the same element to itself' do
      a = 1.constant
      m = a + a
      expect(m[a]).to eq(2)
      expect(m.sample(3)).to eq(Numo::SFloat[2,2,2])
    end

    it 'can add an element repeatedly' do
      a = 1.constant
      m = a + a + a
      expect(m[a]).to eq(1)
      expect(m.sample(3)).to eq(Numo::SFloat[3,3,3])
    end
  end

  describe '#-' do
    it 'returns a mixer' do
      expect(1.constant - 2.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end

    it 'can subtract the same element from itself' do
      a = 1.constant
      m = a - a
      expect(m[a]).to eq(0)
      expect(m.sample(3)).to eq(Numo::SFloat.zeros(3))
    end

    it 'can subtract an element repeatedly' do
      a = 1.constant
      m = a - a - a
      expect(m[a]).to eq(-1)
      expect(m.sample(3)).to eq(Numo::SFloat[-1,-1,-1])
    end
  end

  describe '#*' do
    let(:a) { 15.constant.at_rate(1234) }
    let(:b) { 25.constant.at_rate(2345) }
    let(:c) { 35.constant.at_rate(5432) }

    it 'creates a multiplier' do
      expect(1.constant * 2.constant).to be_a(MB::Sound::GraphNode::Multiplier)
    end

    it 'can multiply two inputs' do
      m = 2.constant * 3.constant
      expect(m.sample(2)).to eq(Numo::SFloat[6,6])
    end

    it 'can multiply more nodes without messing up prior nodes' do
      m = 2.constant * 3.constant
      m2 = m * -1.constant

      expect(m.sample(2)).to eq(Numo::SFloat[6,6])
      expect(m2.sample(2)).to eq(Numo::SFloat[-6,-6])
    end

    it 'can multiply a node by itself' do
      a = 2.constant
      m = a * a
      expect(m.sample(2)).to eq(Numo::SFloat[4,4])
    end

    it 'changes sample rates to match' do
      m = MB::Sound::GraphNode::Multiplier.new(a, b) * c

      expect(m.sample_rate).to eq(1234)
      expect(a.sample_rate).to eq(1234)
      expect(b.sample_rate).to eq(1234)
      expect(c.sample_rate).to eq(1234)
    end
  end

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
      expect(node.graph.any?(MB::Sound::ADSREnvelope)).to eq(true)

      env = node.graph.select { |s| s.is_a?(MB::Sound::ADSREnvelope) }.first
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
      expect(graph).to be_a(MB::Sound::Filter::SampleWrapper)
      expect(graph.sources[:input].original_source).to be_a(MB::Sound::Tone)
      expect(graph.sources[:cutoff].original_source).to be_a(MB::Sound::GraphNode::Mixer)
      expect(graph.sources[:quality].original_source).to be_a(MB::Sound::GraphNode::Mixer)

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

  pending '#peq'
  pending '#peq_series'
  pending '#bandpass_series'

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
  pending '#delay'
  pending '#reverb'

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

    context 'with handled spies' do
      let(:b1) { [] }
      let(:b2) { [] }
      let(:sp1) { ->(buf) { b1 << buf.dup } }
      let(:sp2) { ->(buf) { b2 << buf.dup } }
      let(:graph) { 1i.constant.spy(handle: :a, &sp1).spy(handle: :b, &sp2) }
      let(:more_spies) { graph.spy(handle: :a, &sp2) }

      it 'can notify spies with different handles' do
        expect { graph.sample(5) }.to change { b1.count }.by(1).and change { b2.count }.by(1)
      end

      it 'can notify longer lists of spies' do
        expect { more_spies.sample(5) }.to change { b1.count }.by(1).and change { b2.count }.by(2)
      end
    end

    context 'with an interval' do
      it 'calls the spy once, then waits for the interval to pass' do
        # Time.now is called once for :pre spies and once for :post spies so double the numbers
        expect(Time).to receive(:now).and_return(0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6)

        spycount = 0

        # Time.now == 0 ; last_time == -5
        node = 5.constant.spy(interval: 5) { spycount += 1 }

        # Time.now == 1 ; last_time == 1
        expect { node.sample(10) }.to change { spycount }.by(1)

        # Time.now == 2..5
        4.times do
          expect { node.sample(10) }.not_to change { spycount }
        end

        # Time.now == 6
        expect { node.sample(10) }.to change { spycount }.by(1)
      end
    end

    context 'with phase' do
      it 'calls a :pre spy with the sample count' do
        spyval = nil
        node = 42.constant.spy(phase: :pre) { |c| spyval = c }

        expect { node.sample(13) }.to change { spyval }.to(13)
      end
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

    context 'with handled spies' do
      let(:b1) { [] }
      let(:b2) { [] }
      let(:sp1) { ->(buf) { b1 << buf.dup } }
      let(:sp2) { ->(buf) { b2 << buf.dup } }
      let(:graph) { 42.constant.spy(handle: :a, &sp1).spy(handle: :b, &sp2) }

      it 'can remove spies with a specific handle' do
        graph.clear_spies(handle: :a)
        expect { graph.sample(10) }.to change { b2.count }.by(1).and(not_change { b1.count })
        expect(b1).to eq([])
        expect(b2).to eq([Numo::SFloat.zeros(10).fill(42)])
      end

      it 'can remove all handled spies' do
        graph.clear_spies
        expect { graph.sample(10) }.to not_change { b2.count }.and(not_change { b1.count })
        expect(b1).to eq([])
        expect(b2).to eq([])
      end
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

    context 'with #arithmetic_string' do
      it 'can return a coalesced mathematical statement' do
        q = ((1.constant + 3 + 5 + 7) * 11) / 13
        expect(q.arithmetic_string).to eq("(11 * (((1 + 3) + 5) + 7)) / 13")
      end

      pending 'unary functions when implemented'
    end
  end

  context 'graph introspection' do
    let(:a) { 50.hz.ramp.named('a') }
    let(:b) { 3.hz.at(120..650).named('b') }
    let(:c) { (b * 0.01).named('c') }
    let(:d) { a.filter(:lowpass, cutoff: b, quality: c).named('d') }
    let(:e) { (d * 3).named('e') }

    describe '#graph' do
      it 'returns an ordered list of nodes in a graph without duplicates' do
        expected = [
          e,
          d,
          a,
          c,
          50,
          0.01,
          b,
          3,
          0,
        ]

        result = e.graph(include_tees: false)

        expect(result.length).to eq(expected.length)
        expect(result).to eq(expected)
      end

      it 'does not get lost in feedback loops' do
        n1 = 10.hz.named('1')
        n2 = 20.hz.named('2')
        n3 = 30.hz.named('3')

        expect(n1).to receive(:sources).at_least(3).times.and_return({input: n3})
        expect(n2).to receive(:sources).at_least(3).times.and_return({input: n1})
        expect(n3).to receive(:sources).at_least(3).times.and_return({input: n2})

        expect(n1.graph[0]).to equal(n3)
        expect(n1.graph.map(&:to_s)).to eq([n3, n2, n1].map(&:to_s))
        expect(n2.graph.map(&:to_s)).to eq([n1, n3, n2].map(&:to_s))
        expect(n3.graph.map(&:to_s)).to eq([n2, n1, n3].map(&:to_s))
      end

      pending 'when include_tees is true'
    end

    describe '#graph_edges' do
      it 'returns constant value connections for a single node' do
        expect(a.graph_edges).to eq({ 50 => Set.new([[a, :frequency]]), 0 => Set.new([[a, :phase]]) })
      end

      it 'returns connections for a simple graph' do
        expected = {
          0.01 => Set.new([[c, :constant]]),
          3 => Set.new([[b, :frequency]]),
          0 => Set.new([[b, :phase]]),
          b => Set.new([[c, :input_1]]),
        }
        expect(c.graph_edges(include_tees: false)).to eq(expected)
      end

      it 'returns connections for a more complex graph' do
        expected = {
          0 => Set.new([[a, :phase], [b, :phase]]),
          50 => Set.new([[a, :frequency]]),
          a => Set.new([[d, :input]]),
          3 => Set.new([[b, :frequency], [e, :constant]]),
          b => Set.new([[c, :input_1], [d, :cutoff]]),
          0.01 => Set.new([[c, :constant]]),
          c => Set.new([[d, :quality]]),
          d => Set.new([[e, :input_1]]),
        }
        expect(e.graph_edges(include_tees: false)).to eq(expected)
      end

      pending 'when include_tees is true'
    end

    describe '#graph_ranks' do
      it 'returns expected ordering for a simple graph' do
        a = 300.hz
        m = a.adsr(0.1, 0.1, 0.6, 0.5)
        b = m.multiplicands[1]
        c = 100.hz.fm(m)
        d = c.filter(:lowpass, cutoff: 5)

        ranks = d.graph_ranks(include_tees: false)

        expect(ranks[0]).to match_array([a, b])
        expect(ranks[1]).to match_array([m])
        expect(ranks[2]).to match_array([be_a(MB::Sound::GraphNode::Mixer)])
        expect(ranks[3]).to match_array([c, be_a(MB::Sound::GraphNode::Constant), be_a(MB::Sound::GraphNode::Constant)])
        expect(ranks[4]).to match_array([d])
      end
    end

    describe '#graphviz' do
      pending

      it 'can include feedback edges' do
        a = Numo::SFloat.zeros(100)

        g1 = 100.hz.proc { |v| v + a }
        g2 = g1.delay(seconds: 0.1).proc { |v| a[] = v }

        g1.with_feedback({ feedback_spec: g2 })

        expect(g2.graphviz).to match(/feedback_spec.*constraint/)
      end
    end
  end
end
