# ACID loop info in WAV files driving Sample#follow and Sample#stretch
# (acid-loop-info-1, 2026-11-10): the `strc` chunk's stretch markers as
# Sample#markers, the `acid` chunk's one-shot flag as "plays as recorded",
# `stretch(mode: :none)`, and `transients:` with positions.  Every file is
# written here (Sample::Riff.write).
RSpec.describe('ACID loop info: stretch markers and one-shots', :aggregate_failures) do
  let(:riff) { MB::Sound::Sample::Riff }
  let(:info) { MB::Sound::Sample::LoopInfo }

  # One second (2 beats at 120 BPM) at 44.1 kHz: a quiet two-sine pad
  # with a decaying burst at every frame in +hits+.
  let(:hits) { [0, 5512, 11025, 22050, 27562, 33075] }
  let(:loop_audio) { bursts(44100, hits) }

  def bursts(rate, hits)
    t = Numo::DFloat.new(rate).seq
    x = (Numo::NMath.sin(t * (2 * Math::PI * 220 / rate)) + Numo::NMath.sin(t * (2 * Math::PI * 331 / rate))) * 0.1
    k = Numo::DFloat.new(2000).seq
    burst = Numo::NMath.sin(k * 0.9) * Numo::NMath.exp(-k / 250.0) * 0.6
    hits.each { |h| x[h...(h + 2000)] += burst }
    Numo::SFloat.cast(x)
  end

  def write_wav(name, data, **options)
    MB::Sound::Sample::Riff.write(tmp_path(name), data, sample_rate: 44100, **options)
  end

  # Frames at 44.1 kHz as Sample positions (48 kHz).
  def at48(frames) = frames.map { |f| (f * 48000.0 / 44100).round }

  def auto(position, **more) = { position: position, automatic: true, **more }

  describe MB::Sound::Sample::Riff do
    it 'reads the strc header and entries, and leaves out disabled markers' do
      path = write_wav('old.wav', loop_audio, acid: { tempo: 120.0, beats: 2 },
                       strc: [auto(0), 0, 5512, { position: 8000, disabled: true }, 11025, { position: 22050, pin: 22060 }, 33075])
      s = riff.read(path).strc
      expect(s.count).to eq(7)
      expect(s.settings).to eq([0, 0, 1, 0, 0])
      expect(s.entries.length).to eq(7)
      expect(s.entries[0].to_h).to eq(flags: 2, position: 0, pin: 0, value: 0)
      expect(s.entries[0]).to be_automatic
      expect(s.entries[3]).to be_disabled
      expect(s.entries[5].pin).to eq(22060)
      expect(s.entries[5]).to be_pinned
      expect(s.entries[2]).not_to be_pinned
      expect(s.lists.map(&:length)).to eq([7])
      expect(s.markers).to eq([0, 5512, 11025, 22050, 33075])
      expect(s.stretch_method).to eq(:looping)
      expect(s.spacing).to be_nil
      expect(riff.read(path).chunks.map(&:first)).to eq(['fmt ', 'acid', 'strc', 'data'])
    end

    it 'takes the last list that is not transient hints, with the automatic list before a list of hand-set markers' do
      hints = [{ position: 0, automatic: true, pin: 0, strength: -1.9 }, *[5500, 11000, 22000, 27500].map { |p| { position: p, automatic: true, pin: 0, strength: 12.5 } }]
      copy = [auto(0), *[5512, 11025, 16537, 22050].map { |p| auto(p, pin: 0) }]
      final = [auto(0), auto(5512), { position: 11000, pin: 11025 }, { position: 16537, disabled: true }, auto(22050), { position: 30000 }]

      s = riff.read(write_wav('new.wav', loop_audio, strc: { entries: hints + copy + copy + final, settings: [65, 5, 2, 10, 4] })).strc
      expect(s.lists.map(&:length)).to eq([5, 5, 5, 6])
      expect(s.entries[1]).to be_hint
      expect(s.entries[1].strength).to eq(12.5)
      expect(s.entries[6]).not_to be_hint
      expect(s.markers).to eq([0, 5512, 11000, 22050, 30000]) # the last list: where the moved marker is, not its pin
      expect(s.stretch_method).to eq(:nonlooping)
      expect(s.spacing).to eq(16)

      # only hand-set markers in the last list: ACID keeps the automatic ones in the list before
      edits = [{ position: 8000, pin: 8268 }, { position: 30000 }, { position: 40000, disabled: true }]
      e = riff.read(write_wav('edits.wav', loop_audio, strc: hints + copy + edits)).strc
      expect(e.markers).to eq([0, 5512, 8000, 11025, 16537, 22050, 30000])

      # nothing but hints: no markers
      expect(riff.read(write_wav('hints.wav', loop_audio, strc: hints)).strc.markers).to eq([])
    end

    it 'stops at the header\'s count, ignores trailing bytes, and survives short and lying chunks' do
      # an old list of 4, then entries a later ACID version appended without changing the count
      path = write_wav('appended.wav', loop_audio, strc: { entries: [auto(0), 11025, 22050, 33075, auto(0), auto(2000), auto(4000)], count: 4, tail: 8 })
      s = riff.read(path).strc
      expect(s.count).to eq(4)
      expect(s.entries.length).to eq(7)
      expect(s.lists.map(&:length)).to eq([4])
      expect(s.markers).to eq([0, 11025, 22050, 33075])

      expect(riff.read(write_wav('lying.wav', loop_audio, strc: { entries: [auto(0), 100], count: 1000 })).strc.count).to eq(2)
      expect(riff.read(write_wav('empty.wav', loop_audio, strc: [])).strc.markers).to eq([])
      expect(riff.read(write_wav('short.wav', loop_audio, extra: [['strc', 'x' * 20]])).strc).to be_nil
      expect(riff.read(write_wav('badhead.wav', loop_audio, extra: [['strc', [4000, 1, 0, 0, 0, 0, 0].pack('V7')]])).strc).to be_nil
    end

    it 'gives the forced divisions of older files: the spacing grid where no marker is near' do
      s = riff.read(write_wav('sparse.wav', loop_audio, strc: { entries: [auto(0), 11020, 16537, 33075], settings: [65, 5, 1, 0, 3], tail: 8 })).strc
      expect(s.spacing).to eq(8)
      # eighths of 2 beats in 44100 frames: 11025 apart; 11020 and 33075 are markers already
      expect(s.forced(44100, 2)).to eq([22050])
      expect(s.forced(44100, 4)).to eq([5513, 22050, 27563, 38588]) # sixteenth-sized divisions: 11020 and 16537 cover theirs
      expect(s.forced(44100, 0)).to eq([])
      expect(s.forced(nil, 2)).to eq([])

      newer = riff.read(write_wav('newer.wav', loop_audio, strc: { entries: [auto(0), auto(1000, pin: 0), auto(0), auto(11025)], settings: [65, 5, 1, 0, 3] })).strc
      expect(newer.forced(44100, 2)).to eq([]) # several lists: the divisions are in the list
      none = riff.read(write_wav('none.wav', loop_audio, strc: [auto(0), 11025])).strc
      expect(none.forced(44100, 2)).to eq([]) # no spacing set
    end
  end

  describe MB::Sound::Sample::LoopInfo do
    it 'reads stretch markers as the markers, ahead of cue points' do
      path = write_wav('loop.wav', loop_audio, acid: { tempo: 120.0, beats: 2 }, cues: [[0, 'Bar 1'], [22050, 'Bar 2']], strc: [auto(0), 0, *hits[1..]])
      e = info.read(path)
      expect(e.markers).to eq(hits.map { |h| [h, nil] })
      expect(e.cues).to eq([[0, 'Bar 1'], [22050, 'Bar 2']])
      expect(e.sources[:markers]).to eq(:strc)
      expect(e.why[:markers]).to eq('strc: 6 stretch markers')

      cue_only = info.read(write_wav('cue.wav', loop_audio, cues: [[0, 'a'], 22050]))
      expect(cue_only.markers).to eq([[0, 'a'], [22050, nil]])
      expect(cue_only.cues).to eq(cue_only.markers)
      expect(cue_only.sources[:markers]).to eq(:cue)

      # a chunk with nothing past the start says nothing: the cue points stay
      trivial = info.read(write_wav('trivial.wav', loop_audio, cues: [100], strc: [auto(0)]))
      expect(trivial.markers).to eq([[100, nil]])
      expect(trivial.sources[:markers]).to eq(:cue)
    end

    it 'adds the forced divisions of older ACID versions for loops, not one-shots' do
      strc = { entries: [auto(0), 11020, 16537, 33075], settings: [65, 5, 1, 0, 3], tail: 8 }
      e = info.read(write_wav('sparse.wav', loop_audio, acid: { tempo: 120.0, beats: 2 }, strc: strc))
      expect(e.markers.map(&:first)).to eq([0, 11020, 16537, 22050, 33075])
      expect(e.why[:markers]).to eq('strc: 5 stretch markers (1 forced divisions)')
      shot = info.read(write_wav('shot.wav', loop_audio, acid: { one_shot: true, tempo: 0.0, beats: 0 }, strc: strc))
      expect(shot.markers.map(&:first)).to eq([0, 11020, 16537, 33075])
      expect(info.read(write_wav('noacid.wav', loop_audio, strc: strc)).markers.map(&:first)).to eq([0, 11020, 16537, 33075])
    end

    it 'leaves out markers made for other audio, and a marker on the last frame' do
      # a copy at half the rate that kept its chunks: markers past the end
      stale = info.read(write_wav('stale.wav', loop_audio[0...22050], acid: { tempo: 120.0, beats: 1 }, cues: [50], strc: [auto(0), 0, 11025, 22050, 33075]))
      expect(stale.markers).to eq([[50, nil]])
      expect(stale.sources[:markers]).to eq(:cue)
      expect(stale.why[:markers]).to eq('strc markers past the end (made for other audio): left out')

      ending = info.read(write_wav('ending.wav', loop_audio, strc: [auto(0), 0, 22050, 44100]))
      expect(ending.markers.map(&:first)).to eq([0, 22050])
    end

    it 'reads the chunks kept in a FLAC file\'s riff application blocks' do
      path = tmp_path('kept.flac')
      MB::Sound.write(path, [Numo::SFloat.cast(loop_audio)], sample_rate: 44100)
      flac = File.binread(path)
      expect(flac[0, 4]).to eq('fLaC')
      first = 4 + 4 + (flac[4, 4].unpack1('N') & 0xFFFFFF) # the end of STREAMINFO
      expect(flac.getbyte(4) & 0x80).to eq(0) # (ffmpeg writes more blocks after it)
      block = ->(id, body) { b = 'riff'.b + id.b + [body.bytesize].pack('V') + body; [0x02000000 | b.bytesize].pack('N') + b }
      blocks = block.('acid', riff.acid_bytes(tempo: 120.0, beats: 2)) + block.('strc', riff.strc_bytes([auto(0), 0, 11025, 22050]))
      File.binwrite(path, flac[0, first] + blocks + flac[first..])

      e = info.read(path)
      expect(e.format).to eq(:flac)
      expect(e.bpm).to eq(120.0)
      expect(e.markers.map(&:first)).to eq([0, 11025, 22050])
      expect(e.sources[:markers]).to eq(:strc)
    end
  end
end
