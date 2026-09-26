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
      expect { MB::Sound::Sequence::Duration.new(-1) }.to raise_error(ArgumentError, /negative/)
    end

    it 'converts to seconds at the current tempo' do
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      expect(1.bar.seconds(t)).to eq(2.0)
      expect(3.n16.seconds(t)).to eq(0.375)
    end

    it 'are accepted wherever durations are' do
      expect(described_class.whole_notes(3.n16)).to eq(3/16r)
      expect(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).len(3.n16).length).to eq(3/8r)
      expect(described_class.bars(2.beats, 1)).to eq(1/2r)
      expect(described_class.bars(3, 1)).to eq(3)
    end
  end
end
