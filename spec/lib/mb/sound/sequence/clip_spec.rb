RSpec.describe(MB::Sound::Sequence::Clip) do
  let(:c4) { MB::Sound::C4 }
  let(:e4) { MB::Sound::E4 }

  def times(clip)
    clip.events.map { |e| [e.value, e.start, e.length] }
  end

  describe '#|' do
    it 'plays clips one after another' do
      c = c4.n8 | e4.n4
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/4r]])
      expect(c.length).to eq(3/8r)
    end

    it 'includes trailing rests in the length' do
      expect((c4.n8 | MB::Sound.rest.n8).length).to eq(1/4r)
    end
  end

  describe '#&' do
    it 'plays clips at the same time, with the longer length' do
      c = c4.n8 & e4.n2
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 0, 1/2r]])
      expect(c.length).to eq(1/2r)
    end
  end

  describe '#repeat and #*' do
    it 'repeats the clip' do
      expect(times(c4.n8 * 3)).to eq([[60, 0, 1/8r], [60, 1/8r, 1/8r], [60, 1/4r, 1/8r]])
      expect(c4.n8.repeat(3).length).to eq(3/8r)
    end

    it 'rejects non-positive counts' do
      expect { c4.n8 * 0 }.to raise_error(ArgumentError)
      expect { c4.n8 * 1.5 }.to raise_error(ArgumentError)
    end
  end

  describe '#fill' do
    it 'repeats a short clip to fill a span' do
      c = c4.n32.fill(4)
      expect(c.events.length).to eq(8)
      expect(c.length).to eq(1/4r)
    end

    it 'cuts the last repetition short' do
      c = (c4.n8 | e4.n8).fill(3/8r)
      expect(times(c)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/8r], [60, 1/4r, 1/8r]])
    end
  end

  describe '#roll' do
    it 'splits each event into hits of the given length' do
      c = c4.n4.roll(32)
      expect(c.events.map(&:start)).to eq((0...8).map { |i| Rational(i, 32) })
      expect(c.events.map(&:length).uniq).to eq([1/32r])
      expect(c.length).to eq(1/4r)
    end

    it 'shortens the last hit if the event does not divide evenly' do
      c = c4.n4.roll(3/32r)
      expect(c.events.map(&:length)).to eq([3/32r, 3/32r, 1/16r])
    end

    it 'can ramp velocity' do
      c = c4.n4.roll(16, velocity: 0.2..0.8)
      expect(c.events.map(&:velocity)).to all(be_a(Float))
      expect(c.events.map { |e| e.velocity.round(3) }).to eq([0.2, 0.4, 0.6, 0.8])
    end
  end

  describe '#ratchet' do
    it 'splits each event into equal hits' do
      c = c4.n4.ratchet(3)
      expect(c.events.map(&:start)).to eq([0, 1/12r, 1/6r])
      expect(c.events.map(&:length)).to eq([1/12r] * 3)
    end
  end

  describe '#stretch and modifiers' do
    it 'multiplies times and lengths' do
      c = (c4.n8 | e4.n8).stretch(2)
      expect(times(c)).to eq([[60, 0, 1/4r], [64, 1/4r, 1/4r]])
      expect(c.length).to eq(1/2r)
    end

    it 'has dotted and triplet shortcuts' do
      expect((c4.n8 | e4.n8).d.length).to eq(3/8r)
      expect((c4.n8 | e4.n8).t.length).to eq(1/6r)
    end
  end

  describe '#transpose' do
    it 'shifts values' do
      expect((c4.n8 | e4.n8).transpose(-12).events.map(&:value)).to eq([48, 52])
    end
  end

  describe '#loop' do
    it 'returns a looping copy' do
      c = c4.n8.loop
      expect(c).to be_looping
      expect(c4.n8).not_to be_looping
    end

    it 'rejects empty clips' do
      expect { MB::Sound::Sequence::Clip.new([]).loop }.to raise_error(ArgumentError, /positive length/)
    end
  end

  describe '#edges' do
    it 'returns note-ons and note-offs within a half-open window' do
      c = c4.n8 | e4.n8
      edges = c.edges(0, 1/8r).map { |t, type, e, _| [t, type, e.value] }
      expect(edges).to eq([[0, :on, 60]])

      edges = c.edges(1/8r, 1).map { |t, type, e, _| [t, type, e.value] }
      expect(edges).to eq([[1/8r, :off, 60], [1/8r, :on, 64], [1/4r, :off, 64]])
    end

    it 'repeats looping clips' do
      c = (c4.n8 | e4.n8).loop
      ons = c.edges(0, 1).select { |_, type| type == :on }.map { |t, _, e, cycle| [t, e.value, cycle] }
      expect(ons).to eq([[0, 60, 0], [1/8r, 64, 0], [1/4r, 60, 1], [3/8r, 64, 1], [1/2r, 60, 2], [5/8r, 64, 2], [3/4r, 60, 3], [7/8r, 64, 3]])
    end

    it 'finds note-offs for notes that last longer than the loop' do
      c = MB::Sound::Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 3/4r, value: 60, velocity: 1.0)], length: 1/4r, loop: true)
      offs = c.edges(1/2r, 5/4r).select { |_, type| type == :off }.map { |t, _, _, cycle| [t, cycle] }
      expect(offs).to eq([[3/4r, 0], [1, 1]])
    end

    it 'decides probabilistic events the same way for the same cycle and seed' do
      c = MB::Sound.grid(16, '????????????????').loop
      a = c.edges(0, 4).map(&:first)
      b = c.edges(0, 4).map(&:first)
      expect(a).to eq(b)
      expect(a.length).to be_between(40, 88) # about half of 64 hits, on and off

      other = c.loop(seed: 5).edges(0, 4).map(&:first)
      expect(other).not_to eq(a)
    end
  end
end
