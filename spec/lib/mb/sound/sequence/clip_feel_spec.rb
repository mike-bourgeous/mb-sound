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

    it 'keeps non-looping notes from starting before 0' do
      h = riff.humanize(1/16r, seed: 1)
      expect(h.events.map(&:start).min).to be >= 0
    end

    it 'humanizes loops per cycle, the same in every cycle with vary: false' do
      l = riff.loop.humanize(1/16r, seed: 1, vary: false)
      expect(l.variations.length).to eq(1)
      expect(l.to_s).to include('vary: false')
      expect(l.events_for(0)).not_to eq(riff.loop.events)
      expect(l.events_for(0)).to eq(l.events_for(5))
      # Starts stay relative to their own cycle (no wrapping)
      expect(l.events_for(0).map(&:start)).to all(be_between(-1/16r, riff.length + 1/16r))
      c1 = played(l, 3).select { |_, t| t >= riff.length && t < 2 * riff.length }
      c2 = played(l, 3).select { |_, t| t >= 2 * riff.length }.map { |v, t| [v, t - riff.length] }
      expect(c2).to eq(c1)
    end

    # Notes per grid step (an eighth) over +cycles+ cycles of +clip+: a
    # Hash of step index => played note values.
    def steps(clip, cycles)
      played(clip, cycles).group_by { |_, t| (t * 8).round }.transform_values { |l| l.map(&:first) }
    end

    [true, false].each do |vary|
      it "plays every note exactly once across loop boundaries (vary: #{vary})" do
        values = riff.events.map(&:value)
        30.times do |seed|
          l = riff.loop.humanize(1/32r, seed: seed, vary: vary)
          got = steps(l, 6).reject { |i, _| i >= 24 } # (the next cycle's early downbeat may land before 3)
          expected = (0...24).to_h { |i| [i, [values[i % 4]]] }
          expect(got).to eq(expected), "seed #{seed}: #{played(l, 6).inspect}"
        end
      end
    end

    it 'plays the default +/-4 ms feel of the round-2 riff with every downbeat (listening bug 2026-10-10)' do
      r = MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::E4, MB::Sound::C4, MB::Sound::D4, MB::Sound::B3).n8.loop
      h = r.humanize(velocity: 0.3)
      got = h.edges(0r, 6r).select { |_, type, _, _| type == :on }.group_by { |t, *| (t * 8).round }
      expect(got.keys.sort).to eq((0...48).to_a)
      expect(got.values.map(&:length).uniq).to eq([1])
    end

    describe 'notes moved across the loop boundary' do
      let(:base) { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::B4).n8.loop }
      # Odd cycles move their first note 1/64 earlier, every cycle moves its
      # last note 1/8 + 1/64 later (1/64 past the cycle's end)
      let(:moved) {
        v = MB::Sound::Sequence::Clip::Variation.new(name: 'test', block: ->(events, cycle, _clip) {
          events.each_with_index.map { |e, i|
            if i == 0 && cycle.odd?
              e.with(start: e.start - 1/64r)
            elsif i == 3
              e.with(start: e.start + 1/8r + 1/64r)
            else
              e
            end
          }
        })
        MB::Sound::Sequence::Clip.new(base.events, length: base.length, loop: true, variations: [v])
      }

      def ons(clip, from, to, early: false)
        clip.edges(from, to, early: early).select { |_, type, _, _| type == :on }.map { |t, _, e, c| [e.value, t, c] }
      end

      it 'plays early notes at the end of the previous cycle and late ones in the next, once each' do
        c, e, g, b = base.events.map(&:value)
        expect(ons(moved, 0r, 1r)).to eq([
          [c, 0r, 0], [e, 1/8r, 0], [g, 1/4r, 0],
          [c, 1/2r - 1/64r, 1], [b, 1/2r + 1/64r, 0], [e, 5/8r, 1], [g, 3/4r, 1],
        ])
        # Cycle 1's late note plays in the next read; cycle 3's early
        # downbeat in this one
        expect(ons(moved, 1r, 3/2r)).to eq([
          [c, 1r, 2], [b, 1r + 1/64r, 1], [e, 9/8r, 2], [g, 5/4r, 2], [c, 3/2r - 1/64r, 3],
        ])
      end

      it 'matches when read in any block sizes' do
        whole = ons(moved, 0r, 3r)
        [1/7r, 1/16r, 1/64r, 1/3r].each do |step|
          parts = (0...(3 / step).ceil).flat_map { |i| ons(moved, i * step, MB::M.min((i + 1) * step, 3r)) }
          expect(parts).to eq(whole), "step #{step}"
        end
      end

      it 'plays the first cycle\'s early notes at 0' do
        v = MB::Sound::Sequence::Clip::Variation.new(name: 'early', block: ->(events, _cycle, _clip) {
          events.map { |e| e.with(start: e.start - 1/64r) }
        })
        clip = MB::Sound::Sequence::Clip.new(base.events, length: base.length, loop: true, variations: [v])
        expect(ons(clip, 0r, 1/2r).map { |v_, t, _| [v_, t] }).to eq([
          [base.events[0].value, 0r], [base.events[1].value, 1/8r - 1/64r], [base.events[2].value, 1/4r - 1/64r],
          [base.events[3].value, 3/8r - 1/64r], [base.events[0].value, 1/2r - 1/64r],
        ])
      end

      it 'plays a launched cycle\'s early notes at the read start with early: true' do
        expect(ons(moved, 1/2r, 5/8r).map(&:first)).not_to include(base.events[0].value)
        expect(ons(moved, 1/2r, 5/8r, early: true).first).to eq([base.events[0].value, 1/2r, 1])
        # Notes of earlier cycles don't move
        expect(ons(moved, 1/2r + 1/32r, 5/8r, early: true).map(&:first)).not_to include(base.events[0].value)
      end

      it 'unrolls with #repeat and #| without notes before 0' do
        r = moved.send(:repeated, 3)
        expect(r.events.map(&:start).min).to eq(0)
        expect(r.events.length).to eq(12)
        expect(r.events.map(&:start)).to include(1/2r - 1/64r)
        expect((moved | base).events.map(&:start).min).to eq(0)
      end
    end

    it 'changes velocities with velocity:' do
      v = riff.humanize(0r + 1/1024r, velocity: 0.3, seed: 1).events.map(&:velocity)
      expect(v).to all(be_between(0.75 * 0.7, 0.75 * 1.3))
      expect(v.uniq.length).to be > 1
    end

    it 'defaults to +/-4 ms, varying every cycle of a loop' do
      h = riff.humanize(seed: 5)
      whole = 240.0 / MB::Sound::Sequence.transport.bpm
      offsets = h.events.zip(riff.events).map { |a, b| (a.start - b.start) * whole }
      expect(offsets.map(&:abs).max).to be <= 0.004 + 1e-9
      expect(offsets.map(&:abs).max).to be > 0.001
      l = riff.loop.humanize(seed: 5)
      expect(l.variations.length).to eq(1)
      expect(played(l, 2).first(4)).not_to eq(played(l, 2).last(4).map { |v, t| [v, t - riff.length] })
      expect(riff.humanize.variations).to be_empty
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

    it 'bakes several cycles of a varying loop with cycles:, wrapping from the last' do
      line = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::B4).n8.loop.permute(vary: true, seed: 1)
      b = line.bake(MB::Sound.echo(1.n8, 1, pitch: 12), cycles: 3)
      expect(b.length).to eq(3 * line.length)
      dry = b.events.select { |e| e.velocity == 0.75 && e.value < 72 }.map(&:value)
      expect(dry).to eq((0..2).flat_map { |c| line.events_for(c).map(&:value) })
      # The first echo (at 1/8) comes from cycle 2's last note, wrapped around
      wrapped = b.events.find { |e| e.start == 0 && e.value >= 72 }
      expect(wrapped.value).to eq(line.events_for(2).last.value + 12)
    end

    it 'plays out cycle conditions per baked cycle' do
      c = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4.every(2, from: 2)).n4.loop
      b = c.bake(->(s) { s }, cycles: 2)
      expect(b.events.map { |e| [e.value, e.start] }).to eq([[60, 0r], [60, 1/2r], [64, 3/4r]])
      expect(c.repeat(2).events.map { |e| [e.value, e.start] }).to eq([[60, 0r], [60, 1/2r], [64, 3/4r]])
    end

    it 'needs a transform' do
      expect { riff.bake }.to raise_error(ArgumentError, /transform/)
    end
  end
end
