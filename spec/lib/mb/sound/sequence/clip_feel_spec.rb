RSpec.describe(MB::Sound::Sequence::Clip, :midi_transforms) do
  let(:riff) { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::B4).n8 }

  # [value, start] of each note-on edge of +clip+ in +cycles+ loop cycles.
  def played(clip, cycles = 1)
    clip.edges(0r, clip.length * cycles).select { |_, type, _, _| type == :on }.map { |t, _, e, _| [e.value, t] }
  end

  describe '#humanize' do
    it 'moves notes both ways by up to the time, repeatably from the seed' do
      h = riff.humanize(1.n64, seed: 2)
      offsets = h.events.zip(riff.events).map { |a, b| a.start - b.start }
      expect(offsets.map(&:abs).max).to be <= 1/64r
      expect(offsets.any?(&:negative?) || h.events.first.start == 0).to eq(true)
      expect(riff.humanize(1.n64, seed: 2).events).to eq(h.events)
      expect(riff.humanize(1.n64, seed: 3).events).not_to eq(h.events)
      expect(h.events.map(&:length)).to eq(riff.events.map(&:length))
    end

    it 'keeps non-looping notes from starting before 0 and wraps loops' do
      h = riff.humanize(1/16r, seed: 1)
      expect(h.events.map(&:start).min).to be >= 0
      l = riff.loop.humanize(1/16r, seed: 1)
      expect(l.events.map(&:start)).to all(be_between(0, riff.length))
    end

    it 'changes velocities with velocity:' do
      v = riff.humanize(0r + 1/1024r, velocity: 0.3, seed: 1).events.map(&:velocity)
      expect(v).to all(be_between(0.75 * 0.7, 0.75 * 1.3))
      expect(v.uniq.length).to be > 1
    end

    it 'varies every cycle with vary: true' do
      l = riff.loop.humanize(1.n32, seed: 4, vary: true)
      c0 = played(l, 2).first(4)
      c1 = played(l, 2).last(4).map { |v, t| [v, t - riff.length] }
      expect(c0).not_to eq(c1)
      expect(played(l, 2)).to eq(played(riff.loop.humanize(1.n32, seed: 4, vary: true), 2))
      expect(l.to_s).to include('varying humanize')
    end
  end

  describe '#quantize' do
    it 'moves notes to the nearest step, all or part of the way' do
      loose = MB::Sound::Sequence::Clip.new([
        MB::Sound::Sequence::Event.new(start: 1/64r, length: 1/8r, value: 60, velocity: 0.75),
        MB::Sound::Sequence::Event.new(start: 7/64r + 1/8r, length: 1/8r, value: 62, velocity: 0.75),
      ], length: 1/2r)
      expect(loose.quantize(16).events.map(&:start)).to eq([0r, 1/4r])
      expect(loose.quantize(16, amount: 0.5).events.map(&:start)).to eq([1/128r, 1/4r - 1/128r])
      expect(loose.quantize(8, ends: true).events.map(&:length)).to eq([1/8r, 1/8r])
    end
  end

  describe '#swing' do
    it 'moves every second step of each pair' do
      s = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::B4).n16.swing(2/3r)
      expect(s.events.map(&:start)).to eq([0r, 1/12r, 1/8r, 5/24r])
      expect(s.events.map(&:length)).to eq([1/12r, 1/24r, 1/12r, 1/24r])
      expect(riff.swing(0.5).events.map(&:start)).to eq(riff.events.map(&:start))
    end
  end

  describe '#chance, #every, and step marks' do
    it 'drops notes with a probability per cycle, repeatably' do
      c = riff.loop.chance(0.5)
      a = played(c, 8)
      expect(a.length).to be_between(8, 24)
      expect(played(riff.loop.chance(0.5), 8)).to eq(a)
    end

    it 'plays notes every nth cycle from a cycle (trig conditions)' do
      c = (MB::Sound.seq(MB::Sound::C4) | MB::Sound.seq(MB::Sound::E4.every(2, from: 2))).loop
      starts = played(c, 4).map { |v, t| [v, t / c.length] }
      expect(starts).to eq([[60, 0r], [60, 1r], [64, 3/2r], [60, 2r], [60, 3r], [64, 7/2r]])
      expect(MB::Sound.seq(MB::Sound::C4).every(3).events.first.condition).to eq([3, 1])
      expect(MB::Sound.seq(MB::Sound::C4.maybe(0.25)).events.first.probability).to eq(0.25)
      expect(riff.every(4, from: 4).events.map(&:condition).uniq).to eq([[4, 4]])
    end

    it 'validates' do
      expect { riff.chance(2) }.to raise_error(ArgumentError, /probability/)
      expect { MB::Sound::C4.every(0) }.to raise_error(ArgumentError, /every/)
    end
  end

  describe '#permute(vary: true)' do
    it 'plays a new order every cycle, repeatably' do
      c = riff.loop.permute(vary: true, seed: 5)
      orders = 4.times.map { |i| c.events_for(i).map(&:value) }
      expect(orders.uniq.length).to be > 1
      orders.each { |o| expect(o.sort).to eq([60, 64, 67, 71]) }
      expect(4.times.map { |i| riff.loop.permute(vary: true, seed: 5).events_for(i).map(&:value) }).to eq(orders)
      expect(c.events_for(1).map(&:start)).to eq(riff.events.map(&:start))
    end

    it 'keeps varying through transforms and loops, and unrolls in repeats' do
      c = riff.loop.permute(vary: true, seed: 5)
      t = c.transpose(12)
      expect(t.events_for(2).map(&:value)).to eq(c.events_for(2).map { |e| e.value + 12 })
      r = c.repeat(2)
      expect(r.events.map(&:value)).to eq(c.events_for(0).map(&:value) + c.events_for(1).map(&:value))
    end

    it 'turns a Seq into a varying Clip' do
      expect(riff.permute(vary: true)).not_to be_a(MB::Sound::Sequence::Seq)
    end
  end

  describe '#bake' do
    it 'bakes echoes of a non-looping clip into a longer clip' do
      b = MB::Sound.seq(MB::Sound::C4).n8.bake(MB::Sound.echo(1.n8, 2, pitch: 12, velocity: 0.5))
      expect(b.events.map { |e| [e.value, e.start, e.length, e.velocity] }).to eq([
        [60, 0r, 1/8r, 0.75], [72, 1/8r, 1/8r, 0.375], [84, 1/4r, 1/8r, 0.1875],
      ])
      expect(b.length).to eq(3/8r)
      expect(b.looping?).to eq(false)
    end

    it 'wraps echoes of a loop into the same loop length' do
      b = MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4).n8.loop.bake(MB::Sound.echo(3.n16, 2, pitch: 12, velocity: 0.5))
      expect(b.looping?).to eq(true)
      expect(b.length).to eq(3/8r)
      expect(b.events.map { |e| [e.value, e.start] }).to eq([
        [81, 0r], [57, 0r], [76, 1/16r], [84, 1/8r], [60, 1/8r], [69, 3/16r], [88, 1/4r], [64, 1/4r], [72, 5/16r],
      ])
    end

    it 'bakes arps and blocks, and remembers the derivation for swaps' do
      chord = (MB::Sound.seq(MB::Sound::A3.n2) & MB::Sound.seq(MB::Sound::C4.n2) & MB::Sound.seq(MB::Sound::E4.n2)).loop
      b = chord.bake(MB::Sound.arp(:up, 16))
      expect(b.events.map(&:value)).to eq([57, 60, 64, 57, 60, 64, 57, 60])
      expect(b.events.map(&:length).uniq).to eq([1/32r])

      s = MB::Sound.seq(MB::Sound::C4).n4.bake { |st| st.transpose(2) }
      expect(s.events.map(&:value)).to eq([62])
      expect(s.source).to be_a(MB::Sound::Sequence::Clip)
      expect(s.rederive(MB::Sound.seq(MB::Sound::D4).n4).events.map(&:value)).to eq([64])
    end

    it 'gives the same clip at any tempo for Duration lengths' do
      a = MB::Sound.seq(MB::Sound::C4).n8.bake(MB::Sound.echo(1.n8, 2))
      old = MB::Sound::Sequence.transport.bpm
      MB::Sound::Sequence.transport.bpm = 97
      b = MB::Sound.seq(MB::Sound::C4).n8.bake(MB::Sound.echo(1.n8, 2))
      expect(b.events).to eq(a.events)
    ensure
      MB::Sound::Sequence.transport.bpm = old
    end

    it 'needs a transform' do
      expect { riff.bake }.to raise_error(ArgumentError, /transform/)
    end
  end
end
