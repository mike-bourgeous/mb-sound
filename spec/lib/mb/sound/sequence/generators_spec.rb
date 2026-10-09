RSpec.describe(MB::Sound::Sequence::Generators, :midi_transforms) do
  def pattern(k, n, **opts)
    MB::Sound::Sequence::Generators.euclid_pattern(k, n, **opts).map { |h| h ? 'x' : '.' }.join
  end

  describe '.euclid_pattern' do
    it "matches Toussaint's Euclidean rhythms" do
      expect(pattern(3, 8)).to eq('x..x..x.')
      expect(pattern(5, 8)).to eq('x.xx.xx.')
      expect(pattern(2, 5)).to eq('x.x..')
      expect(pattern(4, 12)).to eq('x..x..x..x..')
      expect(pattern(7, 16)).to eq('x..x.x.x..x.x.x.')
      expect(pattern(0, 4)).to eq('....')
      expect(pattern(4, 4)).to eq('xxxx')
    end

    it 'rotates later' do
      expect(pattern(3, 8, rotate: 1)).to eq('.x..x..x')
      expect(pattern(3, 8, rotate: -1)).to eq('..x..x.x')
    end

    it 'validates' do
      expect { pattern(9, 8) }.to raise_error(ArgumentError, /hits/)
      expect { pattern(1, 0) }.to raise_error(ArgumentError, /steps/)
    end
  end

  describe 'MB::Sound#euclid' do
    it 'makes a Seq of hits and rests' do
      e = MB::Sound.euclid(3, 8)
      expect(e).to be_a(MB::Sound::Sequence::Seq)
      expect(e.length).to eq(1/2r)
      expect(e.events.map { |x| [x.value, x.start, x.length] }).to eq([[36, 0r, 1/16r], [36, 3/16r, 1/16r], [36, 3/8r, 1/16r]])
      expect(MB::Sound.euclid(2, 4, MB::Sound::D2, step: 8, velocity: 1).events.map { |x| [x.value, x.start, x.velocity] }).to eq([[38, 0r, 1.0], [38, 1/4r, 1.0]])
    end
  end

  describe 'MB::Sound#melody' do
    let(:am) { MB::Sound.scale(:minor, MB::Sound::A3) }

    it 'walks the scale within its range, repeatably from the seed' do
      m = MB::Sound.melody(am, 16, seed: 3)
      expect(m.events.length).to eq(16)
      expect(m.events.map(&:value)).to all(satisfy { |n| am.include?(n) && n.between?(45, 69) })
      expect(m.events.each_cons(2).map { |a, b| (am.degree(a.value)[0] - am.degree(b.value)[0]).abs }.max).to be <= 3
      expect(MB::Sound.melody(am, 16, seed: 3).events).to eq(m.events)
      expect(MB::Sound.melody(am, 16, seed: 4).events).not_to eq(m.events)
      expect(m.seed).to eq(3)
      expect(m.length).to eq(1r)
    end

    it 'draws its seed from MB::Sound by default' do
      MB::Sound.seed(12)
      a = MB::Sound.melody(am, 8)
      MB::Sound.seed(12)
      b = MB::Sound.melody(am, 8)
      expect(b.events).to eq(a.events)
    end

    it 'fills a rhythm, keeping its timing and velocities' do
      rhythm = MB::Sound.euclid(5, 8, velocity: 0.9)
      m = MB::Sound.melody(am, rhythm: rhythm, seed: 1)
      expect(m.events.map(&:start)).to eq(rhythm.events.map(&:start))
      expect(m.events.map(&:velocity).uniq).to eq([0.9])
      expect(m.length).to eq(rhythm.length)
    end

    it 'leaves rests, honors leap: and range:' do
      m = MB::Sound.melody(am, 32, seed: 2, rest: 0.5)
      expect(m.events.length).to be_between(4, 28)
      tight = MB::Sound.melody(am, 32, seed: 2, leap: 1, range: MB::Sound::A3..MB::Sound::E4)
      expect(tight.events.map(&:value)).to all(be_between(57, 64))
    end

    it 'picks new notes every cycle with vary: true' do
      m = MB::Sound.melody(am, 8, seed: 5, vary: true).loop
      a = m.events_for(0).map(&:value)
      b = m.events_for(1).map(&:value)
      expect(a).not_to eq(b)
      expect(MB::Sound.melody(am, 8, seed: 5, vary: true).loop.events_for(1).map(&:value)).to eq(b)
    end
  end
end
