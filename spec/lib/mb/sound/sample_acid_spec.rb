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

  # A Provenance saying +field+ came from +via+ (description for a Sample).
  def prov(field, via, **more) = MB::Sound::Provenance.new(field: field, via: via, **more)

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

    it 'says what the file itself declares, beside its own loop or one-shot call' do
      declared = info.read(write_wav('Loop A.wav', loop_audio, acid: { one_shot: true, tempo: 0.0, beats: 0 }))
      expect([declared.one_shot, declared.declared_one_shot, declared.sources[:one_shot]]).to eq([true, true, :acid])
      looped = info.read(write_wav('Kick B.wav', loop_audio, acid: { tempo: 120.0, beats: 2 }))
      expect([looped.one_shot, looped.declared_one_shot, looped.sources[:one_shot]]).to eq([false, false, :acid])
      # a one-shot by its name or length is the interpreter's call, not the file's declaration
      named = info.read(write_wav('Kick C.wav', loop_audio))
      expect([named.one_shot, named.declared_one_shot, named.sources[:one_shot]]).to eq([true, nil, :name])
      short = info.read(write_wav('x.wav', loop_audio[0...4410]))
      expect([short.one_shot, short.declared_one_shot, short.sources[:one_shot]]).to eq([true, nil, :length])
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

  describe 'Sample markers and the slice stretch' do
    let(:path) { write_wav('Loop 3.wav', loop_audio, acid: { tempo: 120.0, beats: 2 }, cues: [[0, 'Bar 1']], strc: [auto(0), 0, *hits[1..]]) }
    let(:loop) { MB::Sound::Sample[path] }

    after { MB::Sound.bpm(120) }

    it 'has the stretch markers as its markers, at the sample\'s rate' do
      expect(loop.length).to eq(48000)
      expect(loop.markers.map(&:position)).to eq(at48(hits))
      expect(loop.markers.map(&:label).uniq).to eq([nil])
      expect(loop.provenance(:markers).via).to eq(:strc)
      expect(loop.meta_source[:markers]).to eq(:strc)
      expect(loop.why(:markers)).to eq('strc: 6 stretch markers')
      # (the cue point is a fact nothing used: description, at the file's own rate)
      expect(loop.meta[:source][:fields]['cue.point[0]']).to eq([0, 'Bar 1'])
      # the file declares a loop: no setting, and the declaration's provenance says so
      expect(loop).not_to be_declared_one_shot
      d = loop.provenance(:declared_one_shot)
      expect([d.via, d.fact, d.why]).to eq([:acid, 'acid.flags', "the file's one-shot flag is not set: a loop"])
      expect(loop.meta.key?(:one_shot)).to be(false)
      expect(at48(hits)).to eq([0, 5999, 12000, 24000, 29999, 36000])
      expect(loop.trim(6000..).markers.map(&:position)).to eq([6000, 18000, 23999, 30000])
    end

    it 'reads the chunk as facts the interpreter consumes, with the markers\' provenance' do
      info = riff.read(path)
      chunk = info.chunks.find { |id, _, _| id == 'strc' }
      facts = MB::Sound::Facts.of_riff(info)
      expect(facts['strc.count'].value).to eq(7)
      expect(facts['strc.settings'].value).to eq([0, 0, 1, 0, 0])
      expect(facts['strc.entry[0]'].to_h).to include(value: [2, 0, 0, 0], record: 'strc', at: chunk[1] + 36, bytes: 32)
      expect(facts['strc.entry[2]'].value).to eq([0, hits[1], hits[1], 0])
      expect(facts.select_keys('strc.entry[*').size).to eq(7)
      expect(facts.key?('chunk.strc')).to be(false)
      expect(facts.keys.last(9)).to eq(%w[strc.count strc.settings] + Array.new(7) { |i| "strc.entry[#{i}]" }) # (after the other chunks' facts)

      m = loop.provenance(:markers)
      expect([m.via, m.fact, m.record, m.at, m.interpreter]).to eq([:strc, 'strc.entry[0]', 'strc', chunk[1] + 36, 'Sample::LoopInfo'])
      fields = loop.meta[:source][:fields].to_h
      expect(fields.keys.grep(/\Astrc\./)).to eq([]) # (consumed: not description)
      expect(fields.keys.grep(/\Acue\./)).to eq(['cue.point[0]'])
      expect(loop.meta[:source][:skipped]).to eq([])
      expect(loop.summary).to include('markers: strc "strc.entry[0]" (wav strc chunk at 0x')

      # a file with cue points only: they are the markers, and consumed
      cued = MB::Sound::Sample[write_wav('Loop 4.wav', loop_audio, acid: { tempo: 120.0, beats: 2 }, cues: [[0, 'Bar 1'], [22050, 'Bar 2']])]
      expect([cued.provenance(:markers).via, cued.provenance(:markers).fact]).to eq([:cue, 'cue.point[0]'])
      expect((cued.meta.dig(:source, :fields) || {}).to_h.keys.grep(/\Acue\./)).to eq([])

      # a chunk made for other audio is left out: its facts stay description, and the reason says so
      stale = MB::Sound::Sample[write_wav('Loop 5.wav', loop_audio[0...22050], acid: { tempo: 120.0, beats: 1 }, strc: [auto(0), 0, 11025, 22050, 33075])]
      expect(stale.markers).to eq([])
      expect([stale.provenance(:markers).via, stale.why(:markers)]).to eq([nil, 'strc markers past the end (made for other audio): left out'])
      expect(stale.meta[:source][:fields]).to include('strc.count' => 5, 'strc.entry[4]' => [0, 33075, 33075, 0])
    end

    it 'cuts slices at them by default, unless slices: says otherwise' do
      cuts = at48(hits)
      s = loop.stretch(1.25, mode: :slice)
      expect(s.data(0)).to eq(loop.stretch(1.25, mode: :slice, slices: cuts).data(0))
      expect(s.data(0)).to eq(loop.stretch(1.25, mode: :slice, slices: loop.markers).data(0))
      expect(s.data(0)).to eq(loop.stretch(1.25, mode: :slice, slices: :markers).data(0))
      cuts.each { |c| q = (c * 1.25).round; expect(s.data(0)[q...(q + 64)]).to eq(loop.data(0)[c...(c + 64)]) }
      grid = loop.stretch(1.25, mode: :slice, slices: 3)
      expect(grid.data(0)).not_to eq(s.data(0))
      expect(grid.data(0)[20000...20064]).to eq(loop.data(0)[16000...16064])
    end

    it 'says so where follow picks the slice stretch' do
      drums = loop.with(name: 'Drum Loop 3')
      f = drums.follow
      expect(f.stretch_reason).to eq("slice: name 'drum', at 5 markers")
      MB::Sound.bpm(96)
      expect(f.sample(800)).to eq(drums.stretch(1.25, mode: :slice, slices: at48(hits)).data(0)[0...800])
      # tonal loops keep the plain spectral stretch; the marker-guided one is there to ask for
      pad = loop.with(name: 'Pad Loop 3')
      expect(pad.follow.stretch_reason).to eq("spectral: name 'pad'")
      guided = pad.follow(stretch: { mode: :spectral, transients: :markers })
      expect(guided.stretch_reason).to eq('stretch: given')
      expect(guided.sample(800)).to eq(pad.stretch(1.25, mode: :spectral, transients: at48(hits)).data(0)[0...800])
      # markers a caller gives count the same: where they came from is description, which follow doesn't read
      expect(MB::Sound::Sample[loop.to_a, bpm: 120, name: 'drums', markers: [0, 24000]].follow.stretch_reason).to eq("slice: name 'drums', at 1 markers")
      relabeled = drums.with(provenance: { markers: prov(:markers, :cue) }, meta: {})
      expect(relabeled.meta_source).to eq(markers: :cue)
      expect(relabeled.follow.stretch_reason).to eq(f.stretch_reason)
      expect(relabeled.stretch(1.25, mode: :slice).data(0)).to eq(drums.stretch(1.25, mode: :slice).data(0))
    end
  end

  describe 'files that declare themselves one-shots (the acid chunk\'s flag)' do
    let(:hit) { loop_audio[5512...16537] } # 0.25 s: two bursts
    let(:shot) { MB::Sound::Sample[write_wav('Perc Shot.wav', hit, acid: { one_shot: true, tempo: 0.0, beats: 0 })] }
    let(:timed) { shot.with(bpm: 120) } # half a beat: a loop length to repeat at

    after { MB::Sound.bpm(120) }

    def collect(node, count, size = 800)
      out = Numo::SFloat.zeros(count)
      i = 0
      while i < count
        k = [size, count - i].min
        out[i...(i + k)] = node.sample(k)
        i += k
      end
      out
    end

    it 'are marked as data: a setting of the Sample, with its provenance' do
      expect(shot).to be_one_shot
      expect(shot.bpm).to be_nil
      expect(shot).to be_declared_one_shot
      d = shot.provenance(:declared_one_shot)
      expect([d.via, d.fact, d.record, d.interpreter, d.why]).to eq([:acid, 'acid.flags', 'acid', 'Sample::LoopInfo', "the file's one-shot flag is set"])
      expect(shot.meta_source).to include(one_shot: :acid, declared_one_shot: :acid)
      expect(shot.meta.key?(:one_shot)).to be(false) # (description keeps no copy of the call)
      expect(shot.summary).to include('declared_one_shot: acid "acid.flags"')
      expect { shot.follow }.to raise_error(ArgumentError, /no tempo/)

      # views, copies, and edits keep the setting; with: changes it
      expect([timed, timed.trim(100..), timed.reverse, timed.gain(-6.db), timed.looped(0...6000), timed.stretch(2), timed.mono]).to all(be_declared_one_shot)
      expect(timed.with(declared_one_shot: false)).not_to be_declared_one_shot
      expect(MB::Sound::Sample[hit]).not_to be_declared_one_shot
      expect(MB::Sound::Sample[hit, declared_one_shot: true]).to be_declared_one_shot
      expect { MB::Sound::Sample[hit, declared_one_shot: :acid] }.to raise_error(ArgumentError, /declared_one_shot: is true or false/)
    end

    it 'follow by the setting, whatever the metadata and provenance say' do
      MB::Sound.bpm(96) # the loop lasts 15000 samples: the second burst at 6000 as recorded, at 7500 in slices
      n = 12000
      as_recorded = collect(timed.follow, n)
      sliced = collect(timed.follow(stretch: :slice), n)
      expect(as_recorded).to eq(timed.data(0))
      expect(sliced).to eq(timed.stretch(1.25, mode: :slice).data(0)[0...n])
      expect((as_recorded - sliced).abs.max).to be > 0.1

      # the description and provenance gone, or saying loop: still as recorded
      says_loop = { one_shot: prov(:one_shot, :name, why: "name 'loop'"), declared_one_shot: prov(:declared_one_shot, :name, why: 'a loop') }
      [{ meta: {}, provenance: {} }, { meta: { one_shot: false, declared_one_shot: false }, provenance: says_loop }].each do |described|
        s = timed.with(**described)
        expect(s.meta[:declared_one_shot]).not_to eq(true)
        expect(s.provenance(:declared_one_shot)&.via).not_to eq(:acid)
        expect(s.follow.stretch_reason).to eq(timed.follow.stretch_reason)
        expect(collect(s.follow, n)).to eq(as_recorded)
      end

      # the description and provenance saying "a declared one-shot, from the acid chunk" without the setting: stretched by its material
      said = MB::Sound::Sample[shot.to_a, bpm: 120, name: 'Perc Shot', meta: { one_shot: true, declared_one_shot: true }, provenance: shot.provenance]
      expect([said.meta[:declared_one_shot], said.provenance(:declared_one_shot).via, said.why(:declared_one_shot)]).to eq([true, :acid, "the file's one-shot flag is set"])
      expect(said).not_to be_declared_one_shot
      expect(said.follow.stretch_reason).to start_with('slice: name')
      expect(collect(said.follow, n)).to eq(sliced)
      unset = timed.with(declared_one_shot: false)
      expect(unset.provenance(:declared_one_shot)).to eq(shot.provenance(:declared_one_shot)) # (still described as declared)
      expect(collect(unset.follow, n)).to eq(sliced)

      # the setting without any description or provenance
      set = MB::Sound::Sample[shot.to_a, bpm: 120, name: 'Perc Shot', declared_one_shot: true]
      expect([set.meta, set.provenance]).to all(be_empty)
      expect(collect(set.follow, n)).to eq(as_recorded)
    end

    it 'play as recorded under follow: silence after them at slower tempos, cut short at faster ones' do
      f = timed.follow
      expect(f.stretch_reason).to eq('none: a one-shot by its file\'s loop info plays as recorded')
      expect(f.to_s).to include('as recorded')
      n = timed.length
      expect(n).to eq(12000)

      MB::Sound.bpm(60) # the loop length doubles
      out = collect(timed.follow, n * 4, 367)
      expect(out[0...n]).to eq(timed.data(0))
      expect(out[n...(2 * n)].abs.max).to eq(0)
      expect(out[(2 * n)...(3 * n)]).to eq(timed.data(0)) # again at the next loop start
      expect(collect(timed.follow, n * 4)).to eq(out)      # the same at another buffer size

      MB::Sound.bpm(240) # half the length: cut, faded over 4 ms
      short = collect(timed.follow, n)
      expect(short[0...(n / 2 - 192)]).to eq(timed.data(0)[0...(n / 2 - 192)])
      expect(short[n / 2 - 1].abs).to be < 1e-3
      expect(short[(n / 2)...(n - 192)]).to eq(timed.data(0)[0...(n / 2 - 192)])
    end

    it 'still stretch when asked to, and resample as before' do
      MB::Sound.bpm(96)
      sliced = timed.follow(stretch: :slice)
      expect(sliced.stretch_reason).to eq('stretch: given')
      expect(sliced.sample(800)).to eq(timed.stretch(1.25, mode: :slice).data(0)[0...800])
      expect(timed.follow(:resample).stretch_reason).to be_nil
      expect(timed.stretch(1.25).length).to eq(15000)          # an explicit stretch is a stretch
      expect(timed.stretch(1.25, mode: :spectral).data(0)).not_to eq(timed.stretch(1.25, mode: :none).data(0))

      # the flag is the file's: a loop from an ACID loop file, or a one-shot by name only, follows by its material
      looped = MB::Sound::Sample[write_wav('Perc Loop.wav', hit, acid: { tempo: 120.0, beats: 1 })]
      expect(looped).not_to be_declared_one_shot
      expect(looped.follow.stretch_reason).to start_with('slice: name')
      named = MB::Sound::Sample[write_wav('Kick 120.wav', hit), bpm: 120]
      expect([named.one_shot?, named.meta_source[:one_shot], named.provenance(:declared_one_shot)]).to eq([true, :name, nil])
      expect(named).not_to be_declared_one_shot
      expect(named.follow.stretch_reason).to start_with('slice: name')
    end

    it 'stay one-shots when saved, alone and in a graph document\'s bundle' do
      timed.save(tmp_path('shot.flac'))
      back = MB::Sound::Sample[tmp_path('shot.flac')]
      expect(back.bpm).to eq(120.0)
      expect(back).to be_declared_one_shot
      expect([back.provenance(:declared_one_shot).via, back.provenance(:declared_one_shot).fact]).to eq([:saved, 'tag.mb_sample_declared_one_shot'])
      expect(back.follow.stretch_reason).to start_with('none: a one-shot by its file')
      expect(timed.tags).to include(mb_sample_declared_one_shot: 'true')
      expect(MB::Sound::Sample[hit, bpm: 120].tags.keys).not_to include(:mb_sample_declared_one_shot)
      # the tag is the setting alone: metadata and provenance changed before saving don't change what is saved or played
      timed.with(meta: {}, provenance: {}).save(tmp_path('bare.flac'))
      expect(MB::Sound::Sample[tmp_path('bare.flac')]).to be_declared_one_shot
      timed.with(declared_one_shot: false).save(tmp_path('loop.flac'))
      expect(MB::Sound::Sample[tmp_path('loop.flac')]).not_to be_declared_one_shot

      # read with an option, the sample goes into the bundle as a FLAC file with tags, not as its WAV
      MB::Sound.bpm(60)
      g = MB::Sound::Sample[write_wav('Perc Shot 2.wav', hit, acid: { one_shot: true, tempo: 0.0, beats: 0 }), bpm: 120].follow
      path = MB::Sound::GraphIO.save(File.join(File.dirname(tmp_path('x')), 'shot'), g, name: 'shot')
      loaded = MB::Sound::GraphIO.load(path)
      expect(loaded.stretch_reason).to eq(g.stretch_reason)
      expect((collect(loaded, 24000) - collect(g, 24000)).abs.max).to be < 1e-6 # (the bundle's FLAC is 24-bit)
      expect(collect(loaded, 24000)[12000...24000].abs.max).to eq(0)             # as recorded: silence after the hit
    end

    it 'play as recorded on a clock\'s loop period' do
      c = shot.clocked(0.5.seconds)
      expect(c.stretch_reason).to start_with('none: a one-shot by its file')
      out = collect(c, 36000)
      expect(out[0...12000]).to eq(shot.data(0))
      expect(out[12000...24000].abs.max).to eq(0)
      expect(out[24000...36000]).to eq(shot.data(0))
    end
  end

  describe 'Sample#stretch(mode: :none)' do
    let(:smp) { MB::Sound::Sample[Numo::SFloat.new(4800).seq / 4800, bpm: 100] }

    it 'keeps the audio and changes the length: zeros after it, or a faded cut' do
      long = smp.stretch(1.5, mode: :none)
      expect(long.length).to eq(7200)
      expect(long.data(0)[0...4800]).to eq(smp.data(0))
      expect(long.data(0)[4800..].abs.max).to eq(0)
      expect(long.bpm).to be_within(1e-9).of(100 / 1.5)
      expect(smp.stretch(1, mode: :none).data(0)).to eq(smp.data(0))

      cut = smp.stretch(0.5, mode: :none)
      expect(cut.length).to eq(2400)
      expect(cut.data(0)[0...(2400 - 192)]).to eq(smp.data(0)[0...(2400 - 192)])
      expect(cut.data(0)[-1].abs).to be < 1e-4
      hard = smp.stretch(0.5, mode: :none, fade: 0)
      expect(hard.data(0)).to eq(smp.data(0)[0...2400])
      expect(smp.stretch(0.5, mode: :unstretched).data(0)).to eq(cut.data(0))
      expect(smp.stretch(0.5, mode: :as_recorded).data(0)).to eq(cut.data(0))
    end

    it 'pads and cuts reversed samples in play order' do
      r = smp.rev.stretch(1.5, mode: :none)
      expect(r).to be_reversed
      expect(r.data(0)[0...4800]).to eq(smp.rev.data(0))
      expect(r.data(0)[4800..].abs.max).to eq(0)
      expect(smp.rev.stretch(0.5, mode: :none, fade: 0).data(0)).to eq(smp.rev.data(0)[0...2400])
    end

    it 'takes only fade:' do
      expect { smp.stretch(2, mode: :none, window: 1024) }.to raise_error(ArgumentError, /only fade/)
      expect { smp.stretch(2, mode: :none, slices: 4) }.to raise_error(ArgumentError, /only fade/)
      expect { smp.stretch(0, mode: :none) }.to raise_error(ArgumentError, /positive/)
    end
  end

  describe 'Sample#stretch(mode: :spectral, transients:)' do
    let(:hits48) { [0, 6000, 12000, 24000, 30000, 36000] }
    let(:plain) { MB::Sound::Sample[bursts(48000, hits48), bpm: 120] }
    let(:marked) { plain.with(markers: hits48) }

    # RMS of the 64 samples from +pos+.
    def rms(data, pos) = Math.sqrt((Numo::DFloat.cast(data[pos...(pos + 64)])**2).mean)

    it 'takes positions, Lengths, Markers, and :markers in place of detection' do
      want = MB::Sound::Sample::Spectral.vocoder([Numo::DFloat.cast(plain.data(0))], 1.5, onsets: hits48)[0]
      byp = plain.stretch(1.5, mode: :spectral, transients: hits48)
      expect(Numo::DFloat.cast(byp.data(0))).to eq(Numo::DFloat.cast(Numo::SFloat.cast(want)))
      expect(byp.length).to eq(72000)
      expect(marked.stretch(1.5, mode: :spectral, transients: :markers).data(0)).to eq(byp.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: marked.markers).data(0)).to eq(byp.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: hits48.map(&:samples)).data(0)).to eq(byp.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: hits48.map { |h| h / 48000.0 }).data(0)).to eq(byp.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: plain.slices(at: hits48)).data(0)).to eq(byp.data(0))
    end

    it 'keeps the attacks at the positions, where the plain vocoder smears them' do
      guided = plain.stretch(1.5, mode: :spectral, transients: hits48).data(0)
      smeared = plain.stretch(1.5, mode: :spectral, transients: false).data(0)
      hits48[1..].each do |h|
        q = (h * 1.5).round
        expect(rms(guided, q)).to be > rms(smeared, q) * 1.2
        expect(rms(guided, q)).to be > rms(plain.data(0), h) * 0.8
      end
    end

    it 'detects onsets for :markers when the sample has none, and as before for true' do
      detected = plain.stretch(1.5, mode: :spectral)
      expect(plain.stretch(1.5, mode: :spectral, transients: :markers).data(0)).to eq(detected.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: true).data(0)).to eq(detected.data(0))
      expect(plain.stretch(1.5, mode: :spectral, transients: :onsets).data(0)).to eq(detected.data(0))
      expect(plain.with(markers: [0]).stretch(1.5, mode: :spectral, transients: :markers).data(0)).to eq(detected.data(0))
      # an empty list is no transient handling at all
      expect(plain.stretch(1.5, mode: :spectral, transients: []).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: false).data(0))
    end

    describe 'confirm:' do
      # Grid markers as a loop file's tend to be: two a few ms before
      # their hits, one after its hit, one on held sound with no attack,
      # none at the loop's start
      let(:grid) { [6000 - 300, 12000 - 430, 18000, 24000 + 40, 30000, 36000] }
      let(:found) { plain.onsets }

      it 'keeps the positions with an attack, each on its attack, and the start' do
        # (the detector puts each hit on its first sample that moves)
        expect(found).to eq([0, 6001, 12001, 24001, 30001, 36001])
        want = plain.stretch(1.5, mode: :spectral, transients: found).data(0)
        expect(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: true).data(0)).to eq(want)
        expect(plain.with(markers: grid).stretch(1.5, mode: :spectral, transients: :markers, confirm: true).data(0)).to eq(want)
        expect(plain.stretch(1.5, mode: :spectral, transients: plain.slices(at: [0] + grid), confirm: true).data(0)).to eq(want)
        # (as given, the markers put the unstretched spans and resets
        # early, and one on the held chord)
        expect(plain.stretch(1.5, mode: :spectral, transients: grid).data(0)).not_to eq(want)
        expect(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: false).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: grid).data(0))
      end

      it 'takes a reach' do
        # (5 ms leaves out the two hits whose markers are 6 and 9 ms early)
        expect(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: 5.ms).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: [0, 24001, 30001, 36001]).data(0))
        expect(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: 480).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: 10.ms).data(0))
      end

      it 'leaves a held sound\'s grid markers to the plain vocoder' do
        t = Numo::DFloat.new(48000).seq
        held = MB::Sound::Sample[Numo::SFloat.cast(Numo::NMath.sin(t * (2 * Math::PI * 220 / 48000)) * 0.3), bpm: 120]
        # (only its start counts, a sound that starts loud)
        expect(held.stretch(1.5, mode: :spectral, transients: [6000, 12000, 18000, 24000], confirm: true).data(0)).to eq(held.stretch(1.5, mode: :spectral, transients: [0]).data(0))
      end

      it 'reads reversed samples in play order, prints, and says what it is for' do
        back = grid.map { |h| 48000 - h }
        expect(plain.rev.stretch(1.5, mode: :spectral, transients: back, confirm: true).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: found).rev.data(0))
        expect(plain.stretch(1.5, mode: :spectral, transients: grid, confirm: true).lineage[3]).to eq({ mode: :spectral, transients: grid, confirm: true })
        expect { plain.stretch(1.5, mode: :spectral, confirm: true) }.to raise_error(ArgumentError, /confirm: is for transients: :markers or positions/)
        expect { plain.stretch(1.5, mode: :slice, confirm: true) }.to raise_error(ArgumentError, /confirm: is for/)
      end
    end

    it 'reads positions of reversed samples in play order' do
      back = hits48.map { |h| 48000 - h }
      expect(plain.rev.stretch(1.5, mode: :spectral, transients: back).data(0)).to eq(plain.stretch(1.5, mode: :spectral, transients: hits48).rev.data(0))
      expect(marked.rev.stretch(1.5, mode: :spectral, transients: :markers).length).to eq(72000)
    end

    it 'keeps them out of the random phases of :paul too, and says what it takes' do
      a = plain.stretch(2, mode: :paul, transients: hits48, window: 2048.samples)
      b = plain.stretch(2, mode: :paul, window: 2048.samples)
      expect(a.length).to eq(96000)
      expect(a.data(0)).not_to eq(b.data(0))
      expect { plain.stretch(1.5, mode: :spectral, transients: :grid) }.to raise_error(ArgumentError, /transients: is true/)
      expect { plain.stretch(1.5, transients: [0]) }.to raise_error(ArgumentError, /for mode: :spectral/)
      expect { plain.stretch(1.5, mode: :slice, transients: [0]) }.to raise_error(ArgumentError, /slice takes/)
    end
  end
end
