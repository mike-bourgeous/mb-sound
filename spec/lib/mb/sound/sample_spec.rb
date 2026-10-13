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

    it 'stretches cyclically to the asked length at the same pitch' do
      sine = ->(n) { Numo::SFloat.cast(Numo::DFloat.new(n).seq.map { |i| Math.sin(i * 2 * Math::PI * 500 / 48000) }) }
      x = MB::Sound::Sample[sine.(4800)]
      y = x.stretch(2, cycle: 20.ms)
      expect(y.length).to eq(9600)
      # 20 ms cycles of 500 Hz taken every 10 ms: whole periods, so seamless
      expect((y.data[0...9000] - sine.(9000)).abs.max).to be < 1e-5
      z = x.stretch(1.5, cycle: 7.ms, crossfade: 1.ms)
      expect(z.length).to eq(7200)
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

    it 'makes chop clips addressing slices with pitch and reverse apart' do
      b = s.slices(4).name(two: 2..3)
      c = b.chop(0, MB::Sound::Tie, [1, 2], :two, b[1].rev.transpose(-3), MB::Sound::Rest, [3, 0, { vel: 0.3 }])
      vals = c.events.map(&:value)
      expect(vals).to eq([
        MB::Sound::Sampler.chop_note(0), MB::Sound::Sampler.chop_note(1, 2), MB::Sound::Sampler.chop_note(4),
        MB::Sound::Sampler.chop_note(1, -3, reverse: true), MB::Sound::Sampler.chop_note(3),
      ])
      expect(c.events[0].length).to eq(1/8r)
      expect(c.events.last.velocity).to eq(0.3)
      expect(c.transpose(2).events[1].value).to eq(MB::Sound::Sampler.chop_note(1, 4))
      expect(MB::Sound::Sampler.chop_hit(MB::Sound::Sampler.chop_note(5, -2.5, reverse: true))).to eq([5, -2.5, true])
      expect { b.chop(:nope) }.to raise_error(ArgumentError)
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
  end
end
