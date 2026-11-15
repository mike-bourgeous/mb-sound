RSpec.describe('loop files and the slice stretch', :aggregate_failures) do
  let(:noise) { Numo::SFloat.new(44100).rand(-0.5, 0.5) }
  let(:riff) { MB::Sound::Sample::Riff }
  let(:info) { MB::Sound::Sample::LoopInfo }

  def write_wav(name, data = noise, **options)
    path = tmp_path(name)
    MB::Sound::Sample::Riff.write(path, data, sample_rate: 44100, **options)
  end

  describe MB::Sound::Sample::Riff do
    it 'reads acid, smpl, cue, and labels' do
      path = write_wav(
        'loop.wav', [noise, noise * 0.5],
        acid: { tempo: 98.5, beats: 8, root: 57, meter: [7, 8] },
        smpl: { unity_note: 57, pitch_fraction: 0.25, loops: [[100, 40000, :ping_pong]] },
        cues: [[0, 'kick'], [11025, 'snare'], 22050],
        info: { 'INAM' => 'Test loop' }
      )
      i = riff.read(path)
      expect(i.container).to eq(:riff)
      expect(i.format.channels).to eq(2)
      expect(i.format.sample_rate).to eq(44100)
      expect(i.frames).to eq(44100)
      expect(i.seconds).to eq(1.0)
      expect(i.acid.tempo).to eq(98.5)
      expect(i.acid.beats).to eq(8)
      expect(i.acid.meter).to eq([7, 8])
      expect(i.acid.root).to eq(57)
      expect(i.acid).to be_root_set
      expect(i.acid).to be_stretch
      expect(i.acid).not_to be_one_shot
      expect(i.smpl.unity_note).to eq(57)
      expect(i.smpl.pitch_fraction).to be_within(1e-9).of(0.25)
      expect(i.smpl.loops.map { |l| [l.start, l.stop, l.type] }).to eq([[100, 40000, :ping_pong]])
      expect(i.cues.map { |c| [c.position, c.label] }).to eq([[0, 'kick'], [11025, 'snare'], [22050, nil]])
      expect(i.info).to eq('INAM' => 'Test loop')
    end

    it 'handles odd chunks with and without pad bytes, unknown chunks, RF64, and WAVE_FORMAT_EXTENSIBLE' do
      odd = [['junk', 'abc'], ['zzz1', "\x01\x02\x03\x04\x05".b]]
      a = riff.read(write_wav('padded.wav', extra: odd, acid: { tempo: 120.0, beats: 4 }))
      b = riff.read(write_wav('unpadded.wav', extra: odd, acid: { tempo: 120.0, beats: 4 }, pad: false))
      [a, b].each do |i|
        expect(i.chunks.map(&:first)).to eq(['fmt ', 'acid', 'junk', 'zzz1', 'data'])
        expect(i.frames).to eq(44100)
        expect(i.acid.tempo).to eq(120.0)
      end

      c = riff.read(write_wav('rf64.wav', bits: :float, rf64: true, extensible: true, acid: { tempo: 90.0, beats: 2 }))
      expect(c.container).to eq(:rf64)
      expect(c.format.tag).to eq(0xFFFE)
      expect(c.format.subformat).to eq(3)
      expect(c.frames).to eq(44100)
      expect(c.acid.tempo).to eq(90.0)
      expect(MB::Sound::Sample[tmp_path('rf64.wav')].length).to eq(48000)
    end

    it 'never trusts sizes beyond the file' do
      path = write_wav('cut.wav', acid: { tempo: 100.0, beats: 4 }, cues: [0, 100])
      bytes = File.binread(path)
      # Truncated audio: the data chunk's size is clamped to the file
      File.binwrite(tmp_path('trunc.wav'), bytes[0, bytes.length - 20001])
      t = riff.read(tmp_path('trunc.wav'))
      expect(t.acid.tempo).to eq(100.0)
      expect(t.frames).to eq((88200 - 20001) / 2)

      # A chunk claiming 2 GB, and a cue count larger than its chunk
      huge = bytes.sub('acid'.b + [24].pack('V'), 'acid'.b + [0x7FFFFFF0].pack('V'))
      File.binwrite(tmp_path('huge.wav'), huge)
      h = riff.read(tmp_path('huge.wav'))
      expect(h.acid).to be_nil
      expect(h.chunks.map(&:first)).to eq(['fmt ', 'acid'])

      lying = bytes.sub('cue '.b + [52].pack('V') + [2].pack('V'), 'cue '.b + [52].pack('V') + [1000].pack('V'))
      File.binwrite(tmp_path('lying.wav'), lying)
      expect(riff.read(tmp_path('lying.wav')).cues.map(&:position)).to eq([0, 100])

      # Short and garbage files
      File.binwrite(tmp_path('short.wav'), 'RIFF'.b)
      expect(riff.read(tmp_path('short.wav'))).to be_nil
      File.binwrite(tmp_path('garbage.wav'), 'RIFF'.b + [100].pack('V') + 'WAVE'.b + "\xff\xfe\x00\x01garbage".b)
      expect(riff.read(tmp_path('garbage.wav')).chunks).to eq([])
      expect { riff.read!(tmp_path('short.wav')) }.to raise_error(riff::NotWave)
    end

    it 'leaves out chunks too short for their layout' do
      path = write_wav('short_acid.wav', extra: [['acid', "\x01\x00".b], ['smpl', 'x' * 10]])
      i = riff.read(path)
      expect(i.acid).to be_nil
      expect(i.smpl).to be_nil
      expect(i.frames).to eq(44100)
    end
  end

  describe MB::Sound::Sample::LoopInfo do
    it 'finds tempo and key words in names' do
      expect(info.parse_name('funk_98bpm')).to eq(bpm: 98.0, key: nil)
      expect(info.parse_name('98 BPM break')).to eq(bpm: 98.0, key: nil)
      expect(info.parse_name('bpm140_Dm')).to eq(bpm: 140.0, key: :Dm)
      expect(info.parse_name('Am_120')).to eq(bpm: 120.0, key: :Am)
      expect(info.parse_name('loop-120-C#m')).to eq(bpm: 120.0, key: :'C#m')
      expect(info.parse_name('House_128_F_minor')).to eq(bpm: 128.0, key: :Fm)
      expect(info.parse_name('Ebmaj7_pad')).to eq(bpm: nil, key: :Eb)
      expect(info.parse_name('drum_loop_01')).to eq(bpm: nil, key: nil)
      expect(info.parse_name('am I a loop')).to eq(bpm: nil, key: nil)
      expect(info.parse_name('Loop A')).to eq(bpm: nil, key: nil) # a lone letter only with a tempo
      expect(info.parse_name('Loop A 90')).to eq(bpm: 90.0, key: :A)
      expect(info.parse_name('take 2 of 3 120 bpm 90')).to eq(bpm: 120.0, key: nil)
    end

    it 'reads folder names and estimates beats from the length' do
      dir = tmp_path('Funk 100 BPM')
      Dir.mkdir(dir)
      path = File.join(dir, 'Gm groove.wav')
      MB::Sound::Sample::Riff.write(path, Numo::SFloat.zeros(44100 * 24 / 10), sample_rate: 44100)
      e = info.read(path)
      expect(e.bpm).to eq(100.0)
      expect(e.key).to eq(:Gm)
      expect(e.beats).to eq(4)
      expect(e.bars).to eq(1)
      expect(e.sources).to eq(bpm: :name, key: :name, beats: :name, one_shot: :name)
      expect(e.one_shot).to eq(false)
      expect(e.why).to eq(bpm: 'name 100 (fits 4 beats)', one_shot: "name 'groove'")
    end

    it 'prefers chunks over names' do
      e = info.read(write_wav('loop_120bpm.wav', acid: { tempo: 98.0, beats: 2 }))
      expect(e.bpm).to eq(98.0)
      expect(e.sources[:bpm]).to eq(:acid)
      expect(e.to_s).to eq('loop_120bpm.wav: 98 BPM, 2 beats')
    end

    it 'reads FLAC tags and lengths without decoding' do
      path = tmp_path('pad.flac')
      MB::Sound.write(path, [Numo::SFloat.zeros(96000)], metadata: { BPM: '87', KEY: 'F#m' })
      e = info.read(path)
      expect(e.format).to eq(:flac)
      expect(e.seconds).to eq(2.0)
      expect(e.bpm).to eq(87.0)
      expect(e.key).to eq(:'F#m')
      expect(e.sources).to include(bpm: :tags, key: :tags)
      s = MB::Sound::Sample[path]
      expect(s.bpm).to eq(87.0)
      expect(s.key).to eq(:'F#m')
    end

    it 'scans folders' do
      dir = tmp_path('lib')
      Dir.mkdir(dir)
      MB::Sound::Sample::Riff.write(File.join(dir, 'a_90bpm.wav'), Numo::SFloat.zeros(48000 * 8 / 3)) # 4 beats at 90
      MB::Sound::Sample::Riff.write(File.join(dir, 'b.wav'), Numo::SFloat.zeros(100), acid: { tempo: 120.0, beats: 1 })
      File.write(File.join(dir, 'notes.txt'), 'x')
      expect(info.scan(dir).map { |e| [File.basename(e.path), e.bpm] }).to eq([['a_90bpm.wav', 90.0], ['b.wav', 120.0]])
    end
  end

  describe 'Sample metadata' do
    it 'reads ACID tempo, beats, root, loop, and markers at 48 kHz' do
      path = write_wav(
        'loop.wav', acid: { tempo: 98.0, beats: 8, root: 57 },
        smpl: { unity_note: 57, loops: [[100, 40000]] }, cues: [[0, 'kick'], [11025, 'snare']]
      )
      s = MB::Sound::Sample[path]
      expect(s.length).to eq(48000)
      expect(s.bpm).to eq(98.0)
      expect(s.beats).to eq(8)
      expect(s.bars).to eq(2)
      expect(s.meter).to eq([4, 4])
      expect(s.root).to eq(57)
      expect(s.loop_points).to eq([0.0, 48000.0]) # ACID loops loop the whole file, whatever smpl says
      expect(s.loop_mode).to eq(:forward)
      # (round 2's layers: the smpl loop is a fact the ACID loop didn't use, so description)
      expect(s.meta[:source][:fields]['smpl.loop[0]']).to eq([100, 40000, :forward])
      expect(s.provenance(:bpm).fact).to eq('acid.tempo')
      expect(s.provenance(:markers).via).to eq(:cue)
      expect(s.markers.map(&:to_h)).to eq([{ position: 0, label: 'kick' }, { position: 12000, label: 'snare' }])
      expect(s.meta_source).to include(bpm: :acid, one_shot: :acid, markers: :cue)

      # Options win; views keep markers in play order; trims recount beats
      expect(MB::Sound::Sample[path, bpm: 120].bpm).to eq(120.0)
      expect(s.rev.markers.map(&:position)).to eq([35999, 47999])
      expect(s.trim(6000..).markers.map(&:position)).to eq([6000])
      expect(s.trim(0...24000).beats).to be_within(1e-9).of(0.5 * 98 / 60) # from the tempo: the file's 8 beats were the whole file
    end

    it 'loops ACID loops without smpl and keeps one-shots one-shot' do
      expect(MB::Sound::Sample[write_wav('l.wav', acid: { tempo: 100.0, beats: 2 })].loop_mode).to eq(:forward)
      o = MB::Sound::Sample[write_wav('o.wav', acid: { one_shot: true, tempo: 0.0, beats: 0 })]
      expect(o).to be_one_shot
      expect(o.bpm).to be_nil
    end

    it 'saves and reads back the metadata in tags' do
      s = MB::Sound::Sample[noise, bpm: 98, beats: 2, meter: [3, 4], key: :Am, markers: [[0, 'a;b%'], 1000]]
      s.save(tmp_path('x.flac'))
      r = MB::Sound::Sample[tmp_path('x.flac')]
      expect(r.bpm).to eq(98.0)
      expect(r.beats).to eq(2)
      expect(r.meter).to eq([3, 4])
      expect(r.key).to eq(:Am)
      expect(r.markers.map { |m| [m.position, m.label] }).to eq([[0, 'a;b%'], [1000, nil]])
    end

    it 'detects tempo when asked, cached' do
      rec = MB::Sound.bounce(2.bars, bpm: 112) { MB::Sound.tr808(MB::Sound.grid(16, kick: 'X...X...X...X...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) }
      plain = MB::Sound::Sample[rec.to_a]
      expect(plain.bpm).to be_nil
      d = plain.detect_tempo
      expect(d.bpm).to be_within(0.01).of(112)
      expect(d.beats).to eq(8)
      expect(d.meta_source[:bpm]).to eq(:detected)
      expect(plain.detect_tempo.bpm).to eq(d.bpm)

      rec.save(tmp_path('beat.flac'))
      expect(MB::Sound::Sample[tmp_path('beat.flac')].bpm).to eq(112.0) # the tag
      MB::Sound.write(tmp_path('plain.flac'), rec.to_a)
      expect(MB::Sound::Sample[tmp_path('plain.flac')].bpm).to be_nil
      expect(MB::Sound::Sample[tmp_path('plain.flac'), detect: true].bpm).to be_within(0.01).of(112)
    end
  end

  describe 'Sample#stretch(mode: :slice)' do
    let(:rec) { MB::Sound.bounce(2.bars, bpm: 100) { MB::Sound.tr909(MB::Sound.grid(16, kick: 'X...x...x..xx...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) } }

    it 'gives the input back at ratio 1' do
      expect(rec.stretch(1, mode: :slice).data(0)).to eq(rec.data(0))
    end

    it 'starts every slice exactly at its scaled time' do
      cuts = rec.onsets.select(&:positive?)
      expect(cuts.length).to be > 10
      [0.78125, 1.25].each do |r|
        s = rec.stretch(r, mode: :slice)
        expect(s.length).to eq((rec.length * r).round)
        expect(s.bpm).to be_within(1e-9).of(100 / r)
        expect(s.beats).to eq(8)
        x = rec.data(0)
        y = s.data(0)
        ([0] + cuts).each_cons(2) do |a, b|
          q = (a * r).round
          n = [32, b - a].min
          expect(y[q...(q + n)]).to eq(x[a...(a + n)])
        end
      end
    end

    # Eight gated kicks, one every 12000 samples (a click, a 45-120 Hz
    # body that stops after 70 ms, and a quiet 220 Hz ring to the next
    # hit): hit times known to the sample, and a decay that has somewhere
    # to be drawn out
    def kick_loop(hits: 8, step: 12000)
      t = Numo::DFloat.new(step).seq / 48000.0
      phase = 50 * t + 70 * 0.03 * (1 - Numo::NMath.exp(-t / 0.03))
      body = Numo::NMath.sin(phase * 2 * Math::PI) * Numo::NMath.exp(-(t - 0.07).clip(0, nil) / 0.005) * 0.8
      click = Numo::NMath.sin(t * (2 * Math::PI * 3000)) * Numo::NMath.exp(-t / 0.002) * 0.4
      ring = Numo::NMath.sin(t * (2 * Math::PI * 220)) * Numo::NMath.exp(-t / 0.4) * 0.03
      x = Numo::DFloat.zeros(hits * step)
      hits.times { |i| x[(i * step)...((i + 1) * step)] = (body + click + ring) * (i.odd? ? 0.7 : 1.0) }
      x
    end

    # The largest and smallest 5 ms RMS of v, measured every 2.5 ms
    def rms_range(v)
      levels = (0..(v.length - 240)).step(120).map { |k| Math.sqrt((v[k...(k + 240)]**2).mean) }
      [levels.max, levels.min]
    end

    it 'fill: :stretch keeps each hit whole and draws its tail out to the next hit' do
      x = kick_loop
      smp = MB::Sound::Sample[Numo::SFloat.cast(x), bpm: 120]
      cuts = (1...8).map { |i| (i * 12000).samples }
      { 1.25 => [0.03, 0.02], 2 => [0.08, 0.02] }.each do |r, (body_limit, tail_limit)|
        slot = 12000 * r
        fills = %i[gap stretch].to_h { |fill| [fill, Numo::DFloat.cast(smp.stretch(r, mode: :slice, slices: cuts, fill: fill).data(0))] }
        body = fills.transform_values { 0.0 }
        tails = fills.transform_values { [0.0, 1.0] }
        8.times do |i|
          q = (i * slot).round
          a = i * 12000
          fills.each do |fill, y|
            # (every attack lands on its stretched time, sample for sample)
            expect((y[q...(q + 720)] - x[a...(a + 720)]).abs.max).to be < 1e-6
            body[fill] = [body[fill], (y[q...(q + 4000)] - x[a...(a + 4000)]).abs.max].max
            hi, lo = rms_range(y[(q + 7000)...(q + slot - 480)])
            tails[fill] = [[tails[fill][0], hi].max, [tails[fill][1], lo].min]
          end
        end

        # The hit's body (its first 83 ms) is the input's, within the
        # level correction's fraction of a dB (the fill before
        # stretch-fixes-1, the plain cyclic stretch of everything after
        # 15 ms, was 0.5 off: the kick played on past its end, spliced)
        expect(body[:gap]).to be < 1e-6
        expect(body[:stretch]).to be < body_limit

        # After the hit the ring carries on at its own level (0.015 RMS
        # in the input) to the next hit: no gap, and nothing louder (no
        # second hit)
        expect(tails[:gap][1]).to eq(0)
        expect(tails[:stretch][1]).to be > 0.005
        expect(tails[:stretch][0]).to be < tail_limit
      end
    end

    it 'fill: :stretch draws a held sound out evenly, without steps in level' do
      # (a 110 Hz tone with a slow 3 Hz tremolo, cut in four: no part of
      # it dies down, so the whole of each slice takes the stretch)
      t = Numo::DFloat.new(48000).seq / 48000.0
      x = Numo::NMath.sin(t * (2 * Math::PI * 110)) * (0.6 + 0.2 * Numo::NMath.sin(t * (2 * Math::PI * 3)))
      smp = MB::Sound::Sample[Numo::SFloat.cast(x), bpm: 120]
      y = Numo::DFloat.cast(smp.stretch(1.5, mode: :slice, slices: 4, fill: :stretch).data(0))
      expect(y.length).to eq(72000)
      env = MB::Sound::Sample::SliceStretch.envelope(y, 480)
      want = MB::Sound::Sample::SliceStretch.envelope(x, 480)
      (2400...69600).step(600) do |k|
        expect(env[k] / want[(k / 1.5).round]).to be_within(0.12).of(1)
      end
    end

    it 'fill: :stretch fills slices too short for its usual attack and cycles (a one-shot saved as a loop)' do
      # (a ringing stab, a marker every 58 ms: slices of 2800 samples
      # against the 3120 of a 15 ms attack and two 25 ms cycles)
      t = Numo::DFloat.new(25200).seq / 48000.0
      x = (Numo::NMath.sin(t * (2 * Math::PI * 220)) + Numo::NMath.sin(t * (2 * Math::PI * 277)) * 0.7) * Numo::NMath.exp(-t / 0.25) * 0.4
      stab = MB::Sound::Sample[Numo::SFloat.cast(x), bpm: 120]
      cuts = (1...9).map { |i| (i * 2800).samples }
      [2, 3.82, 8].each do |r|
        gap = Numo::DFloat.cast(stab.stretch(r, mode: :slice, slices: cuts).data(0))
        filled = Numo::DFloat.cast(stab.stretch(r, mode: :slice, slices: cuts, fill: :stretch).data(0))
        9.times do |i|
          q = (i * 2800 * r).round
          expect((filled[q...(q + 700)] - x[(i * 2800)...(i * 2800 + 700)]).abs.max).to be < 1e-6
          # Each slot rings to its end at about the slice's level; with
          # gaps it is silent from the slice's end on
          tail = (q + 2800 + 240)...((q + 2800 * r).round - 240)
          expect(rms_range(gap[tail])[0]).to eq(0)
          hi, lo = rms_range(filled[tail])
          level = Math.sqrt((x[(i * 2800)...((i + 1) * 2800)]**2).mean)
          expect(lo).to be > 0.25 * level
          expect(hi).to be < 1.6 * level
        end
      end
      # (under 5 ms a slice plays with a gap)
      tiny = (1...126).map { |i| (i * 200).samples }
      expect(stab.stretch(2, mode: :slice, slices: tiny, fill: :stretch).data(0)).to eq(stab.stretch(2, mode: :slice, slices: tiny).data(0))
      expect { stab.stretch(2, mode: :slice, fill: :cyclic) }.to raise_error(ArgumentError, /fill: is one of/)
      # (both named fills fill them too)
      %i[even decay].each do |fill|
        filled = Numo::DFloat.cast(stab.stretch(3.82, mode: :slice, slices: cuts, fill: fill).data(0))
        expect(rms_range(filled[4000...(25200 * 3.82).round - 4000])[1]).to be > 0.002
      end
    end

    it 'fill: :stretch picks per slice: a hit that dies down keeps its body, anything else is drawn out evenly' do
      pick = MB::Sound::Sample::SliceStretch.method(:fill_kind)
      kick = kick_loop(hits: 1)
      t = Numo::DFloat.new(12000).seq / 48000.0
      held = Numo::NMath.sin(t * (2 * Math::PI * 220)) * Numo::NMath.exp(-t / 0.5) * 0.5
      second = kick.dup
      second[6000...12000] += Numo::NMath.sin(t[0...6000] * (2 * Math::PI * 330)) * Numo::NMath.exp(-t[0...6000] / 0.05) * 0.3
      expect(pick.call(kick, 0, 12000, 48000)).to eq(:decay)
      expect(pick.call(held, 0, 12000, 48000)).to eq(:even)
      expect(pick.call(second, 0, 12000, 48000)).to eq(:even)
      expect(pick.call(Numo::DFloat.zeros(12000), 0, 12000, 48000)).to eq(:even)

      # Two slices of each kind in one loop: the picker's result is the
      # named fill's in each slot
      x = Numo::DFloat.zeros(48000)
      [kick, second, held, kick].each_with_index { |v, i| x[(i * 12000)...((i + 1) * 12000)] = v }
      smp = MB::Sound::Sample[Numo::SFloat.cast(x), bpm: 120]
      cuts = [12000, 24000, 36000].map(&:samples)
      fills = %i[stretch even decay gap].to_h { |f| [f, Numo::DFloat.cast(smp.stretch(1.5, mode: :slice, slices: cuts, fill: f).data(0))] }
      { 0 => :decay, 1 => :even, 2 => :even, 3 => :decay }.each do |i, kind|
        slot = (i * 18000 + 1000)...(i * 18000 + 17000)
        expect(fills[:stretch][slot]).to eq(fills[kind][slot])
        expect(fills[:stretch][slot]).not_to eq(fills[kind == :even ? :decay : :even][slot])
      end

      # The second sound of slice 1 (6000 samples in) lands near its
      # stretched time under the even fill (9000 samples in: within
      # 25 ms, early, as the fitted cyclic stretch runs), 62 ms early
      # with a gap, and where the level sends it under :decay
      ref = x[18000...18480]
      place = ->(y) { (18000...18000 + 18000 - 480).max_by { |q| (y[q...(q + 480)] * ref).sum / Math.sqrt((y[q...(q + 480)]**2).sum + 1e-12) } - 18000 }
      expect(place.call(fills[:gap])).to eq(6000)
      expect(place.call(fills[:even])).to be_between(9000 - 1200, 9000 + 240)
      expect(place.call(fills[:stretch])).to eq(place.call(fills[:even]))
      expect(fills[:stretch].length).to eq(72000)
    end

    it 'plans a fill that starts with the input and ends where it ends (Lofi.anchored_plan)' do
      x = kick_loop(hits: 1)[720..]
      plan = MB::Sound::Sample::Lofi.anchored_plan(x, 15000, 1200)
      expect(plan.first[0..1]).to eq([0, 0])
      expect(plan.map { |c| c[2] }.sum).to eq(15000)
      plan.each_cons(2) { |a, b| expect(b[0]).to eq(a[0] + a[2]) }
      expect(plan.last[1] + plan.last[2]).to be_between(x.length - 2 * 660, x.length)
      expect(plan.map { |c| c[1] + c[2] }.max).to be <= x.length
      expect { MB::Sound::Sample::Lofi.anchored_plan(x[0...500], 3000, 1200) }.to raise_error(ArgumentError, /at least a cycle/)
    end

    it 'fades instead of clicking' do
      [0.7, 1.4].each do |r|
        [:gap, :stretch, :even, :decay].each do |fill|
          y = Numo::DFloat.cast(rec.stretch(r, mode: :slice, fill: fill).data(0))
          jumps = (y[1..] - y[0...-1]).abs
          expect(jumps.max).to be < (Numo::DFloat.cast(rec.data(0))[1..] - Numo::DFloat.cast(rec.data(0))[0...-1]).abs.max * 1.01
        end
      end
    end

    it 'takes slices from markers, grids, counts, and positions' do
      a = rec.stretch(1.5, mode: :slice, slices: :grid)
      b = rec.stretch(1.5, mode: :slice, slices: 32)
      expect(a.data(0)).to eq(b.data(0))
      m = MB::Sound::Sample[rec.to_a, bpm: 100, markers: [0, 24000, 48000]]
      expect(m.stretch(2, mode: :slice).data(0)).to eq(rec.stretch(2, mode: :slice, slices: [0, 24000, 48000]).data(0))
      expect(rec.stretch(2, mode: :slice, slices: rec.slices(4)).length).to eq(rec.length * 2)
      expect { MB::Sound::Sample[rec.to_a].stretch(2, mode: :slice, slices: :grid) }.to raise_error(ArgumentError, /bpm/)
      expect { rec.stretch(2, mode: :slice, window: 1024) }.to raise_error(ArgumentError, /slice takes/)
      expect { rec.stretch(2, fill: :gap) }.to raise_error(ArgumentError, /for mode: :slice/)
    end

    it 'cuts only where a transient is with slices: :transients, so the timing holds' do
      on = rec.onsets
      expect(on.length).to be >= 12
      # (markers: one 5 ms before a hit, one inside a decay, one on a hit,
      # one 75 ms after a hit: with or without them every hit the
      # detector is sure of cuts on its attack)
      m = rec.with(markers: [on[1] - 240, on[1] + 7200, on[3], on[5] + 3600])
      with_markers = Numo::DFloat.cast(m.stretch(1.5, mode: :slice, slices: :transients).data(0))
      on.each { |o| q = (o * 1.5).round; expect((with_markers[q...(q + 480)] - rec.data(0)[o...(o + 480)]).abs.max).to be < 1e-6 }
      expect(m.stretch(1.5, mode: :slice, slices: :transients, confirm: false).data(0)).to eq(m.stretch(1.5, mode: :slice, slices: on).data(0))
      expect(m.stretch(1.5, mode: :slice, slices: :transients, confirm: false).lineage[3]).to eq({ mode: :slice, slices: :transients, confirm: false })

      # Soft hits (two bursts of hiss 6 dB up, between two loud ones): a
      # marker stands for the first (set 5 ms after its attack), none for
      # the second.  The first gets a cut, on its attack; the second
      # keeps its distance from the cut before it (early when slowing).
      Numo::NArray.srand(21)
      x = Numo::DFloat.new(96000).rand(-0.05, 0.05)
      burst = Numo::NMath.sin(Numo::DFloat.new(2400).seq * 0.9) * Numo::NMath.exp(-Numo::DFloat.new(2400).seq / 300.0) * 0.6
      [12000, 60000].each { |h| x[h...(h + 2400)] += burst }
      [30000, 80000].each { |h| x[h...(h + 4800)] += Numo::DFloat.new(4800).rand(-0.09, 0.09) * Numo::NMath.exp(-Numo::DFloat.new(4800).seq / 2400.0) }
      hiss = MB::Sound::Sample[Numo::SFloat.cast(x)]
      sure = hiss.onsets
      soft = hiss.onsets(threshold: 4.db) - sure
      expect(sure.map { |o| (o / 100.0).round }).to eq([0, 120, 600])
      expect(soft.map { |o| (o / 1000.0).round }).to eq([30, 80])
      marked = hiss.with(markers: [soft[0] + 240, sure[1] + 3000])
      cut = marked.stretch(1.25, mode: :slice, slices: :transients)
      expect(cut.data(0)).to eq(hiss.stretch(1.25, mode: :slice, slices: sure + [soft[0]]).data(0))
      out = Numo::DFloat.cast(cut.data(0))
      q = (soft[0] * 1.25).round
      expect((out[q...(q + 480)] - x[soft[0]...(soft[0] + 480)]).abs.max).to be < 1e-6
      late = soft[1] + ((sure[2] * 1.25).round - sure[2])
      expect((out[late...(late + 480)] - x[soft[1]...(soft[1] + 480)]).abs.max).to be < 1e-6
      expect(late - soft[1] * 1.25).to be < -4000
      # (a reach of 2 ms: the marker 5 ms off stands for nothing; a
      # threshold given: the onsets of that threshold, no softer ones)
      expect(marked.stretch(1.25, mode: :slice, slices: :transients, confirm: 0.002).data(0)).to eq(hiss.stretch(1.25, mode: :slice, slices: sure).data(0))
      expect(marked.stretch(1.25, mode: :slice, slices: :transients, threshold: 9.db).data(0)).to eq(hiss.stretch(1.25, mode: :slice, slices: sure).data(0))
      expect(marked.stretch(1.25, mode: :slice, slices: :transients, confirm: false, threshold: 4.db).data(0)).to eq(hiss.stretch(1.25, mode: :slice, slices: sure + soft).data(0))

      # Without markers every detected onset (+threshold+ as Onsets takes it)
      expect(rec.stretch(1.5, mode: :slice, slices: :transients).data(0)).to eq(rec.stretch(1.5, mode: :slice, slices: on).data(0))
      loud = rec.onsets(threshold: 20.db)
      expect(loud.length).to be < on.length
      expect(rec.stretch(1.5, mode: :slice, slices: :transients, threshold: 20.db).data(0)).to eq(rec.stretch(1.5, mode: :slice, slices: loud).data(0))

      # Every hit lands on its stretched time, and the loop keeps its length
      st = rec.stretch(1.5, mode: :slice, slices: :transients)
      expect(st.length).to eq((rec.length * 1.5).round)
      got = st.onsets
      out = Numo::DFloat.cast(st.data(0))
      src = Numo::DFloat.cast(rec.data(0))
      on.each { |o| q = (o * 1.5).round; expect((out[q...(q + 480)] - src[o...(o + 480)]).abs.max).to be < 1e-6 }
      # (detected again within the 4 ms pre-roll that leads into each)
      expect(on.map { |o| got.map { |g| (g - o * 1.5).abs }.min }.max).to be <= 192

      expect { rec.stretch(1.5, mode: :slice, slices: :markers, confirm: true) }.to raise_error(ArgumentError, /slices: :transients/)
      expect { rec.stretch(1.5, mode: :spectral, threshold: 6.db) }.to raise_error(ArgumentError, /slices: :transients/)
      expect { m.stretch(1.5, mode: :slice, slices: :transients, confirm: :yes) }.to raise_error(ArgumentError, /confirm: is/)
      expect { rec.stretch(1.5, mode: :slice, slices: :beats) }.to raise_error(ArgumentError, /slices: is/)
    end

    # The rule slot_fade: follows, written out per slot: a slice cut
    # short plays from its cut for its slot (to the next cut's new
    # place), as it is for the first 1 - share of the slot, then fading
    # out over the rest while the audio that led up to the next cut
    # fades in over the same samples, arriving at the next cut in step.
    # law :power: a cosine out and a sine in; :linear: raised cosines.
    def slot_fade_reference(x, cuts, ratio, share, law, places = nil)
      len = x.length
      p = (cuts.select { |c| c > 0 && c < len } + [0, len]).uniq.sort
      q = places || p.map { |c| (c * ratio).round }
      out = Numo::DFloat.zeros(q.last)
      (p.length - 1).times do |i|
        slot = q[i + 1] - q[i]
        raise 'the reference is for slices cut short' unless slot < p[i + 1] - p[i]
        f = (slot * share).round
        theta = Numo::DFloat.zeros(slot)
        theta[(slot - f)..] = (Numo::DFloat.new(f).seq + 0.5) / f * (Math::PI / 2) if f > 0
        gain_out = law == :power ? Numo::NMath.cos(theta) : Numo::NMath.cos(theta)**2
        gain_in = law == :power ? Numo::NMath.sin(theta) : Numo::NMath.sin(theta)**2
        out[q[i]...q[i + 1]] = x[p[i]...(p[i] + slot)] * gain_out + x[(p[i + 1] - slot)...p[i + 1]] * gain_in
      end
      out
    end

    # Two seconds of quiet stereo noise (the channels differ) with a
    # click on every cut and one 10 ms before every cut and the end
    def clicks_and_cuts
      Numo::NArray.srand(11)
      cuts = [0, 12000, 24000, 24100, 40000, 61000, 72000, 84000]
      len = 96000
      x = [Numo::DFloat.new(len).rand(-0.05, 0.05), Numo::DFloat.new(len).rand(-0.05, 0.05)]
      cuts.each { |c| x.each { |ch| ch[c] = 0.9 } }
      (cuts[1..] + [len]).each { |c| x.each { |ch| ch[c - 480] = -0.7 } }
      [MB::Sound::Sample[x.map { |ch| Numo::SFloat.cast(ch) }, bpm: 120], cuts]
    end

    it 'slot_fade: crossfades each slice cut short into what led up to the next cut, in proportion to its slot' do
      smp, cuts = clicks_and_cuts
      len = smp.length
      x = [0, 1].map { |ch| Numo::DFloat.cast(smp.data(ch)) }
      [0.8, 0.528].each do |r|
        q = (cuts + [len]).map { |c| (c * r).round }
        [[2/3r, :power], [2/3r, :linear], [0.25, :power], [1, :power]].each do |share, law|
          kw = law == :linear ? { slot_fade: share } : { slot_fade: share, fade_law: law }
          s = smp.stretch(r, mode: :slice, slices: cuts, **kw)
          expect(s.length).to eq((len * r).round)
          # (the reference within 1e-6 of full scale, -120 dB: the
          # output is single precision)
          2.times { |ch| expect((Numo::DFloat.cast(s.data(ch)) - slot_fade_reference(x[ch], cuts, r, share, law)).abs.max).to be < 1e-6 }
        end

        s = smp.stretch(r, mode: :slice, slices: cuts, slot_fade: 2/3r, fade_law: :power)
        y = Numo::DFloat.cast(s.data(0))
        plain = Numo::DFloat.cast(smp.stretch(r, mode: :slice, slices: cuts).data(0))
        cuts.each_with_index do |c, i|
          # A hit on a cut: there, and the first third of its slot the input's, sample for sample
          third = (q[i + 1] - q[i]) - ((q[i + 1] - q[i]) * 2/3r).round
          expect(s.data(0)[q[i]...(q[i] + third)]).to eq(smp.data(0)[c...(c + third)])
          # A hit 10 ms before the next cut (or the loop's end, which
          # leads into the first cut): 10 ms before it still, within 4%
          # of its level (its gain is 0.984 or more there, and the
          # noise going out adds up to 0.009); the fixed 4 ms fade has
          # cut it off, except in a slot too short to (the 100-sample
          # slice)
          at = q[i + 1] - 480
          next if at < q[i]
          expect(y[at]).to be_within(0.028).of(-0.7)
          expect(y[(at - 24)..(at + 24)].abs.max_index).to eq(24)
          expect(plain[at].abs).to be < 0.06 if q[i + 1] - q[i] > 4000
        end
      end

      # A slot shorter than the fixed fade (the 100-sample slice plays
      # for 80 samples at 0.8x; `fade:` is 192): the fade is the slot's
      # share, out and in alike, and stays inside the slot (the fixed
      # fade's pre-roll into the next cut is 192 samples whatever the
      # slot, so it plays over this slice's first half too)
      s = smp.stretch(0.8, mode: :slice, slices: cuts, slot_fade: 0.5, fade_law: :power)
      a = (24000 * 0.8).round
      expect(s.data(0)[a...(a + 40)]).to eq(smp.data(0)[24000...24040])
      expect(smp.stretch(0.8, mode: :slice, slices: cuts).data(0)[a...(a + 40)]).not_to eq(smp.data(0)[24000...24040])

      # Ratio 1 is the input, and slices drawn out are as without it
      expect(smp.stretch(1, mode: :slice, slices: cuts, slot_fade: 2/3r, fade_law: :power).data(1)).to eq(smp.data(1))
      [:gap, :stretch].each do |fill|
        expect(smp.stretch(1.25, mode: :slice, slices: cuts, fill: fill, slot_fade: 2/3r).data(0)).to eq(smp.stretch(1.25, mode: :slice, slices: cuts, fill: fill).data(0))
      end
      # (fade_law: is every fade's: at 1.25x the 4 ms fades change shape)
      expect(smp.stretch(1.25, mode: :slice, slices: cuts, fade_law: :power).data(0)).not_to eq(smp.stretch(1.25, mode: :slice, slices: cuts).data(0))

      # The defaults by name are the default, and print as nothing
      expect(smp.stretch(0.8, mode: :slice, slices: cuts, slot_fade: nil, fade_law: :linear)).to equal(smp.stretch(0.8, mode: :slice, slices: cuts))
      expect(smp.stretch(0.8, mode: :slice, slot_fade: 2/3r, fade_law: :power).lineage[3]).to eq({ mode: :slice, slot_fade: 2/3r, fade_law: :power })

      expect { smp.stretch(0.8, mode: :slice, slot_fade: 1.5) }.to raise_error(ArgumentError, /share of each slot/)
      expect { smp.stretch(0.8, mode: :slice, slot_fade: 4.ms) }.to raise_error(ArgumentError, /share of each slot/)
      expect { smp.stretch(0.8, mode: :slice, fade_law: :cosine) }.to raise_error(ArgumentError, /fade_law: is one of/)
      expect { smp.stretch(0.8, mode: :spectral, slot_fade: 0.5) }.to raise_error(ArgumentError, /for mode: :slice/)
      expect { smp.stretch(0.8, fade_law: :power) }.to raise_error(ArgumentError, /for mode: :slice/)
    end

    it 'positions: puts each slice at its own place in the output' do
      smp, cuts = clicks_and_cuts
      len = smp.length
      x = Numo::DFloat.cast(smp.data(0))

      # The stretched times by name are the stretch
      at = cuts.map { |c| (c * 0.8).round }
      expect(smp.stretch(0.8, mode: :slice, slices: cuts, positions: at).data(0)).to eq(smp.stretch(0.8, mode: :slice, slices: cuts).data(0))

      # Slices moved off those times (a groove): every cut's hit lands
      # on its position, and the length is still ratio × the input's
      moved = at.zip([0, 300, 0, 0, -250, 200, -100, 150]).map(&:sum)
      s = smp.stretch(0.8, mode: :slice, slices: cuts, positions: moved, slot_fade: 2/3r, fade_law: :power)
      expect(s.length).to eq((len * 0.8).round)
      expect(s.lineage[3][:positions]).to eq(moved)
      y = Numo::DFloat.cast(s.data(0))
      cuts.zip(moved) { |c, v| expect(s.data(0)[v...(v + 16)]).to eq(smp.data(0)[c...(c + 16)]) }
      expect((y - slot_fade_reference(x, cuts, 0.8, 2/3r, :power, moved + [s.length])).abs.max).to be < 1e-6

      # One slot cut short and one drawn out in the same loop (at the
      # input's length: the second cut 2000 samples early, so the first
      # slice is cut and the second has 2000 more than its own length):
      # the cut one crossfades by its slot, the drawn-out one is filled,
      # the rest follow on untouched
      early = cuts.dup
      early[1] -= 2000
      mixed = smp.stretch(1, mode: :slice, slices: cuts, positions: early, fill: :even, slot_fade: 2/3r, fade_law: :power)
      m = Numo::DFloat.cast(mixed.data(0))
      head = slot_fade_reference(x[0...12000], [], 10000 / 12000.0, 2/3r, :power)
      expect((m[0...10000] - head).abs.max).to be < 1e-6
      expect(mixed.data(0)[10000...10720]).to eq(smp.data(0)[12000...12720])
      gapped = Numo::DFloat.cast(smp.stretch(1, mode: :slice, slices: cuts, positions: early, slot_fade: 2/3r, fade_law: :power).data(0))
      expect(gapped[22200...23800].abs.max).to eq(0)
      expect(m[22200...23800].abs.max).to be > 0.01
      expect(mixed.data(0)[24000..]).to eq(smp.data(0)[24000..])

      # Seconds, Lengths, and Durations at the stretched tempo (120 BPM
      # at 0.8x is 150: a quarter note is 19200 samples)
      three = [0, 24000, 48000]
      by_grid = smp.stretch(0.8, mode: :slice, slices: three, positions: [0, 1.n4, 0.75])
      expect(by_grid.data(0)).to eq(smp.stretch(0.8, mode: :slice, slices: three, positions: [0, 19200, 36000]).data(0))
      expect(by_grid.data(0)[19200...19216]).to eq(smp.data(0)[24000...24016])

      st = MB::Sound::Sample::SliceStretch
      expect(st.places([0, 100, 300], nil, 0.5, 400, 200)).to eq([[0, 100, 300, 400], [0, 50, 150, 200]])
      expect(st.places([300, 100], [170, 20], 0.5, 400, 200)).to eq([[0, 100, 300, 400], [0, 20, 170, 200]])
      expect { smp.stretch(0.8, mode: :slice, slices: cuts, positions: at[1..]) }.to raise_error(ArgumentError, /one output position per cut \(8 cuts/)
      expect { smp.stretch(0.8, mode: :slice, slices: three, positions: [0, 40000, 30000]) }.to raise_error(ArgumentError, /run forward/)
      expect { smp.stretch(0.8, mode: :slice, slices: three, positions: [100, 20000, 30000]) }.to raise_error(ArgumentError, /stays at 0/)
      expect { smp.stretch(0.8, mode: :slice, slices: three, positions: [0, 20000, 90000]) }.to raise_error(ArgumentError, /within the output/)
      expect { smp.stretch(0.8, mode: :slice, slices: three, positions: [0, :late, 30000]) }.to raise_error(ArgumentError, /output positions/)
      expect { smp.stretch(0.8, mode: :spectral, positions: [0]) }.to raise_error(ArgumentError, /for mode: :slice/)
    end

    it 'stretches reversed samples in play order' do
      r = rec.rev.stretch(1.25, mode: :slice)
      expect(r).to be_reversed
      direct = MB::Sound::Sample[rec.rev.to_a, bpm: 100].stretch(1.25, mode: :slice)
      expect(r.data(0)).to eq(direct.data(0))
    end
  end

  describe 'Sample#follow' do
    let(:rec) { MB::Sound.bounce(2.bars, bpm: 100) { MB::Sound.tr909(MB::Sound.grid(16, kick: 'X...x...x..xx...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) } }

    after { MB::Sound.bpm(120) }

    it 'plays the loop as it is at its own tempo, stretched or resampled' do
      MB::Sound.bpm(100)
      expect(rec.follow.sample(rec.length)).to eq(rec.data(0))
      expect(rec.follow(:resample).sample(rec.length)).to eq(rec.data(0))
      expect(rec.node(follow: true)).to be_a(MB::Sound::GraphNode::LoopPlayer)
    end

    it 'plays the slice stretch at another tempo, the same at any buffer size' do
      MB::Sound.bpm(125)
      want = rec.stretch(0.8, mode: :slice).data(0)
      [800, *slow_tier([7, 1, 128])].each do |n|
        f = rec.follow
        out = Numo::SFloat.zeros(want.length)
        i = 0
        while i < want.length
          k = [n, want.length - i].min
          out[i...(i + k)] = f.sample(k)
          i += k
        end
        expect(out).to eq(want)
      end
    end

    it 'takes slot_fade: and fade_law: with its stretch options, through the loop point, the same at any buffer size' do
      MB::Sound.bpm(125)
      kw = { mode: :slice, slot_fade: 2/3r, fade_law: :power }
      once = rec.stretch(0.8, **kw).data(0)
      expect(once).not_to eq(rec.stretch(0.8, mode: :slice).data(0))
      want = SpecBuffers.join([once, once[0...4000]])
      [800, *slow_tier([367, 128])].each do |n|
        f = rec.follow(stretch: kw)
        out = Numo::SFloat.zeros(want.length)
        i = 0
        while i < want.length
          k = [n, want.length - i].min
          out[i...(i + k)] = f.sample(k)
          i += k
        end
        expect(out).to eq(want)
      end
    end

    it 'stays on the bar through a tempo change in a session' do
      path = tmp_path('follow.flac')
      MB::Sound.render(path, bars: 6, bpm: 100, gain: 0.5) { # (the break peaks at +4 dBFS)
        MB::Sound.bg :brk, rec.follow
        MB::Sound.at_bar(3) { MB::Sound.bpm 125 }
      }
      mono = MB::Sound.read(path)[0]
      split = 4.8 * 48000
      on = MB::Sound::Sample[mono].onsets
      pos = on.map { |o| o < split ? o / (split / 32) : 32 + (o - split) / (1.92 * 48000 / 16) }
      grid = pos.reject { |p| (p % 16 - 0.3).abs < 0.1 || (p % 16 - 0.375).abs < 0.1 } # the clap's second burst
      expect(grid.length).to be >= 50
      grid.each { |p| expect((p - p.round).abs).to be < 0.01 }
      expect(pos.select { |p| p > 32 }.length).to be > 30
    end

    it 'needs a tempo' do
      expect { MB::Sound::Sample[rec.to_a].follow }.to raise_error(ArgumentError, /no tempo/)
      expect { rec.follow(:wobble) }.to raise_error(ArgumentError, /follow takes/)
    end

    it 'gives stereo samples a bundle' do
      st = MB::Sound::Sample[[rec.data(0), rec.data(0) * 0.5], bpm: 100]
      f = st.follow
      expect(f).to be_a(MB::Sound::GraphNode::Channels)
      expect(f.length).to eq(2)
    end
  end

  describe 'MB::Sound#loops' do
    it 'lists and filters a folder' do
      dir = tmp_path('Loops')
      Dir.mkdir(dir)
      Dir.mkdir(File.join(dir, 'Funk 98 BPM'))
      MB::Sound::Sample::Riff.write(File.join(dir, 'Funk 98 BPM', 'Am groove.wav'), Numo::SFloat.zeros(44100 * 60 / 98 * 4 / 1), sample_rate: 44100)
      MB::Sound::Sample::Riff.write(File.join(dir, 'acid.wav'), Numo::SFloat.zeros(4800), acid: { tempo: 120.0, beats: 4 })
      MB::Sound::Sample::Riff.write(File.join(dir, 'hit.wav'), Numo::SFloat.zeros(480), acid: { one_shot: true })
      before = Dir.glob(File.join(dir, '**', '*')).to_h { |f| [f, File.mtime(f)] }

      l = MB::Sound.loops(dir)
      expect(l.length).to eq(3)
      expect(l.to_s.lines.length).to eq(5)
      expect(l.to_s).to include('Funk 98 BPM/Am groove.wav', 'one-shot', 'acid')
      expect(l.inspect).to eq(l.to_s)
      expect(MB::Sound.loops(dir, bpm: 95..100).map { |e| File.basename(e.path) }).to eq(['Am groove.wav'])
      expect(MB::Sound.loops(dir, bpm: 120).map { |e| File.basename(e.path) }).to eq(['acid.wav'])
      expect(MB::Sound.loops(dir, key: :Am).length).to eq(1)
      expect(MB::Sound.loops(dir, beats: 4).length).to eq(2)
      expect(l.sample(1).bpm).to eq(120.0)
      expect(Dir.glob(File.join(dir, '**', '*')).to_h { |f| [f, File.mtime(f)] }).to eq(before)
      expect(MB::Sound.loops(tmp_path('empty_dir').tap { |d| Dir.mkdir(d) }).to_s).to start_with('No loop files')
    end
  end

  describe 'loop or one-shot, and name tempos that fit' do
    # Files of +secs+ seconds of noise (or +data+) under a fresh folder
    def file(name, secs = nil, data: nil, **chunks)
      path = File.join(@dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      data ||= Numo::SFloat.new((48000 * secs).round).rand(-0.1, 0.1)
      MB::Sound::Sample::Riff.write(path, data, **chunks)
    end

    # Three fixed folders, so the names LoopInfo reads (the file and 3
    # folders up) never reach the random temp directory names, whose
    # suffixes once spelled the drum word "bd" ("folder 'bd'": a
    # one-shot) and could hold a bare 60-200 tempo
    before { @dir = tmp_path('lib/lib/lib') }

    def beats(n, bpm) = n * 60.0 / bpm

    it 'takes a name tempo only when the length fits whole beats' do
      e = info.read(file('funk 98bpm.wav', beats(8, 98)))
      expect([e.bpm, e.beats, e.one_shot, e.why[:bpm]]).to eq([98.0, 8, false, 'name 98 (fits 8 beats)'])
      e = info.read(file('funk 98bpm 2.wav', 3.3))
      expect([e.bpm, e.one_shot, e.why[:bpm]]).to eq([nil, nil, 'name 98 (no fit to 3.300 s)'])
      e = info.read(file('pad 120.wav', beats(16, 120) + 0.004)) # a padded end of 4 ms
      expect([e.bpm, e.beats]).to eq([120.0, 16])
      e = info.read(file('pad 120 b.wav', beats(16, 120) + 0.03))
      expect(e.bpm).to be_nil
    end

    it 'tries double and half time and picks the best fit among the numbers' do
      e = info.read(file('dnb 87.wav', beats(3, 174)))
      expect([e.bpm, e.beats, e.why[:bpm]]).to eq([174.0, 3, 'name 87 as 174 (double time, fits 3 beats)'])
      e = info.read(file('take 2 of 3 92 99.wav', beats(4, 99)))
      expect([e.bpm, e.beats]).to eq([99.0, 4])
      e = info.read(file('Funk 98 BPM/bass 3.wav', beats(8, 98)))
      expect([e.bpm, e.why[:bpm]]).to eq([98.0, 'name 98 (fits 8 beats)'])
    end

    it 'reads loop and one-shot words, the file name before its folders' do
      expect(info.read(file('Kick 100.wav', 0.6)).then { |e| [e.one_shot, e.bpm, e.why[:one_shot]] }).to eq([true, nil, "name 'kick'"])
      expect(info.read(file('KickLoop 100.wav', beats(4, 100))).then { |e| [e.one_shot, e.bpm] }).to eq([false, 100.0])
      expect(info.read(file('One Shots/thing.wav', 1.2)).then { |e| [e.one_shot, e.why[:one_shot]] }).to eq([true, "folder 'oneshot'"])
      expect(info.read(file('One Shots/Loop 3 92.wav', beats(4, 92))).then { |e| [e.one_shot, e.bpm] }).to eq([false, 92.0])
      expect(info.read(file('Loops/blip.wav', 0.5)).then { |e| [e.one_shot, e.why[:one_shot]] }).to eq([true, 'short (0.50 s)'])
    end

    it 'calls short files one-shots unless a tempo fits' do
      expect(info.read(file('blip.wav', 0.5)).one_shot).to eq(true)
      expect(info.read(file('tick.wav', 0.2)).then { |e| [e.one_shot, e.why[:one_shot]] }).to eq([true, '0.20 s'])
      expect(info.read(file('blip 120.wav', 0.5)).then { |e| [e.one_shot, e.bpm, e.beats] }).to eq([false, 120.0, 1])
      expect(info.read(file('pad.wav', 2.0)).one_shot).to be_nil
    end

    it 'lets ACID flags win and keeps smpl loops for non-ACID files' do
      e = info.read(file('kick loop.wav', 0.4, acid: { one_shot: true }))
      expect([e.one_shot, e.bpm]).to eq([true, nil])
      e = info.read(file('crash 120.wav', beats(4, 120), acid: { tempo: 120.0, beats: 4 }, smpl: { loops: [[100, 20000]] }))
      expect([e.one_shot, e.loop, e.smpl_loops]).to eq([false, nil, [[100, 20000, :forward]]])
      s = MB::Sound::Sample[file('piano c3.wav', 1.0, smpl: { unity_note: 48, loops: [[100, 20000, :ping_pong]] })]
      expect([s.loop_points, s.loop_mode, s.root]).to eq([[100.0, 20000.0], :ping_pong, 48.0])
      expect(s.provenance(:loop).fact).to eq('smpl.loop[0]') # (consumed: not description)
      expect(s.meta[:source][:fields].to_h.keys.grep(/smpl\.loop/)).to eq([])
    end

    it 'loops loops and calls one hit decaying to silence a one-shot' do
      s = MB::Sound::Sample[file('groove 100.wav', beats(4, 100))]
      expect([s.loop_points, s.loop_mode, s.bpm]).to eq([[0.0, 115200.0], :forward, 100.0])

      t = Numo::DFloat.new(96000).seq / 48000
      hit = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 180) * Numo::NMath.exp(-t * 8) * 0.8)
      s = MB::Sound::Sample[file('boom 120.wav', data: hit)] # 2 s = 4 beats at 120, but one decaying hit
      expect([s.one_shot?, s.bpm, s.meta_source[:one_shot], s.why(:one_shot)]).to eq([true, nil, :decay, 'one hit decaying to silence'])
      expect(s.why(:bpm)).to eq('name 120 (fits 4 beats); dropped: a one-shot')

      drums = MB::Sound.bounce(1.bar, bpm: 120) { MB::Sound.tr808(MB::Sound.grid(16, kick: 'X...X...X...X...', hat: 'x.x.x.x.x.x.x.x.')) }
      s = MB::Sound::Sample[file('drums 120.wav', data: drums.data(0))]
      expect([s.one_shot?, s.bpm, s.loop_mode]).to eq([false, 120.0, :forward])
    end

    it 'shows kind and why in loops()' do
      file('Funk 98 BPM/Am groove.wav', beats(8, 98))
      file('Kick 100.wav', 0.6)
      file('odd 98bpm.wav', 3.3)
      text = MB::Sound.loops(@dir).to_s
      expect(text.lines[1]).to match(/kind +why/)
      expect(text).to match(/Am groove\.wav +98 +8 +Am +loop +name 98 \(fits 8 beats\); loop: name 'groove'/)
      expect(text).to match(/Kick 100\.wav +- +- +- +one-shot +one-shot: name 'kick'/)
      expect(text).to match(/odd 98bpm\.wav +- +- +- +- +name 98 \(no fit to 3\.300 s\)/)
    end
  end

  describe 'follow defaults by material, and soft onsets in slices' do
    let(:arp) {
      notes = %i[A3 C4 E4 A4 G4 E4 C4 D4 A3 C4 E4 B4 A4 E4 D4 C4].map { |n| MB::Sound.const_get(n) }
      MB::Sound.bounce(2.bars, bpm: 100) {
        MB::Sound.seq(*notes).n8.loop.synth(voices: 4) { |v|
          v.hz.saw.lp4(v.env(0.002, 0.25, 0.2, 0.2, gm: false) * 2500 + 400, resonance: 0.3) * v.env(0.003, 0.3, 0.5, 0.25, gm: false) * 0.4
        }
      }
    }
    let(:drums) { MB::Sound.bounce(2.bars, bpm: 100) { MB::Sound.tr909(MB::Sound.grid(16, kick: 'X...x...x..xx...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) } }

    after { MB::Sound.bpm(120) }

    it 'cuts slices at soft notes on the grid (the A3 after D4 that #onsets misses)' do
      eighth = arp.length / 16
      expect(arp.onsets.map { |o| (o.to_f / eighth).round }).not_to include(8)
      s = arp.stretch(0.78125, mode: :slice)
      a = 8 * eighth + arp.onsets(threshold: 4.db).find { |o| (o.to_f / eighth).round == 8 } - 8 * eighth
      q = (a * 0.78125).round
      expect(s.data(0)[q...(q + 64)]).to eq(arp.data(0)[a...(a + 64)])
    end

    it 'calls drums percussive and notes tonal, by name words, else spectral flatness' do
      expect(drums.material.kind).to eq(:percussive)
      expect(drums.material.flatness).to be > 0.04
      expect(arp.material.kind).to eq(:tonal)
      expect(arp.material.why).to eq('tonal, spectral flatness 0.000')
      expect(arp.with(name: 'Perc Loop 3').material.then { |m| [m.kind, m.why] }).to eq([:percussive, "name 'perc'"])
      expect(drums.with(name: 'PadLoop').material.kind).to eq(:tonal)
      # words run together, as loop packs name files: a list word at the end of a name word
      expect(drums.with(name: 'Deepbass 04').material.then { |m| [m.kind, m.why] }).to eq([:tonal, "name 'bass' in 'deepbass'"])
      expect(arp.with(name: 'Clubhats 12').material.then { |m| [m.kind, m.why] }).to eq([:percussive, "name 'hats' in 'clubhats'"])
      expect(arp.with(name: 'Bigbeat 3').material.kind).to eq(:percussive)
      expect(arp.with(name: 'bassdrum').material.kind).to eq(:percussive)      # percussive words first
      expect(arp.with(name: 'that harp').material.why).to start_with('tonal, spectral flatness') # (no three-letter matches: hat, arp)
    end

    it 'follows with slices for percussive loops and the vocoder for tonal ones, unless told' do
      expect(drums.follow.stretch_reason).to start_with('slice: percussive, spectral flatness')
      a = arp.follow
      expect(a.stretch_reason).to eq('spectral: tonal, spectral flatness 0.000')
      expect(a.to_s).to include('spectral stretch')
      MB::Sound.bpm(125)
      expect(a.sample(800)).to eq(arp.stretch(0.8, mode: :spectral, wrap: true).data(0)[0...800])
      b = arp.follow(stretch: :slice)
      expect(b.stretch_reason).to eq('stretch: given')
      expect(b.sample(800)).to eq(arp.stretch(0.8, mode: :slice).data(0)[0...800])
      expect(arp.follow(:resample).stretch_reason).to be_nil
    end
  end
end
