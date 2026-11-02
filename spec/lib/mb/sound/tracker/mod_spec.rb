require_relative '../../../../support/module_writer'

# MOD modules (tracker-1): synthetic files from ModuleWriter, read into a
# Song, played tick by tick, and imported as a set.
RSpec.describe(MB::Sound::Tracker::ModReader, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def write(cells = {}, patterns: nil, orders: [0], channels: 4, samples: nil, **options)
    path = tmp_path('spec.mod')
    samples ||= [{ name: 'saw', data: w.saw(2000), volume: 64, loop: [1000, 2000] }, { name: 'click', data: w.click(400), volume: 48 }]
    w.mod(path, samples: samples, patterns: patterns || [w.pattern(channels, cells)], orders: orders, channels: channels, **options)
  end

  def run(path, mode: :musical)
    song = t.read(path)
    t::Player.for(song, mode: mode).run
  end

  def session
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  # The set's flow from the start, +frames+ frames in +buffer+-frame buffers.
  def play(set, frames, buffer: 800)
    s = session
    MB::Sound::Session.with_context(session: s) { set.play(on: :now) }
    bufs = []
    left = frames
    while left > 0
      n = [buffer, left].min
      bufs << s.process_buffer(n).map(&:dup)
      left -= n
    end
    bufs.transpose.map { |c| SpecBuffers.join(c) }
  end

  # Frames where the summed channels first pass +level+, at least +gap+
  # apart.
  def onsets(chans, level: 0.1, gap: 2000)
    m = chans.map(&:abs).reduce(:+)
    found = []
    i = 0
    while i < m.length
      if m[i] > level
        found << i
        i += gap
      else
        i += 1
      end
    end
    found
  end

  describe 'reading' do
    it 'reads the header, samples, orders, and cells' do
      cells = { [0, 0] => { note: 60, sample: 1 }, [3, 2] => { note: 72, sample: 2, effect: 12, param: 32 }, [5, 3] => { effect: 15, param: 3 } }
      song = t.read(write(cells, orders: [0, 0], title: 'hello'))
      expect(song.format).to eq(:mod)
      expect(song.title).to eq('hello')
      expect(song.channels).to eq(4)
      expect(song.orders).to eq([0, 0])
      expect(song.pans).to eq([-1.0, 1.0, 1.0, -1.0])
      expect(song.samples[0].name).to eq('saw')
      expect(song.samples[0].length).to eq(2000)
      expect(song.samples[0].loop).to eq([1000, 2000])
      expect(song.samples[1].loop).to be_nil
      expect(song.samples[1].volume).to eq(48)
      expect(song.samples[0].data[0][1]).to be_within(1 / 128.0).of(w.saw(2000)[1])
      c = song.patterns[0].rows[3][2]
      expect([c.note, c.instrument, c.effect, c.param, c.period]).to eq([72, 2, 12, 32, 214])
      expect(song.patterns[0].rows[5][3].note).to be_nil
      expect(song.patterns[0].rows[1][1]).to be_nil
    end

    it 'reads multichannel signatures' do
      song = t.read(write({ [0, 5] => { note: 60, sample: 1 } }, channels: 6))
      expect(song.channels).to eq(6)
      expect(song.patterns[0].rows[0][5].note).to eq(60)
      expect(t::ModReader.channels_for('12CH')).to eq(12)
      expect(t::ModReader.channels_for('FLT8')).to eq(8)
    end

    it 'raises for files it does not know and warns about truncated ones' do
      bad = tmp_path('x.mod')
      File.binwrite(bad, 'x' * 2000)
      expect { t.read(bad) }.to raise_error(t::FormatError, /not a module/)
      File.binwrite(bad, File.binread(write)[0...-300])
      song = t.read(bad)
      expect(song.problems.join).to match(/truncated/)
      File.binwrite(bad, File.binread(write)[0, 1100])
      expect(t.read(bad).problems.join).to match(/patterns are past the end/)
    end
  end

  describe 'playing' do
    it 'counts speed and tempo in ticks and stops where the song ends' do
      cells = { [0, 0] => { note: 60, sample: 1, effect: 15, param: 3 }, [1, 1] => { effect: 15, param: 150 } }
      r = run(write(cells, orders: [0, 0]))
      expect(r.ticks).to eq(2 * 64 * 3)
      expect(r.tempos).to eq([[0, 125], [3, 150]])
      expect(r.visits.map(&:start)).to eq([0, 192])
      expect(r.restart).to be_nil
    end

    it 'follows pattern breaks, jumps, loops, and delays, and finds where the song loops back' do
      p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [4, 1] => { effect: 13, param: 0x12 } })
      p1 = w.pattern(4, { [12, 0] => { note: 60, sample: 1 }, [13, 0] => { effect: 14, param: 0x60 }, [15, 0] => { effect: 14, param: 0x62 },
                          [16, 1] => { effect: 14, param: 0xE2 }, [17, 2] => { effect: 11, param: 1 } })
      r = run(write(patterns: [p0, p1], orders: [0, 1]))
      v0, v1 = r.visits
      expect(v0.rows.map(&:first)).to eq([0, 1, 2, 3, 4])
      expect(v1.first_row).to eq(12)
      # rows 13-15 three times (the loop), row 16 three times as long (the delay)
      expect(v1.rows.map(&:first).first(10)).to eq([12, 13, 14, 15, 13, 14, 15, 13, 14, 15])
      expect(v1.rows.find { |row, _, _| row == 16 }[2]).to eq(18)
      # B01 at row 17 jumps to order 1 again (row 0): the song loops there
      expect(v1.rows.last.first).to eq(17)
      expect(r.visits.length).to eq(3)
      expect(r.visits[2].first_row).to eq(0)
      expect(r.restart).to be_nil.or(be_an(Array))
    end

    it 'marks where the song comes back to when it loops' do
      p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 } })
      p1 = w.pattern(4, { [63, 0] => { effect: 11, param: 1 } })
      r = run(write(patterns: [p0, p1], orders: [0, 1]))
      expect(r.visits.map(&:order)).to eq([0, 1])
      expect(r.restart).to eq([1, 384])
    end

    it 'plays volumes, slides, cuts, delays, offsets, and retriggers' do
      cells = {
        [0, 0] => { note: 60, sample: 1, effect: 12, param: 32 }, [1, 0] => { effect: 10, param: 0x20 }, [2, 0] => { effect: 14, param: 0xC2 },
        [0, 1] => { note: 60, sample: 2, effect: 14, param: 0xD3 }, [2, 1] => { note: 60, sample: 1, effect: 9, param: 2 },
        [0, 2] => { note: 60, sample: 1, effect: 14, param: 0x92 },
      }
      r = run(write(cells))
      a, b, c = r.logs
      expect(a.volume[0..17].map { |v| (v * 64).round }).to eq([32] * 7 + [34, 36, 38, 40, 42] + [42, 42, 0, 0, 0, 0])
      expect(b.triggers.map { |x| [x.tick, x.sample, x.offset] }).to eq([[3, 1, 0], [12, 0, 512]])
      expect(b.volume[3]).to eq(48 / 64.0)
      expect(c.triggers.map(&:tick)).to eq([0, 2, 4])
    end

    it 'slides pitch: portamento, tone portamento, vibrato, and arpeggio' do
      cells = {
        [0, 0] => { note: 60, sample: 1, effect: 1, param: 4 },
        [0, 1] => { note: 60, sample: 1 }, [1, 1] => { note: 72, effect: 3, param: 64 },
        [0, 2] => { note: 60, sample: 1, effect: 0, param: 0x47 },
        [0, 3] => { note: 60, sample: 1, effect: 4, param: 0x88 },
      }
      r = run(write(cells), mode: :hardware)
      pal = MB::Sound::Tracker::Player::Amiga::PAL
      a, b, c, d = r.logs
      expect(a.freq[0..2]).to eq([pal / 428, pal / 424, pal / 420])
      expect(b.freq[6..8]).to eq([pal / 428, pal / 364, pal / 300])
      expect(b.freq[11]).to eq(pal / 214)
      expect(b.triggers.length).to eq(1)
      expect(c.freq[0..3]).to eq([pal / 428, pal / 339, pal / 285, pal / 428])
      expect(d.freq[0]).to eq(pal / 428)
      # (ProTracker's vibrato: sine[pos] * depth >> 7, pos += speed)
      sine = MB::Sound::Tracker::Player::SINE
      expect(d.freq[1..5].map { |f| (pal / f).round }).to eq([0, 8, 16, 24, 32].map { |pos| 428 + ((sine[pos & 31] * 8) >> 7) * (pos < 32 ? 1 : -1) })
    end

    it 'plays the table notes and table arpeggios in :musical mode, finetuned rows halved per octave' do
      samples = [{ name: 'saw', data: w.saw(2000), volume: 64, loop: [1000, 2000] }, { name: 'ft2', data: w.saw(2000), volume: 64, loop: [1000, 2000], finetune: 2 }]
      cells = { [0, 0] => { note: 60, sample: 1, effect: 0, param: 0x47 }, [0, 1] => { note: 61, sample: 1 },
                [0, 2] => { note: 57, sample: 2 }, [0, 3] => { note: 81, sample: 2 } }
      r = run(write(cells, samples: samples), mode: :musical)
      a, b, c, d = r.logs
      pal = MB::Sound::Tracker::Player::Amiga::PAL
      expect(a.freq[0]).to be_within(1e-9).of(pal / 428)
      # (the arpeggio's notes are the table's: 339 and 285, as the composer heard them)
      expect(a.freq[1]).to be_within(1e-9).of(pal / 339)
      expect(a.freq[2]).to be_within(1e-9).of(pal / 285)
      expect(b.freq[0]).to be_within(1e-9).of(pal / 404)
      # (finetune 2: A-1 is 502, A-3 its quarter, 125.5)
      ft2 = MB::Sound::Tracker::ModReader::FINETUNE_PERIODS[2]
      expect(ft2[9]).to eq(502)
      expect(c.freq[0]).to be_within(1e-9).of(pal / 502)
      expect(d.freq[0]).to be_within(1e-9).of(pal / 125.5)
    end

    it 'lists effects it skips' do
      r = run(write({ [0, 0] => { note: 60, sample: 1, effect: 14, param: 0x31 }, [1, 0] => { effect: 14, param: 0xF1 } }))
      expect(r.unsupported).to eq('E3x glissando' => 1, 'EFx invert loop' => 1)
    end
  end

  describe 'importing' do
    let(:cells) {
      { [0, 0] => { note: 60, sample: 2 }, [5, 1] => { note: 60, sample: 2 }, [16, 2] => { note: 72, sample: 2, effect: 15, param: 3 },
        [17, 3] => { note: 60, sample: 2 }, [20, 0] => { note: 60, sample: 2, effect: 13, param: 0 } }
    }
    let(:path) { write(cells, patterns: [w.pattern(4, cells), w.pattern(4, { [0, 0] => { note: 60, sample: 2 } })], orders: [0, 1, 0]) }

    it 'makes tracks, clips in exact whole notes with lanes, scenes, and a flow' do
      set = MB::Sound.mod_import(path)
      expect(set.tracks).to eq(%i[ch1 ch2 ch3 ch4])
      expect(set.scenes).to eq(%i[p00 p01 p00_b])
      expect(set.plays.map(&:first)).to eq(%i[p00 p01 p00_b])
      # 16 rows of 6 ticks, 4 of 3, the break row: 111 ticks of 1/96
      expect(set.plays[0][1]).to eq(111/96r)
      ch2 = set[:p00][:ch2]
      expect(ch2.events.map { |e| [e.start, e.value, e.pitch] }).to eq([[30/96r, 2, 0]])
      expect(ch2.length).to eq(111/96r)
      expect(ch2).to be_looping
      expect(set[:p00][:ch3].events[0].pitch).to eq(12)
      expect(ch2.controls.map { |l| [l.type, l.number] }).to eq([[:bend, nil], [:cc, 7], [:cc, 10]])
      expect(ch2.control(7).points).to eq([[0r, 0.0], [30/96r, 0.75]])
      # (the third visit plays pattern 0 at speed 3, so it is a scene of its own)
      expect(set.plays[2][1]).to eq(21 * 3/96r)
      expect(set.seconds).to be_within(1e-9).of((111 + 192 + 63) * 2.5 / 125)
    end

    it 'starts notes on their exact samples at any buffer size' do
      set = MB::Sound.mod_import(path, mode: :hardware)
      frames = (111 + 192 + 63) * 960
      tick = 960 # (2.5 / 125 s at 48 kHz)
      expected = [0, 30, 96, 99, 108, 111, 111 + 192].map { |k| k * tick }
      ref = play(set, frames)
      expect(onsets(ref).first(7)).to eq(expected)
      [367, 64].each { |bs|
        other = play(set, frames, buffer: bs)
        expect(onsets(other).first(7)).to eq(expected)
        expect((other[0] - ref[0]).abs.max).to be < 1e-4
      }
    end

    it 'plays the musical mode band-limited, within a few samples of the hardware notes' do
      saws = cells.transform_values { |c| c.merge(sample: 1) }
      set = MB::Sound.mod_import(write(saws, samples: [{ name: 'saw', data: w.saw(2000) }]), separation: 1.0)
      left, right = play(set, 100_000)
      # (lanes step over 1.5 ms in :musical mode: a 72-sample declick;
      # channels 1 and 4 are on the left, 2 and 3 on the right)
      found = [onsets([left], gap: 20_000).first(2), onsets([right], gap: 20_000).first(2)]
      expect(found.flatten.zip([0, 95_040, 28_800, 92_160]).map { |a, b| (a - b).abs }.max).to be <= 40
    end
  end
end
