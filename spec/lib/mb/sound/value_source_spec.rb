# Values that move (knobs-1): one coercer for "a number, a knob name, a
# knob, or a node" and one value_at protocol for every reader (turns,
# sends, scene values, rack control ports, document params, clock speeds,
# followed tempos, MIDI params).
RSpec.describe(MB::Sound::ValueSource, :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: :virtual), realtime: false) }
  after { session.close }

  describe '.coerce' do
    before { session.knob(:cut, 800.0, range: 100.0..8000.0, curve: :exp) }

    it 'takes numbers, knob names, knobs, and nodes per sample' do
      expect(described_class.coerce(2, 'x')).to eq(2)
      expect(described_class.coerce(:cut, 'x', names: :check, knobs: session)).to eq(:cut)
      expect(described_class.coerce(:cut, 'x', names: :knob, knobs: session)).to equal(session.knobs[:cut])
      k = session.knobs[:cut]
      expect(described_class.coerce(k, 'x')).to equal(k)
      r = k.get_sampler
      expect(described_class.coerce(r, 'x')).to equal(r)
      sine = 3.hz.sine
      expect(described_class.coerce(sine, 'x')).to equal(sine)
      bundle = MB::Sound::GraphNode::Channels.new([1.constant, 2.constant])
      expect(described_class.coerce(bundle, 'x', channels: true)).to equal(bundle)
    end

    it 'checks numbers and names, saying what it takes' do
      expect { described_class.coerce(Float::NAN, 'turn :cut') }.to raise_error(ArgumentError, /turn :cut takes a real, finite number/)
      expect { described_class.coerce(5, 'A send level', numbers: 0..4, number_hint: 'is a gain from 0 to 4') }
        .to raise_error(ArgumentError, /A send level is a gain from 0 to 4 \(got 5\)/)
      expect { described_class.coerce(:cutt, 'turn :x', names: :check, knobs: session) }.to raise_error(ArgumentError, /turn :x: No knob :cutt.*Did you mean\?.*:cut/m)
      expect { described_class.coerce(:cut, 'param x', names: :knob) }.to raise_error(ArgumentError, /names knob :cut, but there is no Session/)
      expect { described_class.coerce(nil, 'turn :cut') }.to raise_error(ArgumentError, /turn :cut takes a number, a knob name, knob\(:x\), or a node \(got nil\)/)
      expect { described_class.coerce(2, 'bpm', numbers: false) }.to raise_error(ArgumentError, /bpm takes a knob name, knob\(:x\), or a node/)
    end

    it 'reads decision-time values through MIDI::Param.wrap' do
      lfo = described_class.coerce(4.bars.lfo.at(0.5..2), 'A clock speed', read: :decision)
      expect(lfo).to be_a(MB::Sound::MIDI::Param::Graph)
      clip = described_class.coerce(MB::Sound.seq(0, 2).n1.loop, 'x', read: :decision)
      expect(clip).to be_a(MB::Sound::MIDI::Param::ClipValue)
      expect { described_class.coerce(440.hz.saw, 'bpm', read: :decision) }.to raise_error(MB::Sound::MIDI::Param::NotAParam)
    end
  end

  describe '.value_at' do
    it 'reads every moving value through one signature' do
      k = session.knob(:spd, 0.5)
      expect(described_class.value_at(0.25, 1r)).to eq(0.25)
      expect(described_class.value_at(:lydian, 1r)).to eq(:lydian) # (Symbols are values without knobs:)
      expect(described_class.value_at(:spd, 0r, frame: session.frame, knobs: session)).to eq(0.5)
      expect(described_class.value_at(k.get_sampler, 0r, frame: session.frame)).to eq(0.5)
      expect(described_class.value_at(MB::Sound.seq(3, 5).n1.loop, 1r)).to eq(5)
      expect(described_class.value_at(described_class.coerce(k * 2, 'x', read: :decision), 0r, frame: session.frame)).to eq(1.0)
      k.set(0.75, frame: k.next_frame, smooth: 0)
      session.process_buffer
      expect(described_class.value_at(k, 0r, now: true)).to eq(0.75)
    end
  end
end
