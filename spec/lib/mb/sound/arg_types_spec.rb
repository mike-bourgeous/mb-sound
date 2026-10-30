RSpec.describe(MB::Sound::ArgTypes) do
  describe '.classify' do
    it 'names the type of each kind of value' do
      expect(described_class.classify(138.75.bpm)).to eq(:tempo)
      expect(described_class.classify(5/4r)).to eq(:ratio)
      expect(described_class.classify(19.7.seconds)).to eq(:seconds)
      expect(described_class.classify(480.samples)).to eq(:samples)
      expect(described_class.classify(2.bars)).to eq(:duration)
      expect(described_class.classify(-6.db)).to eq(:decibels)
      expect(described_class.classify(7.semitones)).to eq(:interval)
      expect(described_class.classify(0.25.cycles)).to eq(:phase)
      expect(described_class.classify(MB::Sound::Curve[:smooth])).to eq(:curve)
      expect(described_class.classify(220.hz)).to eq(:frequency)
      expect(described_class.classify(MB::Sound::A4)).to eq(:frequency)
      expect(described_class.classify(MB::Sound.seq(MB::Sound::C4).n4)).to eq(:notes)
      expect(described_class.classify(:tide)).to eq(:name)
      expect(described_class.classify(2)).to eq(:number)
      expect(described_class.classify(0.5)).to eq(:number)
      expect(described_class.classify(0.5.constant)).to eq(:node)
    end

    it 'tags frequency nodes (v.freq, node.freq) without changing them' do
      clip = MB::Sound.seq(MB::Sound::C4).n4.loop
      expect(described_class.classify(clip.notes.freq)).to eq(:frequency)
      n = 60.constant
      ivars = n.instance_variables
      f = n.freq
      expect(described_class.classify(f)).to eq(:frequency)
      expect(n.instance_variables).to eq(ivars)
      expect(described_class.classify(60.constant)).to eq(:node)
    end
  end

  describe MB::Sound::ArgTypes::Signature do
    # A toolkit-style method: a frequency and a partial count, any order
    let(:sig) {
      described_class.new(:peqish, receiver: 'a node', params: [
        MB::Sound::ArgTypes::Param.new(name: :preset, primary: true, types: { name: 'a preset' }),
        MB::Sound::ArgTypes::Param.new(name: :root, types: { frequency: 'the root' }, default: 220.hz),
        MB::Sound::ArgTypes::Param.new(name: :decay, types: { seconds: 'ring time', number: 'seconds' }, default: 1),
        MB::Sound::ArgTypes::Param.new(name: :q, types: { number: 'quality' }, default: 4),
      ])
    }

    it 'places typed values by type in any order, untyped ones by position' do
      expect(sig.bind([3.seconds, 330.hz, :bowl]).transform_values(&:to_s)).to eq(preset: 'bowl', root: 330.hz.to_s, decay: 3.seconds.to_s)
      expect(sig.bind([:bowl, 2, 8])).to eq(preset: :bowl, decay: 2, q: 8)
    end

    it 'gives keywords precedence over type and position' do
      expect(sig.bind([8], q: 2)).to eq(q: 2, decay: 8)
      expect(sig.bind([], decay: 5, other: 1)).to eq(decay: 5, rest: { other: 1 })
    end

    it 'raises for a typed value no parameter takes, listing the table' do
      expect { sig.bind([-6.db]) }.to raise_error(MB::Sound::ArgTypes::ArgumentTypeError, /doesn't take a level in dB.*root:/m)
    end

    it 'raises for a typed value two open parameters take, suggesting keywords' do
      two = described_class.new(:x, receiver: 'a node', params: [
        MB::Sound::ArgTypes::Param.new(name: :a, types: { seconds: 'one' }),
        MB::Sound::ArgTypes::Param.new(name: :b, types: { seconds: 'two' }),
      ])
      expect { two.bind([1.seconds]) }.to raise_error(MB::Sound::ArgTypes::ArgumentTypeError, /say which with a keyword.*a: 1.0 s|Did you mean\?/m)
      expect(two.bind([1.seconds], b: 2.seconds)).to eq(a: 1.seconds, b: 2.seconds)
    end

    it 'prints canonical forms: the primary positional, others as keywords in declared order, defaults left out' do
      pos, kw = sig.canonical(preset: :bowl, q: 8, root: 330.hz, decay: 1)
      expect(pos).to eq([:bowl])
      expect(kw.keys).to eq([:root, :q])
      expect(kw[:q]).to eq(8)
    end
  end

  describe 'the declared dispatch tables (guard)' do
    # One example value per type (the guard calls every row with it)
    EXAMPLES = {
      tempo: 138.75.bpm, ratio: 5/4r, seconds: 1.5.seconds, samples: 480.samples, duration: 1.n4,
      decibels: -6.db, interval: 7.semitones, phase: 0.25.cycles, name: :guard_clock,
    }.freeze

    let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false) }
    after { session.close }

    def receiver_for(kind)
      case kind
      when :clip then MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.loop
      when :sample then MB::Sound::Sample[Numo::SFloat.new(4800).seq / 4800, bpm: 120]
      end
    end

    it 'covers every receiver and method this branch declares' do
      keys = MB::Sound::ArgTypes::REGISTRY.keys
      expect(keys).to include([:clip, :clocked], [:clip, :at], [:clip, :over], [:clip, :%], [:sample, :clocked], [:sample, :at], [:sample, :over], [:sample, :%])
    end

    it 'routes every row to its canonical method, which graphs print' do
      MB::Sound::Session.with_context(session: session) do
        session.define_clock(:guard_clock, 2.seconds)
        MB::Sound::ArgTypes::REGISTRY.each do |(kind, name), table|
          next unless table.is_a?(MB::Sound::ArgTypes::Dispatch)
          table.rows.each do |type, (method, _meaning)|
            value = EXAMPLES.fetch(type)
            r = receiver_for(kind)
            expect(method).to eq(:clocked)
            out = name == :% ? r % value : r.public_send(name, value)
            want = r.public_send(method, value)
            expect(out.class).to eq(want.class), "#{kind}##{name}(#{type})"
            expect(out.clocking).to eq(want.clocking), "#{kind}##{name}(#{type})"
          end
        end
      end
    end

    it 'raises with the table for plain numbers on clips, suggesting spellings' do
      clip = receiver_for(:clip)
      expect { clip.at(2) }.to raise_error(MB::Sound::ArgTypes::ArgumentTypeError, /by type it means.*\.at\(2\.bpm\).*\.at\(2\.seconds\)/m)
      expect { clip.over(138.bpm) }.to raise_error(MB::Sound::ArgTypes::ArgumentTypeError, /#over doesn't take a tempo/)
      expect { clip % 3 }.to raise_error(MB::Sound::ArgTypes::ArgumentTypeError, /% 3\.seconds/)
    end

    it 'keeps Sample#at offsets for lengths and numbers' do
      s = receiver_for(:sample)
      expect(s.at(100).length).to eq(4700)
      expect(s.at(0.05.seconds).length).to eq(4800 - 2400)
      expect(s.at(138.75.bpm)).to be_a(MB::Sound::GraphNode::LoopPlayer)
    end

    it 'prints every preposition as clocked' do
      clip = receiver_for(:clip)
      [clip % 1.5.seconds, clip.at(5/4r), clip.over(1.5.seconds), clip.clock(138.75.bpm), clip.clocked_at(:tide)].each do |c|
        expect(c.notes.gate.to_ruby).to match(/\.clocked\((1\.5\.seconds|5\/4r|138\.75\.bpm|:tide)\)\.notes\.gate/)
      end
    end
  end
end
