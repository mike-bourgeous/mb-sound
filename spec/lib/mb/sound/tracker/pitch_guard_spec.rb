require_relative '../../../../support/module_writer'
require_relative '../../../../support/pitch_track'

# The pitch guard (tracker-2): every pitch effect of every format, in a
# synthetic one-channel module playing a looped 16-frame sine, rendered by
# a Session and pitch-tracked per tick (PitchTrack), against the periods
# the format's math gives, written out here: the rendered pitch must follow
# them within a few cents on every checked tick.  This checks the Player's
# period math and the path from its log to the sampler voice (lanes,
# pitch marks, held notes across clips) together.  The formulas are the
# formats' (ProTracker's periods and sine, ST3's periods, FT2's linear
# periods, IT's linear slides) and measured behavior of openmpt123 on the
# same synthetic files (tick-0 rules, waveform shapes, arpeggio order),
# never the reference player's source.
RSpec.describe('tracker pitch guard', :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }
  let(:sine) { Array.new(64) { |j| Math.sin(2 * Math::PI * j / 16) * 0.9 } }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  PAL = 3_546_894.6
  # ProTracker's half sine (the vibrato table every PC tracker copied).
  SINE = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
          255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24].freeze

  def pt_sine(pos)
    pos &= 63
    pos < 32 ? SINE[pos] : -SINE[pos - 32]
  end

  # Renders +path+ (+mode+, +limits+) and returns the tracked frequency of
  # each of +ticks+ ticks (ticks of 2.5 / bpm seconds).
  def track(path, ticks, mode: :musical, limits: :format, bpm: 125)
    set = MB::Sound.mod_import(path, mode: mode, limits: limits)
    s = MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |x| sessions << x }
    MB::Sound::Session.with_context(session: s) { set.play(on: :now) }
    tick = 48_000 * 2.5r / bpm
    frames = (tick * ticks).ceil + 800
    bufs = Array.new((frames / 800.0).ceil) { s.process_buffer(800).map(&:dup) }
    mono = bufs.transpose.map { |c| SpecBuffers.join(c) }.reduce(:+)
    PitchTrack.per_tick(mono, tick, ticks)
  end

  # Checks +got+ (Hz of the sine) against +expected+ ({ tick => playback
  # rate in Hz }) within +cents+.
  def check(label, got, expected, cents: 3)
    expected.each do |tick, rate|
      hz = rate / 16.0
      f = got[tick]
      expect(f).not_to be_nil, "#{label}: tick #{tick} is silent"
      next unless f
      expect(PitchTrack.cents(hz, f).abs).to be < cents, "#{label}: tick #{tick} plays #{f.round(2)} Hz, the format says #{hz.round(2)}"
    end
  end

  # { tick => rate } for the six ticks of +row+ from +periods+ (a period
  # per tick) through +freq+.
  def row(row, periods, &freq)
    periods.each_with_index.to_h { |p, k| [row * 6 + k, freq.(p)] }
  end

  it 'MOD (ProTracker): slides, tone portamento, vibrato, arpeggio, fine slides, finetune, the period limits' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 1, param: 4 },
      [2, 0] => { note: 60, sample: 1, effect: 2, param: 8 },
      [3, 0] => { note: 60, sample: 1 },
      [4, 0] => { note: 72, effect: 3, param: 16 }, [5, 0] => { effect: 3, param: 0 },
      [6, 0] => { note: 60, sample: 1, effect: 4, param: 0x48 }, [7, 0] => { effect: 4, param: 0 },
      [8, 0] => { note: 60, sample: 1, effect: 0, param: 0x47 },
      [9, 0] => { note: 60, sample: 1, effect: 14, param: 0x12 }, [10, 0] => { effect: 14, param: 0x23 },
      [11, 0] => { note: 57, sample: 2 }, [12, 0] => { note: 81, sample: 2 },
      [13, 0] => { note: 48, sample: 1, effect: 2, param: 0x40 }, [14, 0] => { effect: 2, param: 0x40 },
    }
    path = tmp_path('pitch.mod')
    w.mod(path, samples: [{ name: 's', data: sine, volume: 64, loop: [0, 64] }, { name: 'ft2', data: sine, volume: 64, loop: [0, 64], finetune: 2 }],
                patterns: [w.pattern(4, cells)])
    pal = ->(p) { PAL / p }
    exp = {}
    exp.merge!(row(0, [428, 424, 420, 416, 412, 408], &pal), row(1, [408] * 6, &pal))
    exp.merge!(row(2, [428, 436, 444, 452, 460, 468], &pal))
    exp.merge!(row(4, [428, 412, 396, 380, 364, 348], &pal), row(5, [348, 332, 316, 300, 284, 268], &pal))
    # (ProTracker: the first tick plays the note's period; then the sine, depth 8 over 128, speed 4)
    exp.merge!(row(6, [428, *[0, 4, 8, 12, 16].map { |p| 428 + pt_sine(p) * 8 / 128.0 }], &pal))
    exp.merge!(row(7, [428, *[20, 24, 28, 32, 36].map { |p| 428 + pt_sine(p) * 8 / 128.0 }], &pal))
    exp.merge!(row(8, [428, 339, 285, 428, 339, 285], &pal))
    exp.merge!(row(9, [426] * 6, &pal), row(10, [429] * 6, &pal))
    # (finetune +2: A-1 502, A-3 its quarter)
    exp.merge!(row(11, [502] * 6, &pal), row(12, [125.5] * 6, &pal))
    # (4-channel MODs stop at ProTracker's C-1; the note's first tick, three
    # octaves below the last note, is left out: the tracker's Hilbert
    # transform spreads the jump over it)
    exp.merge!(row(13, [856] * 6, &pal).except(78), row(14, [856] * 6, &pal))
    check('MOD', track(path, 90), exp)

    # (limits: :none: the slide goes on past C-1, 64 periods a tick)
    open = track(path, 90, limits: :none)
    check('MOD limits: :none', open, row(13, [856, 920, 984, 1048, 1112, 1176], &pal).except(78).merge(row(14, [1176, 1240, 1304, 1368, 1432, 1496], &pal)))
    check('MOD limits: :none, below the limits', open, exp.reject { |k, _| k >= 78 })
  end

  it 'holds a ringing note\'s pitch across a pattern change into a pattern of other samples' do
    # (the held note's key is its sample: a scene change used to chase the
    # new clip's last key and retune it by the difference, cry4bass)
    p0 = w.pattern(4, { [0, 0] => { note: 66, sample: 3 }, [3, 0] => { effect: 13, param: 0 } })
    p1 = w.pattern(4, { [2, 0] => { note: 60, sample: 5 }, [3, 0] => { effect: 13, param: 0 } })
    path = tmp_path('held.mod')
    w.mod(path, samples: Array.new(5) { |i| { name: "s#{i}", data: sine, volume: 64, loop: [0, 64] } }, patterns: [p0, p1], orders: [0, 1])
    # (pattern 0 breaks after 4 rows: the note rings from tick 0 to 36, through the change at 24)
    exp = (1...48).to_h { |k| [k, PAL / (k < 36 ? 302 : 428)] }.except(36)
    check('held MOD note', track(path, 48), exp)
  end

  it 'MOD with more channels (FastTracker style): vibrato reads its waveform on the first tick too' do
    cells = { [0, 0] => { note: 60, sample: 1, effect: 4, param: 0x48 }, [1, 0] => { effect: 4, param: 0 },
              [2, 0] => { note: 60, sample: 1, effect: 14, param: 0x41 }, [3, 0] => { effect: 4, param: 0x48 }, [4, 0] => { effect: 4, param: 0 } }
    path = tmp_path('pitch8.mod')
    w.mod(path, samples: [{ name: 's', data: sine, volume: 64, loop: [0, 64] }], patterns: [w.pattern(8, cells)], channels: 8)
    pal = ->(p) { PAL / p }
    # (tick 0 reads the waveform without moving on; later ticks read, then move by the speed)
    exp = row(0, [0, 0, 4, 8, 12, 16].map { |p| 428 + pt_sine(p) * 8 / 128.0 }, &pal)
    exp.merge!(row(1, [20, 20, 24, 28, 32, 36].map { |p| 428 + pt_sine(p) * 8 / 128.0 }, &pal))
    # (the ramp: rising period from 0, so the pitch falls first)
    exp.merge!(row(3, [0, 0, 4, 8, 12, 16].map { |p| 428 + p * 8 * 8 / 128.0 }, &pal))
    exp.merge!(row(4, [20, 20, 24, 28, 32, 36].map { |p| 428 + (p < 32 ? p * 8 : p * 8 - 512) * 8 / 128.0 }, &pal))
    check('8-channel MOD', track(path, 30), exp)
  end

  it 'S3M (ST3 periods): slides, tone portamento, vibrato, arpeggio, fine slides' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 'F', param: 4 },
      [2, 0] => { note: 60, sample: 1, effect: 'E', param: 8 },
      [3, 0] => { note: 60, sample: 1 },
      [4, 0] => { note: 72, sample: 1, effect: 'G', param: 16 }, [5, 0] => { effect: 'G', param: 0 },
      [6, 0] => { note: 60, sample: 1, effect: 'H', param: 0x48 }, [7, 0] => { effect: 'H', param: 0 },
      [8, 0] => { note: 60, sample: 1, effect: 'J', param: 0x47 },
      [9, 0] => { note: 60, sample: 1, effect: 'F', param: 0xF2 },
      [10, 0] => { note: 60, sample: 1, effect: 'S', param: 0x31 }, [11, 0] => { effect: 'H', param: 0x48 },
    }
    path = tmp_path('pitch.s3m')
    w.s3m(path, samples: [{ name: 's', data: sine, loop: [0, 64], c2spd: 8363 }], patterns: [w.pattern(1, cells)], channels: 1)
    st3 = ->(p) { 14_317_056.0 / p }
    exp = {}
    # (C-4 at C2Spd 8363 is period 1712; slides move 4 periods a unit)
    exp.merge!(row(0, [1712, 1696, 1680, 1664, 1648, 1632], &st3), row(1, [1632] * 6, &st3))
    exp.merge!(row(2, [1712, 1744, 1776, 1808, 1840, 1872], &st3))
    exp.merge!(row(4, [1712, 1648, 1584, 1520, 1456, 1392], &st3), row(5, [1392, 1328, 1264, 1200, 1136, 1072], &st3))
    # (ST3's vibrato: the sine times the depth over 32, read without moving on at the first tick)
    exp.merge!(row(6, [0, 0, 4, 8, 12, 16].map { |p| 1712 + pt_sine(p) * 8 / 32.0 }, &st3))
    exp.merge!(row(7, [20, 20, 24, 28, 32, 36].map { |p| 1712 + pt_sine(p) * 8 / 32.0 }, &st3))
    exp.merge!(row(8, [0, 4, 7, 0, 4, 7].map { |s| 1712 * 2**(-s / 12.0) }, &st3))
    exp.merge!(row(9, [1704] * 6, &st3))
    # (ST3's ramp lowers the period first: the pitch rises)
    exp.merge!(row(11, [0, 0, 4, 8, 12, 16].map { |p| 1712 - p * 8 * 8 / 32.0 }, &st3))
    check('S3M', track(path, 72), exp)
  end

  it 'XM (linear frequencies): slides, tone portamento, vibrato, arpeggio in FT2 order, fine slides' do
    cells = {
      [0, 0] => { note: 60, instrument: 1, effect: 1, param: 4 },
      [2, 0] => { note: 60, instrument: 1, effect: 2, param: 8 },
      [3, 0] => { note: 60, instrument: 1 },
      [4, 0] => { note: 72, instrument: 1, effect: 3, param: 16 }, [5, 0] => { effect: 3, param: 0 },
      [6, 0] => { note: 60, instrument: 1, effect: 4, param: 0x48 }, [7, 0] => { effect: 4, param: 0 },
      [8, 0] => { note: 60, instrument: 1, effect: 0, param: 0x47 },
      [9, 0] => { note: 60, instrument: 1, effect: 14, param: 0x12 },
      [10, 0] => { note: 60, instrument: 2 },
    }
    path = tmp_path('pitch.xm')
    w.xm(path, instruments: [{ samples: [{ data: sine, loop: [0, 64] }] }, { samples: [{ data: sine, loop: [0, 64], finetune: 46 }] }],
               patterns: [w.pattern(1, cells)], channels: 1, linear: true)
    lin = ->(p) { 8363.0 * 2**((4608 - p) / 768.0) }
    exp = {}
    # (C-4 is linear period 4608, 64 a semitone; slides move 4 a unit)
    exp.merge!(row(0, [4608, 4592, 4576, 4560, 4544, 4528], &lin), row(1, [4528] * 6, &lin))
    exp.merge!(row(2, [4608, 4640, 4672, 4704, 4736, 4768], &lin))
    exp.merge!(row(4, [4608, 4544, 4480, 4416, 4352, 4288], &lin), row(5, [4288, 4224, 4160, 4096, 4032, 3968], &lin))
    # (FT2: the sine times the depth over 32, read without moving on at the first tick)
    exp.merge!(row(6, [0, 0, 4, 8, 12, 16].map { |p| 4608 + pt_sine(p) * 8 / 32.0 }, &lin))
    exp.merge!(row(7, [20, 20, 24, 28, 32, 36].map { |p| 4608 + pt_sine(p) * 8 / 32.0 }, &lin))
    # (FT2's tick counter runs down: 0, y, x at speed 6)
    exp.merge!(row(8, [0, 7, 4, 0, 7, 4].map { |s| 4608 - s * 64 }, &lin))
    exp.merge!(row(9, [4600] * 6, &lin))
    # (finetune 46 steps as 40, 1/16 semitones: 20 linear periods, not 23)
    exp.merge!(row(10, [4588] * 6, &lin).except(60))
    check('XM', track(path, 66), exp)
  end

  it 'IT (linear slides): slides, tone portamento, vibrato on every tick, arpeggio' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 'F', param: 4 },
      [2, 0] => { note: 60, sample: 1, effect: 'E', param: 8 },
      [3, 0] => { note: 60, sample: 1 },
      [4, 0] => { note: 72, sample: 1, effect: 'G', param: 16 }, [5, 0] => { effect: 'G', param: 0 },
      [6, 0] => { note: 60, sample: 1, effect: 'H', param: 0x48 }, [7, 0] => { effect: 'H', param: 0 },
      [8, 0] => { note: 60, sample: 1, effect: 'J', param: 0x47 },
      [9, 0] => { note: 60, sample: 1, effect: 'S', param: 0x32 }, [10, 0] => { effect: 'H', param: 0x48 },
    }
    path = tmp_path('pitch.it')
    w.it(path, samples: [{ data: sine, loop: [0, 64], c5speed: 8363 }], patterns: [w.pattern(1, cells)], channels: 1, linear: true)
    lin = ->(p) { 8363.0 * 2**((3840 - p) / 768.0) }
    exp = {}
    # (C-5 is linear period 3840; slides move 4 a unit)
    exp.merge!(row(0, [3840, 3824, 3808, 3792, 3776, 3760], &lin), row(1, [3760] * 6, &lin))
    exp.merge!(row(2, [3840, 3872, 3904, 3936, 3968, 4000], &lin))
    exp.merge!(row(4, [3840, 3776, 3712, 3648, 3584, 3520], &lin), row(5, [3520, 3456, 3392, 3328, 3264, 3200], &lin))
    # (IT moves on and reads every tick, the first included, upward first;
    # openmpt123 plays depth 8 at speed 4 as 19, 31, 44, 50, 44, 31 cents:
    # 12, 20, 28, 32 1/64 semitones, steps of 4 above 16)
    exp.merge!(row(6, [12, 20, 28, 32, 28, 20].map { |d| 3840 - d }, &lin))
    exp.merge!(row(7, [12, 0, -12, -20, -28, -32].map { |d| 3840 - d }, &lin))
    exp.merge!(row(8, [0, 4, 7, 0, 4, 7].map { |s| 3840 - s * 64 }, &lin))
    # (IT's square is up for half its cycle, then 0: depth 8 is 1/2 semitone)
    exp.merge!(row(10, [3840 - 32] * 6, &lin))
    check('IT', track(path, 66), exp)
  end

  it 'IT: tone portamento onto another sample plays it at once and slides to the note at its rate' do
    s8 = Array.new(64) { |j| Math.sin(2 * Math::PI * j / 8) * 0.9 }
    cells = { [0, 0] => { note: 60, sample: 1 }, [2, 0] => { note: 52, sample: 2, effect: 'G', param: 0x20 }, [3, 0] => { effect: 'G', param: 0 } }
    path = tmp_path('porta.it')
    w.it(path, samples: [{ data: sine, loop: [0, 64], c5speed: 22_050 }, { data: s8, loop: [0, 64], c5speed: 44_100 }], patterns: [w.pattern(1, cells, rows: 8)],
               channels: 1, linear: true)
    # (rates as 16-frame sines: the 8-frame sample sounds an octave up; openmpt123: 2756, 3094, then 3473 Hz)
    lin = ->(p, rate) { rate * 2**((3840 - p) / 768.0) * 2 }
    p0 = 3840 + 768 * Math.log2(2) # (C-5 at 22050 Hz as a period of the 44100 Hz sample)
    target = 3840 + 8 * 64
    exp = row(0, [3840] * 6) { |p| lin.(p, 22_050) / 2 }
    exp.merge!(row(2, [p0, p0 - 128, target, target, target, target]) { |p| lin.(p, 44_100) })
    check('IT porta onto a new sample', track(path, 24), exp)
  end

  it '669: Hz slides' do
    cells = { [0, 0] => { note: 60, sample: 1, effect: 0, param: 2 }, [2, 0] => { note: 60, sample: 1, effect: 1, param: 2 } }
    path = tmp_path('pitch.669')
    w.six_six_nine(path, samples: [{ name: 's', data: sine, loop: [0, 64] }], patterns: [w.pattern(8, cells)], tempos: [6])
    rate = MB::Sound::Tracker::SixSixNineReader::RATE
    # (2 units of 80 Hz a tick, from the first tick: measured from openmpt123 in tracker-1)
    exp = row(0, (1..6).map { |k| rate + 160 * k }) { |r| r }
    exp.merge!(row(2, (1..6).map { |k| rate - 160 * k }) { |r| r })
    check('669', track(path, 18, bpm: 78), exp, cents: 4)
  end
end
