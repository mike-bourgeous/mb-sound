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
      expect(e.sources).to eq(bpm: :name, key: :name, beats: :name)
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
      MB::Sound::Sample::Riff.write(File.join(dir, 'a_90bpm.wav'), Numo::SFloat.zeros(100))
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
      expect(s.loop_points).to eq([109.0, 43537.0])
      expect(s.loop_mode).to eq(:forward)
      expect(s.markers.map(&:to_h)).to eq([{ position: 0, label: 'kick' }, { position: 12000, label: 'snare' }])
      expect(s.meta_source).to include(bpm: :acid, loop: :smpl, markers: :cue)

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

    it 'fades instead of clicking' do
      [0.7, 1.4].each do |r|
        [:gap, :stretch].each do |fill|
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

    it 'stretches reversed samples in play order' do
      r = rec.rev.stretch(1.25, mode: :slice)
      expect(r).to be_reversed
      direct = MB::Sound::Sample[rec.rev.to_a, bpm: 100].stretch(1.25, mode: :slice)
      expect(r.data(0)).to eq(direct.data(0))
    end
  end
end
