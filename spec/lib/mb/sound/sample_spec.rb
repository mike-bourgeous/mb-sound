RSpec.describe(MB::Sound::Sample, :aggregate_failures) do
  let(:ramp) { Numo::SFloat.new(4800).seq / 4800 }
  let(:s) { MB::Sound::Sample[ramp] }

  describe 'construction' do
    it 'takes NArrays, channel Arrays, number Arrays, and Samples' do
      expect(s.length).to eq(4800)
      expect(s.seconds).to eq(0.1)
      expect(s.root).to eq(60)
      expect(s.loop_mode).to eq(:one_shot)
      expect(s.channel_count).to eq(1)
      expect(MB::Sound::Sample[[ramp, ramp * 2]].channel_count).to eq(2)
      expect(MB::Sound::Sample[Numo::SFloat.zeros(2, 10)].channel_count).to eq(2)
      expect(MB::Sound::Sample[[0.1, 0.2]].length).to eq(2)
      expect(MB::Sound::Sample[s]).to equal(s)
      expect(MB::Sound::Sample[s, root: MB::Sound::A4].root).to eq(69)
      expect(MB::Sound::Sample[ramp, root: 440.hz].root).to be_within(1e-9).of(69)
    end

    it 'takes a sample-mode Wavetable' do
      t = MB::Sound::Wavetable.from_samples(ramp, mode: :sample, root: 220, loop: 100...200)
      x = MB::Sound::Sample[t]
      expect(x.root).to be_within(1e-9).of(57)
      expect(x.loop_points).to eq([100.0, 200.0])
      expect(x.loop_mode).to eq(:forward)
    end

    it 'rejects bad data and settings' do
      expect { MB::Sound::Sample[:x] }.to raise_error(ArgumentError, /Cannot make a sample/)
      expect { MB::Sound::Sample[Numo::SFloat[]] }.to raise_error(ArgumentError, /at least one sample/)
      expect { MB::Sound::Sample[[ramp, ramp[0...10]]] }.to raise_error(ArgumentError, /same length/)
      expect { MB::Sound::Sample.new(ramp, loop_mode: :forward) }.to raise_error(ArgumentError, /needs a loop/)
      expect { MB::Sound::Sample.new(ramp, loop_mode: :wobble) }.to raise_error(ArgumentError, /Unknown loop mode/)
      expect { s.looped(10...5) }.to raise_error(ArgumentError, /loop/)
    end

    it 'is a frozen value' do
      expect(s).to be_frozen
      expect(s.audio.channels[0]).to be_frozen
    end
  end

  describe 'views' do
    it 'trims with Integer samples, seconds, and Lengths, sharing the audio' do
      t = s[100...200]
      expect(t.length).to eq(100)
      expect(t.data).to eq(ramp[100...200])
      expect(t.audio).to equal(s.audio)
      expect(s.trim(0.001..0.002).length).to eq(49)
      expect(s.trim(48.samples...96.samples).length).to eq(48)
    end

    it 'reverses, offsets, and trims reversed samples in play order' do
      r = s.rev
      expect(r.data).to eq(ramp.reverse)
      expect(r.rev.data).to eq(ramp)
      expect(r[0...10].data).to eq(ramp.reverse[0...10])
      expect(s.at(100).data).to eq(ramp[100..])
      expect(r.at(100).data).to eq(ramp.reverse[100..])
      expect { s.at(5000) }.to raise_error(ArgumentError, /past the end/)
    end

    it 'counts Durations at the sample tempo' do
      b = MB::Sound::Sample.new(Numo::SFloat.zeros(48000), bpm: 120)
      expect(b.at(1.n16).start).to eq(6000)
      expect(b.position(1.beat)).to eq(24000)
    end

    it 'loops, fades, gains, transposes, and normalizes' do
      l = s.looped(1000...2000, mode: :ping_pong)
      expect(l.loop_points).to eq([1000.0, 2000.0])
      expect(l.loop_mode).to eq(:ping_pong)
      expect(s.looped.loop_points).to eq([0.0, 4800.0])
      expect(l.one_shot.looped?).to eq(false)
      expect(s.fade(in: 10, out: 1.ms).fade_out).to eq(48)
      expect(s.gain(-6.db).level).to be_within(1e-3).of(0.501)
      expect(s.transpose(2).transpose(MB::Sound::Interval.new(1)).tune).to eq(3)
      expect(s.gain(0.25).normalize.peak).to be_within(1e-6).of(1)
      expect(s.normalize(-6.db).peak).to be_within(1e-3).of(0.501)
    end

    it 'remembers how it was made' do
      t = s.rev.at(10)
      expect(t.lineage[1]).to eq(:at)
      expect(t.lineage[0].lineage[1]).to eq(:reverse)
      expect(t.origin).to equal(s)
    end
  end

  describe 'edits' do
    it 'reduces bits' do
      b = s.bits(4)
      expect((b.data * 8).round).to eq(b.data * 8)
      expect(b.audio).not_to equal(s.audio)
      expect(b.lineage[1]).to eq(:bits)
    end

    it 'runs lofi presets and settings' do
      x = MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| Math.sin(i * 0.3) })]
      [:s950, :sp1200, :mpc60].each do |p|
        y = x.lofi(p)
        expect(y.length).to eq(x.length)
        expect((y.data * 2048).round).to eq(y.data * 2048) unless MB::Sound::Sample::Lofi::PRESETS[p][:filter]
      end
      expect(x.lofi(rate: 8000).data).not_to eq(x.data)
      expect { x.lofi(:tape) }.to raise_error(ArgumentError, /Unknown lofi preset/)
      expect { x.lofi }.to raise_error(ArgumentError, /preset or rate/)
    end

    it 'reads :s950 and :sp1200 drop-sample, :mpc60 clean, unless told otherwise' do
      x = MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| Math.sin(i * 0.3) })]
      expect([x.interpolation, x.mips]).to eq([nil, nil])
      [:s950, :sp1200].each do |p|
        expect([x.lofi(p).interpolation, x.lofi(p).mips]).to eq([:none, false])
      end
      expect([x.lofi(:mpc60).interpolation, x.lofi(:mpc60).mips]).to eq([nil, nil])
      expect(x.lofi(:s950).to_s).to include('drop read')
      expect(x.lofi(:mpc60).to_s).not_to include('drop read')

      drop = x.lofi(:mpc60, read: :drop)
      expect([drop.interpolation, drop.mips]).to eq([:none, false])
      expect(drop.data).to eq(x.lofi(:mpc60).data)
      clean = x.lofi(:s950, read: :clean)
      expect([clean.interpolation, clean.mips]).to eq([nil, nil])
      expect(clean.data).to eq(x.lofi(:s950).data)
      expect(x.lofi(:s950, read: { interpolation: :cubic }).interpolation).to eq(:cubic)
      expect(x.lofi(rate: 8000).interpolation).to be_nil # custom converters keep the read

      # Views and later edits keep the read; read_as changes it (a view)
      d = x.lofi(:sp1200)
      expect(d.slices(4)[2].interpolation).to eq(:none)
      expect(d.rev.bits(8).mips).to eq(false)
      c = d.read_as(:clean)
      expect(c.audio).to equal(d.audio)
      expect([c.interpolation, c.mips]).to eq([nil, nil])
      expect(c.lineage[1..2]).to eq([:read_as, [:clean]])
      expect([x.read_as(:drop).interpolation, x.read_as(:drop, mips: :octave).mips]).to eq([:none, :octave])
      expect(x.read_as(interpolation: :cubic).interpolation).to eq(:cubic)
      expect { x.read_as(:wobbly) }.to raise_error(ArgumentError, /Unknown read style/)
      expect { x.read_as(speed: 2) }.to raise_error(ArgumentError, /read_as takes/)
      expect { x.with(interpolation: :blurry) }.to raise_error(ArgumentError, /Unknown interpolation/)
    end

    it 'stretches cyclically to the asked length at the same pitch with fit: :fixed' do
      sine = ->(n) { Numo::SFloat.cast(Numo::DFloat.new(n).seq.map { |i| Math.sin(i * 2 * Math::PI * 500 / 48000) }) }
      x = MB::Sound::Sample[sine.(4800)]
      y = x.stretch(2, cycle: 20.ms, fit: :fixed)
      expect(y.length).to eq(9600)
      # 20 ms cycles of 500 Hz taken every 10 ms: whole periods, so seamless
      expect((y.data[0...9000] - sine.(9000)).abs.max).to be < 1e-5
      z = x.stretch(1.5, cycle: 7.ms, crossfade: 1.ms, fit: :fixed)
      expect(z.length).to eq(7200)
      # nil and false mean :fixed (what they meant before :auto was the default)
      expect(x.stretch(2, cycle: 20.ms, fit: nil).data).to eq(y.data)
      expect(x.stretch(2, cycle: 20.ms, fit: false).data).to eq(y.data)
      expect(y.lineage[1..3]).to eq([:stretch, [2], { cycle: 20.ms, fit: :fixed }])
    end

    it 'keeps a bass at its pitch with fit: :auto, where :fixed retunes it' do
      # A 55 Hz sine at 2x in 30 ms cycles: :fixed turns it into partials at
      # 27.5 + 33.3 m Hz, the strongest at 60.8 Hz (Lofi::FITS)
      sine = Numo::SFloat.cast(Numo::DFloat.new(48000).seq.map { |i| Math.sin(i * 2 * Math::PI * 55 / 48000) })
      x = MB::Sound::Sample[sine]
      peak = ->(s) {
        d = Numo::DFloat.cast(s.data[12000...60000])
        d *= 0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(48000).seq * (2 * Math::PI / 48000))
        Numo::Pocketfft.rfft(d).abs[0..200].max_index
      }
      expect(peak.(x.stretch(2, cycle: 30.ms, fit: :fixed))).to eq(61)
      expect(peak.(x.stretch(2, cycle: 30.ms))).to eq(55)
    end

    it 'fits stretch cycles to the sound with fit: :auto (the default)' do
      sine = ->(n, f) { Numo::SFloat.cast(Numo::DFloat.new(n).seq.map { |i| Math.sin(i * 2 * Math::PI * f / 48000) }) }
      jump = ->(d) { (d[1..] - d[0...-1]).abs.max }
      x = MB::Sound::Sample[sine.(24000, 110)]
      fixed = x.stretch(2, cycle: 30.ms, fit: :fixed)
      auto = x.stretch(2, cycle: 30.ms)
      expect(x.stretch(2, cycle: 30.ms, fit: :auto).data).to eq(auto.data)
      expect(auto.length).to eq(48000)
      # 30 ms isn't a whole number of 110 Hz periods: the plain stretch
      # cuts mid-cycle, the fitted one splices on matching phase
      expect(jump.(fixed.data)).to be > 0.5
      expect(jump.(auto.data)).to be < 2 * jump.(x.data)

      # Cycles are whole periods near the asked length, cut at rising zero crossings
      plan = MB::Sound::Sample::Lofi.fit_plan(x.data, 2.0, 1440)
      period = 48000 / 110.0
      plan[0...-2].each do |o, src, len|
        expect((len / period - (len / period).round).abs).to be < 0.01
        expect(len).to be_within(period / 2 + 1).of(1440)
      end
      expect(plan.map(&:first).each_cons(2).all? { |a, b| b > a }).to eq(true)
      # The output keeps time: each cycle starts near output time / ratio
      plan.each { |o, src, _| expect(src).to be_within(0.25 * 1440 + 12).of([o / 2.0, 24000 - 1440].min) }

      # Every channel cuts in the same places
      st = MB::Sound::Sample[[sine.(24000, 110) + sine.(24000, 2000) * 0.1, sine.(24000, 110) * 0.5]].stretch(1.5, cycle: 20.ms, fit: :auto)
      expect(st.length).to eq(36000)
      mono = MB::Sound::Sample[sine.(24000, 110) + sine.(24000, 2000) * 0.1].stretch(1.5, cycle: 20.ms, fit: :auto)
      expect(st.data(0)).not_to eq(mono.data) # the plan follows the mix, not one channel

      # Noise: no period, splices only where they match; still the asked length
      rng = Random.new(3)
      noise = MB::Sound::Sample[Numo::SFloat.cast(Array.new(9600) { rng.rand - 0.5 })]
      expect(noise.stretch(0.5, cycle: 10.ms, fit: :auto).length).to eq(4800)
      expect(noise.stretch(3, fit: :auto, crossfade: 1.ms).length).to eq(28800)
      expect(MB::Sound::Sample[sine.(500, 440)].stretch(2, cycle: 30.ms, fit: :auto).length).to eq(1000) # shorter than a cycle

      expect(auto.lineage[1..3]).to eq([:stretch, [2], { cycle: 30.ms }])
      expect { x.stretch(2, fit: :wobble) }.to raise_error(ArgumentError, /Unknown stretch fit/)
    end

    it 'mixes to mono' do
      st = MB::Sound::Sample[[ramp, ramp * 3]]
      expect(st.mono.data).to eq(ramp * 2)
      expect(s.mono).to equal(s)
    end
  end

  describe 'slices' do
    it 'cuts equal slices, joins runs, and names them' do
      b = s.slices(4)
      expect(b.length).to eq(4)
      expect(b[1].data[0...100]).to eq(ramp[1200...1300])
      expect(b[1].fade_out).to eq(96)
      expect(b[1..2].length).to eq(2400)
      expect(b[-1].start).to eq(3600)
      n = b.name(k: 0, sk: 1..3)
      expect(n[:sk].length).to eq(3600)
      expect { n[:x] }.to raise_error(ArgumentError, /No slice named/)
      expect { b.name(z: 9) }.to raise_error(ArgumentError, /slice index/)
      expect(n.chop_list.length).to eq(5)
    end

    it 'cuts at positions and in play order for reversed samples' do
      b = s.slices(at: [0, 1000, 3000])
      expect(b.bounds).to eq([[0, 1000], [1000, 3000], [3000, 4800]])
      r = s.rev.slices(2)
      expect(r[0].data).to eq(ramp.reverse[0...2400])
      expect(r[0]).to be_reversed
    end

    it 'finds onsets' do
      x = Numo::SFloat.zeros(48000)
      [3000, 15000, 30001].each { |at| x[at...(at + 2000)] = Numo::SFloat.cast(Numo::DFloat.new(2000).seq.map { |i| Math.sin(i * 0.7) * Math.exp(-i / 400.0) }) }
      on = MB::Sound::Sample[x].onsets
      expect(on.length).to eq(3)
      on.zip([3000, 15000, 30001]).each { |a, b| expect(a).to be_within(3).of(b) }
      expect(MB::Sound::Sample[x].slices(:onsets).length).to eq(4)
    end

    it 'makes chop clips of keys with pitch marks: slices, runs, then all reversed from C2' do
      b = s.slices(4).name(two: 2..3)
      c = b.chop(0, MB::Sound::Tie, [1, 2], :two, b[1].rev.transpose(-3), MB::Sound::Rest, [3, 0, { vel: 0.3 }])
      # Keys: slices 36..39, the run :two 40, reversed 41..45
      expect(c.events.map(&:value)).to eq([36, 37, 40, 42, 39])
      expect(c.events.map(&:pitch)).to eq([0.0, 2.0, 0.0, -3.0, 0.0])
      expect(c.events[0].length).to eq(1/8r)
      expect(c.events.last.velocity).to eq(0.3)
      t = c.transpose(2)
      expect(t.events.map(&:value)).to eq([36, 37, 40, 42, 39])
      expect(t.events.map(&:pitch)).to eq([2.0, 4.0, 2.0, -1.0, 2.0])
      expect(t.loop.transpose(-2).events.map(&:pitch)).to eq([0.0, 2.0, 0.0, -3.0, 0.0])
      expect(b.chop(0, from: 48).events[0].value).to eq(48)
      expect { b.chop(:nope) }.to raise_error(ArgumentError)
      expect { b.chop(0, from: 125) }.not_to raise_error
      expect { b.chop(b[0].rev, from: 125) }.to raise_error(ArgumentError, /past 127/)

      inst = b.keymap(from: MB::Sound::C2)
      expect(inst.regions.map(&:keys)).to eq((36..45).map { |k| [k, k] })
      expect(inst.regions[5].sample).to be_reversed
      expect(b.keymap(spread: 3).regions.first.keys).to eq([36, 38])
      expect { b.keymap(from: 125) }.to raise_error(ArgumentError, /don't fit/)
      sp = b.keymap(from: 48, split: 58)
      expect(sp.split).to eq(58)
      expect(sp.regions.length).to eq(10) # 48..57, below the split
    end

    it 'pitch marks notes and steps, printing and reading them' do
      st = MB::Sound::C4.pitch(1.5)
      expect(st.pitch).to eq(1.5)
      expect(st.value).to eq(60)
      c = MB::Sound.seq(MB::Sound::C4.pitch(-2), MB::Sound::E4).n8
      expect(c.events.map(&:pitch)).to eq([-2.0, nil])
      expect(c.transpose(1).events.map { |e| [e.value, e.pitch] }).to eq([[60, -1.0], [65, nil]])
      expect(c.events[0].to_s).to include('pitch-2')
      e = MB::Sound.events([0r, 1r/8, 38, 0.75, { pitch: 3.0 }], length: 1r/4)
      expect(e.events[0].pitch).to eq(3.0)
    end
  end

  describe 'files' do
    it 'saves and reads back the audio and settings' do
      path = tmp_path('ramp.flac')
      v = s.looped(100...300, mode: :release).rev.transpose(2).gain(0.5).with(bpm: 140)[10...4700]
      v.save(path)
      back = MB::Sound::Sample[path]
      expect(back.length).to eq(v.length)
      expect(back.loop_points).to eq(v.loop_points)
      expect(back.loop_mode).to eq(:release)
      expect(back).to be_reversed
      expect(back.tune).to eq(2)
      expect(back.bpm).to eq(140)
      expect(back.file).to eq(File.expand_path(path))
      expect((back.data - v.data).abs.max).to be < 1e-5
    end

    it 'saves and reads back the read settings' do
      path = tmp_path('drop.flac')
      s.read_as(:drop, mips: :octave).save(path)
      back = MB::Sound::Sample[path]
      expect([back.interpolation, back.mips]).to eq([:none, :octave])

      path = tmp_path('ratio.flac')
      s.read_as(interpolation: :cubic, mips: false).save(path)
      expect([MB::Sound::Sample[path].interpolation, MB::Sound::Sample[path].mips]).to eq([:cubic, false])
      path = tmp_path('spacing.flac')
      s.read_as(mips: 1.5).save(path)
      expect(MB::Sound::Sample[path].mips).to eq(1.5)
    end
  end
end
