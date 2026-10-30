RSpec.describe(MB::Sound::Sequence::Duration) do
  describe '.whole_notes' do
    it 'treats Integers as note divisions' do
      expect(described_class.whole_notes(4)).to eq(1/4r)
      expect(described_class.whole_notes(6)).to eq(1/6r)
    end

    it 'treats Rationals as fractions of a whole note' do
      expect(described_class.whole_notes(3/8r)).to eq(3/8r)
    end

    it 'converts Floats to exact Rationals' do
      expect(described_class.whole_notes(0.375)).to eq(3/8r)
    end

    it 'rejects zero, negative, and non-numeric durations' do
      [0, -4, 0r, -0.5, Float::INFINITY, '4', nil].each do |d|
        expect { described_class.whole_notes(d) }.to raise_error(ArgumentError), "expected #{d.inspect} to be rejected"
      end
    end
  end

  describe '.rational' do
    it 'converts Floats to the simplest nearby Rational and leaves other numbers exact' do
      expect(described_class.rational(0.85)).to eq(17/20r)
      expect(described_class.rational(0.1)).to eq(1/10r)
      expect(described_class.rational(3)).to eq(3r)
      expect(described_class.rational(3/7r)).to eq(3/7r)
    end
  end

  describe '.format' do
    it 'formats unit fractions as note divisions' do
      expect(described_class.format(1/16r)).to eq('n16')
      expect(described_class.format(3/8r)).to eq('3/8')
    end
  end

  describe 'instances' do
    it 'are created by Numeric methods with friendly descriptions' do
      expect(3.n16.whole_notes).to eq(3/16r)
      expect(3.n16.to_s).to eq('3 × n16')
      expect(1.n16.to_s).to eq('n16')
      expect(3.sixteenths).to eq(3.n16)
      expect(1.sixteenth).to eq(1.n16)
      expect(2.halves).to eq(1.whole)
      expect(1.quarter).to eq(1.beat)
      expect(2.bars.to_s).to eq('2 bars')
      expect(1.bar.to_s).to eq('1 bar')
      expect(3.beats.whole_notes).to eq(3/4r)
      expect(1.5.bars.whole_notes).to eq(3/2r)
      expect(5.n(7).whole_notes).to eq(5/7r)
      expect(3.n16.inspect).to include('3 × n16', '3/16')
    end

    it 'follows the transport bar length for bars' do
      old = MB::Sound::Sequence.transport.bar_length
      MB::Sound::Sequence.transport.bar_length = 3/4r
      expect(2.bars.whole_notes).to eq(3/2r)
    ensure
      MB::Sound::Sequence.transport.bar_length = old
    end

    it 'supports dotted, double-dotted, and triplet modifiers' do
      expect(1.n8.dotted).to eq(3.n16)
      expect(1.n8.d.to_s).to eq('dotted n8')
      expect(1.n4.dd.whole_notes).to eq(7/16r)
      expect(1.n4.triplet).to eq(1.n6)
      expect(1.n4.t.to_s).to eq('triplet n4')
    end

    it 'can be added, subtracted, scaled, divided, and compared' do
      expect(2.bars + 1.beat).to eq(9.n4)
      expect(1.bar - 1.beat).to eq(3.beats)
      expect(3.n16 * 2).to eq(3.n8)
      expect(2 * 3.n16).to eq(3.n8)
      expect(1.bar / 4).to eq(1.beat)
      expect(1.bar / 1.n16).to eq(16)
      expect([3.n16, 1.n4, 1.n8].max).to eq(1.n4)
      expect(1.n16 < 1.n8).to eq(true)
      expect((3.n16..5.n16).cover?(1.n4)).to eq(true)
      expect({ 3.n16 => 1 }[1.n8.d]).to eq(1)
    end

    it 'rejects arithmetic that would mix up units' do
      expect { 1.bar + 1 }.to raise_error(ArgumentError, /Durations/)
      expect { 1 + 1.bar }.to raise_error(TypeError, /Duration/)
      expect { 1.bar * 1.bar }.to raise_error(ArgumentError, /numbers/)
      expect { MB::Sound::Sequence::Duration.new(Float::INFINITY) }.to raise_error(ArgumentError, /finite real/)
      expect { MB::Sound::Sequence::Duration.new(1i) }.to raise_error(ArgumentError, /finite real/)
    end

    it 'converts to seconds at the current tempo' do
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      expect(1.bar.to_seconds(transport: t)).to eq(2.0)
      expect(3.n16.to_seconds(transport: t)).to eq(0.375)
      expect(1.bar).not_to respond_to(:seconds) # removed 2026-10-11 (Numeric#seconds makes a Length)
    end

    it 'are accepted wherever durations are' do
      expect(described_class.whole_notes(3.n16)).to eq(3/16r)
      expect(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).len(3.n16).length).to eq(3/8r)
      expect(described_class.bars(2.beats, 1)).to eq(1/2r)
      expect(described_class.bars(3, 1)).to eq(3)
    end
  end

  # fixes-1030: `-1.n8` (the literal (-1).n8) and `-len` are offsets for
  # shift and rotate; lengths of time refuse them with one line.
  describe 'negative durations' do
    let(:s) { MB::Sound }

    it 'are made by negative numbers and unary minus, printing and reading back' do
      expect((-1.n8).whole_notes).to eq(-1/8r)
      expect(-(3.n16)).to eq(-3.n16)
      expect((1.n8 - 1.n4).whole_notes).to eq(-1/8r)
      expect(-(-(1.n8))).to eq(1.n8)
      expect((-1.n8).abs).to eq(1.n8)
      expect(-1.n8).to be_negative
      expect(1.n8).to be_positive
      expect([(-1.n8).to_s, (-(2.bars)).to_s, (-1.beat).to_s, (-(1.n8.dotted)).to_s]).to eq(['-n8', '-2 bars', '-1 beat', '-dotted n8'])
      [-1.n8, -(3.n16), -(2.bars), -1.5.bars, -(1.n8.dotted)].each do |d|
        text = MB::Sound::RubyValue.to_ruby(d)
        expect(MB::Sound.module_eval(text).whole_notes).to eq(d.whole_notes), text
      end
    end

    it 'shift and rotate clips and kits earlier, like negative whole notes' do
      clip = s.seq(s::C4, s::E4, s::G4, s::B4).n4
      expect(clip.shift(-1.beat).events.map(&:value)).to eq(clip.shift(-1/4r).events.map(&:value))
      expect(clip.shift(-1.beat).events.map(&:start)).to eq([0r, 1/4r, 1/2r])
      expect(clip.rotate(-(1.beat)).events.map(&:value)).to eq([s::E4, s::G4, s::B4, s::C4].map(&:number))
      kit = s.grid(16, kick: 'x...x...', hat: '..x...x.')
      expect(kit.shift(-2.n16)[:hat].events.map(&:start)).to eq([0r, 1/4r])
      expect(clip.shift(-1.n8).to_ruby).to include('.shift(-1.n8)')
      expect(s::GraphIO.load("graph #{s::GraphIO::FORMAT}\nseq(C4, E4).n4.shift(-1.n8)\n").events.map(&:start)).to eq([1/8r])
    end

    it 'reads seconds offsets at the current tempo' do
      clip = s.seq(s::C4, s::E4).n4
      wn = MB::Sound::Sequence::Duration.rational(0.25 * MB::Sound::Sequence.transport.whole_notes_per_second)
      expect(clip.shift(-0.25.seconds).events.map(&:start)).to eq([1/4r - wn])
    end

    it 'are refused with one line by lengths of time' do
      clip = s.seq(s::C4, s::E4).n4
      sig = 220.hz.saw
      {
        'note length' => -> { clip.note_length(-1.n8) },
        'legato' => -> { clip.legato(-1.n8) },
        'quantize grid' => -> { clip.quantize(-1.n16) },
        'humanize time' => -> { clip.humanize(-1.n64) },
        'ratchet rate' => -> { clip.ratchet(2, rate: -1.n32) },
        'delay' => -> { sig.delay(-1.n8) },
        'delay in seconds' => -> { sig.delay(-5.ms) },
        'multitap' => -> { sig.multitap(-1.n8, 0.1) },
        'envelope time' => -> { s.adsr(-1.n16, 0.1, 0.5, 0.1) },
        'envelope seconds' => -> { s.adsr(-0.01.seconds, 0.1, 0.5, 0.1) },
        'smooth' => -> { sig.smooth(-1.n32) },
        'tempo LFO' => -> { (-1.bar).lfo },
        'echo' => -> { clip.stream.echo(-1.n8) },
        'stream note length' => -> { clip.stream.note_length(-1.n8) },
        'events length' => -> { s.events([0, 1/4r, 60, 1], length: -1.bar) },
        'harmony key' => -> { s.harmony(0 => s.scale(:minor, :a).weights, -2.bars => s.scale(:major, :c).weights) },
      }.each do |what, code|
        expect { code.call }.to raise_error(ArgumentError, /can't be negative|must be|lengths from 0/), what
        begin
          code.call
        rescue ArgumentError => e
          expect(e.message.lines.count).to eq(1), "#{what}: #{e.message}"
        end
      end
    end

    it 'are refused as launch offsets and alignments' do
      expect { MB::Sound::LaunchPoint.build(at: nil, on: nil, offset: -1.bar) }.to raise_error(ArgumentError, /in: must be/)
      expect { MB::Sound::LaunchPoint.build(at: nil, on: -1.n4, offset: nil) }.to raise_error(ArgumentError, /on: must be/)
      expect { MB::Sound::LaunchPoint.build(at: nil, on: nil, offset: -5.ms) }.to raise_error(ArgumentError, /in: must be/)
    end
  end
end
