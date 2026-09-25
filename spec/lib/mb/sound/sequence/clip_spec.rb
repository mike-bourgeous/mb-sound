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

    it 'warns that a repeated looping clip stops looping' do
      clip = (c4.n8 | e4.n8).loop
      expect(clip).to receive(:warn).with(/stop looping/).twice
      expect(clip.repeat(2)).not_to be_looping
      expect(clip * 2).not_to be_looping
    end

    it 'does not warn for non-looping clips or when splitting voices' do
      clip = (c4.n8 | e4.n8 | c4.n8).loop
      expect_any_instance_of(described_class).not_to receive(:warn)
      (c4.n8 | e4.n8).repeat(2)
      clip.synth(voices: 2) { 1.constant }
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

  describe '#synth' do
    let(:chords) { MB::Sound.seq(MB::Sound::A2, MB::Sound::F2, MB::Sound::C3, MB::Sound::G2).n1 }

    it 'yields one clip per voice with notes assigned round-robin, and the index' do
      yielded = []
      chords.synth(voices: 2) { |v, idx| yielded << [idx, v.events.map(&:value)]; 1.constant }
      expect(yielded).to eq([[0, [45, 48]], [1, [41, 43]]])
    end

    it 'defaults to two voices' do
      count = 0
      chords.synth { count += 1; 1.constant }
      expect(count).to eq(2)
    end

    it 'puts notes that start together on different voices' do
      yielded = []
      (MB::Sound::C3.n1 & MB::Sound::G3.n1).synth { |v| yielded << v.events.map(&:value); 1.constant }
      expect(yielded).to eq([[48], [55]])
    end

    it 'keeps the original timing and length in every voice' do
      voices = []
      chords.loop.synth { |v| voices << v; 1.constant }
      expect(voices.map(&:length).uniq).to eq([4])
      expect(voices.all?(&:looping?)).to eq(true)
      expect(voices[1].events.map(&:start)).to eq([1, 3])
    end

    it 'repeats a loop whose notes do not divide evenly among the voices' do
      voices = []
      chords.loop.synth(voices: 3) { |v| voices << v; 1.constant }
      expect(voices.map(&:length).uniq).to eq([12])
      expect(voices.map { |v| v.events.length }).to eq([4, 4, 4])
      expect(voices[0].events.map(&:start)).to eq([0, 3, 6, 9])
    end

    it 'skips voices with no notes' do
      count = 0
      MB::Sound::C3.n4.synth(voices: 4) { count += 1; 1.constant }
      expect(count).to eq(1)
    end

    it 'mixes the voice graphs together' do
      g = chords.synth(voices: 2) { |_, idx| (idx + 1).constant }
      expect(g.sample(10)[0]).to eq(3)
    end

    it 'mixes stereo pairs per channel' do
      g = chords.synth(voices: 2) { |_, idx| [(idx + 1).constant, 10.constant] }
      expect(g.length).to eq(2)
      expect([g[0].sample(10)[0], g[1].sample(10)[0]]).to eq([3, 20])
    end

    it 'lets one voice release while the next note attacks on another' do
      transport = MB::Sound::Sequence::Transport.new(bpm: 240) # a whole note is 1 second
      g = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n1.synth { |v| v.env(0.01, 0.01, 1, 0.5, velocity: 1..1, transport: transport) }
      data = Array.new(80) { g.sample(800).dup }.reduce(:concatenate) # the mixer reuses its buffer
      # Just after the second note starts, the first is still releasing
      expect(data[47000]).to be_within(0.01).of(1)
      expect(data[48000 + 480]).to be > 1.5
    end

    it 'requires a block and a positive voice count' do
      expect { chords.synth }.to raise_error(ArgumentError, /block/)
      expect { chords.synth(voices: 0) { 1.constant } }.to raise_error(ArgumentError, /Voice count/)
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
