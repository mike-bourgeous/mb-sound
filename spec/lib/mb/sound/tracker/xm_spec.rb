require_relative '../../../../support/module_writer'

# FastTracker 2 modules (tracker-1): synthetic files from ModuleWriter.
RSpec.describe(MB::Sound::Tracker::XMReader, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }

  def instruments
    [
      { name: 'lead', samples: [{ name: 'saw', data: w.saw(4000), loop: [2000, 4000], loop_type: :ping_pong, relative: 12, finetune: 16 },
                                { name: 'hi', data: w.saw(800), bits: 16, volume: 32, pan: 0 }],
        keymap: [0] * 48 + [1] * 48, fadeout: 4096,
        volume_envelope: { points: [[0, 64], [4, 32], [8, 16]], sustain: 1 }, pan_envelope: { points: [[0, 32], [10, 0]] } },
      { name: 'plain', samples: [{ name: 'click', data: w.click(300), volume: 48 }] },
    ]
  end

  def write(cells = {}, patterns: nil, orders: [0], **options)
    path = tmp_path('spec.xm')
    w.xm(path, instruments: options.delete(:instruments) || instruments, patterns: patterns || [w.pattern(4, cells)], orders: orders, **options)
  end

  def run(path, mode: :musical)
    t::Player.for(t.read(path), mode: mode).run
  end

  def freq(period)
    8363.0 * 2**((4608 - period.to_f) / 768)
  end

  it 'reads instruments, keymaps, envelopes, samples, and packed cells' do
    song = t.read(write({ [0, 0] => { note: 60, instrument: 1, volume: 0x30, effect: 10, param: 0x02 }, [2, 3] => { note: :off } }, speed: 3, tempo: 140))
    expect([song.format, song.channels, song.speed, song.tempo, song.linear]).to eq([:xm, 4, 3, 140, true])
    expect(song.samples.length).to eq(3)
    expect(song.instruments.length).to eq(2)
    lead = song.instruments[0]
    expect(lead.keymap[60]).to eq([1, 60]) # (keymap entry 48: XM note 49, C-4)
    expect(lead.keymap[59]).to eq([0, 59])
    expect(lead.volume_envelope.points).to eq([[0, 64], [4, 32], [8, 16]])
    expect(lead.volume_envelope.sustain).to eq([1, 1])
    expect(lead.fadeout).to eq(4096)
    expect(song.instruments[1].keymap[60]).to eq([2, 60])
    s0, s1 = song.samples
    expect([s0.loop, s0.loop_mode, s0.relative_note, s0.finetune]).to eq([[2000, 4000], :ping_pong, 12, 16])
    expect([s1.bits, s1.length, s1.volume, s1.pan]).to eq([16, 800, 32, 0])
    expect(s0.data[0][100]).to be_within(1 / 128.0).of(w.saw(4000)[100])
    expect(s1.data[0][100]).to be_within(1e-4).of(w.saw(800)[100])
    c = song.patterns[0].rows[0][0]
    expect([c.note, c.instrument, c.volume, c.effect, c.param]).to eq([60, 1, 0x30, 10, 2])
    expect(song.patterns[0].rows[2][3].note).to eq(:off)
  end

  it 'plays linear periods with relative notes and finetune, and the volume envelope with fadeout after key off' do
    cells = { [0, 0] => { note: 48, instrument: 1 }, [4, 0] => { note: :off }, [0, 1] => { note: 60, instrument: 2 } }
    r = run(write(cells, speed: 2), mode: :hardware)
    a, b = r.logs
    # (note 48 plays the saw a semitone-scaled octave up: relative 12, finetune 16)
    expect(a.freq[0]).to eq(freq(7680 - (48 - 12 + 12) * 64 - 8))
    expect(b.freq[0]).to eq(8363.0)
    # envelope 64 -> 32 over 4 ticks, held at the sustain point (32) until key off at tick 8
    expect(a.volume[0..8].map { |v| (v * 64).round(2) }).to eq([64, 56, 48, 40, 32, 32, 32, 32, 32])
    # after key off: on to 16 over 4 ticks while fading by 4096 / 32768 a tick
    expect(a.volume[9] * 64).to be_within(1e-9).of(28 * (1 - 4096 / 32_768.0))
    expect(a.volume[16]).to eq(0)
    expect(b.volume[0]).to eq(48 / 64.0)
  end

  it 'plays the volume column, memories, global volume, key off effect, and pan envelope' do
    cells = {
      [0, 0] => { note: 60, instrument: 2, volume: 0x10 + 40 }, [1, 0] => { volume: 0x62 }, [2, 0] => { volume: 0x94 },
      [0, 1] => { note: 60, instrument: 2, effect: 1, param: 4 }, [1, 1] => { effect: 1, param: 0 },
      [0, 2] => { note: 48, instrument: 1, effect: 20, param: 3 },
      [0, 3] => { effect: 16, param: 32 },
    }
    r = run(write(cells, speed: 3), mode: :hardware)
    a, b, c = r.logs
    expect(a.volume[0..7].map { |v| (v * 64 * 2).round }).to eq([40, 40, 40, 40, 38, 36, 40, 40]) # (global volume 32 halves it)
    expect(b.freq[0..5]).to eq([4608, 4592, 4576, 4576, 4560, 4544].map { |p| freq(p) })
    expect(c.volume[2] * 2 * 64).to be > c.volume[4] * 2 * 64
    expect(c.pan[0]).to be_within(0.01).of(0.0)
    expect(c.pan[5]).to be_within(0.01).of(-0.5) # (the pan envelope halfway down to 0)
  end

  it 'imports instruments as one sampler keymap of their samples' do
    set = MB::Sound.mod_import(write({ [0, 0] => { note: 48, instrument: 1 }, [0, 1] => { note: 72, instrument: 1 }, [4, 2] => { note: 60, instrument: 2 } }))
    expect(set.instrument.regions.map { |r| r.keys[0] }).to eq([1, 2, 3])
    expect(set[:p00][:ch1].events[0].value).to eq(1)
    expect(set[:p00][:ch2].events[0].value).to eq(2)
    expect(set[:p00][:ch3].events.map { |e| [e.start, e.value, e.pitch] }).to eq([[24/96r, 3, 0]])
  end
end
