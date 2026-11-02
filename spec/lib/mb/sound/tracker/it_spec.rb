require_relative '../../../../support/module_writer'

# Impulse Tracker modules (tracker-1): synthetic files from ModuleWriter.
RSpec.describe(MB::Sound::Tracker::ITReader, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }

  def samples
    [
      { name: 'saw', data: w.saw(4000), loop: [2000, 4000], volume: 48, global_volume: 32, c5speed: 16_000 },
      { name: 'one', data: w.saw(2000), bits: 16, pan: 16 },
    ]
  end

  def instruments
    [
      { name: 'pad', keymap: Array.new(120) { |n| [n, n < 60 ? 1 : 2] }, nna: 3, fadeout: 128, global_volume: 64, pan: 48,
        volume_envelope: { points: [[0, 64], [4, 32], [8, 32]], sustain: [1, 2] }, pitch_envelope: { points: [[0, 0], [4, 8]] } },
      { name: 'cut', keymap: 2, nna: 0 },
    ]
  end

  def write(cells = {}, patterns: nil, orders: [0], **options)
    path = tmp_path('spec.it')
    w.it(path, samples: options.delete(:samples) || samples, instruments: options.key?(:instruments) ? options.delete(:instruments) : instruments,
               patterns: patterns || [w.pattern(4, cells)], orders: orders, **options)
  end

  def run(path, mode: :musical)
    t::Player.for(t.read(path), mode: mode).run
  end

  def linear(rate, period)
    rate * 2**((3840 - period.to_f) / 768)
  end

  it 'reads the header, instruments with keyboards and envelopes, samples, and packed cells' do
    cells = { [0, 0] => { note: 60, instrument: 1, volume: 40, effect: 'D', param: 0x04 }, [1, 3] => { note: :off }, [2, 3] => { note: :fade } }
    song = t.read(write(cells, speed: 4, tempo: 150, global_volume: 96, pans: [0, 64, 32, 32], volumes: [64, 32, 64, 64]))
    expect([song.format, song.channels, song.speed, song.tempo, song.linear, song.global_volume]).to eq([:it, 4, 4, 150, true, 48.0])
    expect(song.pans).to eq([-1.0, 1.0, 0.0, 0.0])
    expect(song.channel_volumes).to eq([64, 32, 64, 64])
    pad, cut = song.instruments
    expect([pad.nna, pad.fadeout, pad.global_volume, pad.pan]).to eq([3, 128, 64, 48])
    expect(pad.keymap[59]).to eq([0, 59])
    expect(pad.keymap[60]).to eq([1, 60])
    expect(pad.volume_envelope.points).to eq([[0, 64], [4, 32], [8, 32]])
    expect(pad.volume_envelope.sustain).to eq([1, 2])
    expect(pad.pitch_envelope.points).to eq([[0, 0], [4, 8]])
    expect(cut.keymap[30]).to eq([1, 30])
    s0, s1 = song.samples
    expect([s0.loop, s0.volume, s0.global_volume, s0.rate, s0.pan]).to eq([[2000, 4000], 48, 32, 16_000.0, nil])
    expect([s1.bits, s1.pan, s1.length]).to eq([16, 16, 2000])
    c = song.patterns[0].rows[0][0]
    expect([c.note, c.instrument, c.volume, c.effect, c.param]).to eq([60, 1, 40, 4, 4])
    expect(song.patterns[0].rows[1][3].note).to eq(:off)
    expect(song.patterns[0].rows[2][3].note).to eq(:fade)
  end

  it 'reads IT 2.14 and 2.15 compressed samples' do
    data = Array.new(3000) { |i| 0.6 * Math.sin(i * 0.02) + (i % 500 == 0 ? 0.3 : 0) }
    [[8, true], [8, :it215], [16, true], [16, :it215]].each { |bits, how|
      song = t.read(write(samples: [{ name: 'c', data: data, bits: bits, compressed: how }], instruments: nil))
      q = bits == 16 ? 32_768.0 : 128.0
      expected = data.map { |x| (x.clamp(-1.0, (q - 1) / q) * q).round / q }
      expect((song.samples[0].data[0] - Numo::SFloat.cast(expected)).abs.max).to be < 1e-6
    }
  end

  it 'plays linear periods from C5Speed, volumes from every level, envelopes, and pitch envelopes' do
    cells = { [0, 0] => { note: 48, instrument: 1 }, [2, 0] => { note: :off }, [0, 1] => { note: 72, instrument: 1 } }
    r = run(write(cells, speed: 3, global_volume: 64), mode: :hardware)
    a, b = r.logs
    expect(a.freq[0]).to eq(linear(16_000, 7680 - 48 * 64))
    # (the pitch envelope reaches 8, four semitones, at tick 4)
    expect(a.freq[4]).to be_within(1e-9).of(linear(16_000, 7680 - 48 * 64 - 4 * 64))
    # 48/64 x sample 32/64 x instrument 64/128 x global 64/128 x envelope
    level = 48 / 64.0 * 0.5 * 0.5 * 0.5
    expect(a.volume[0..5].map { |v| (v / level * 64).round(3) }).to eq([64, 56, 48, 40, 32, 32])
    # key off at tick 6 releases the sustain loop: the envelope plays to its
    # end, then the note fades by 128/1024 a tick
    expect(a.volume[6] / level * 64).to be_within(1e-9).of(32)
    expect(a.volume[6 + 4]).to be < a.volume[6]
    expect(a.volume[6 + 4 + 8]).to eq(0)
    expect(b.freq[0]).to eq(linear(8363, 7680 - 72 * 64))
    expect(b.pan[0]).to eq(16 / 32.0 - 1) # (the sample's pan wins)
  end

  it 'moves a sounding note to a background voice by its new note action' do
    cells = { [0, 0] => { note: 48, instrument: 1 }, [1, 0] => { note: 50, instrument: 1 }, [2, 1] => { note: 48, instrument: 2 }, [3, 1] => { note: 48, instrument: 2 } }
    r = run(write(cells, speed: 3))
    expect(r.logs.map(&:name)).to eq(%i[ch1 ch2 bg1])
    bg = r.logs[2]
    expect(bg.triggers.map { |x| [x.tick, x.sample] }).to eq([[3, 0]])
    expect(bg.triggers[0].offset).to be > 0 # (it carries on from where it was)
    # (NNA fade: it fades by 128 / 1024 a tick from its move)
    expect(bg.volume[3]).to be > bg.volume[5]
    expect(bg.volume[3 + 9]).to eq(0)
    # instrument 2 cuts (NNA 0): no background voice for channel 2
    expect(r.logs[1].triggers.length).to eq(2)
  end

  it 'plays the volume column and channel and global volume effects' do
    cells = {
      [0, 0] => { note: 60, instrument: 2, volume: 32 }, [1, 0] => { volume: 85 + 4 }, [2, 0] => { volume: 75 + 8 },
      [0, 1] => { note: 60, instrument: 2, effect: 'M', param: 16 }, [1, 1] => { effect: 'N', param: 0x20 },
      [0, 2] => { note: 60, instrument: 2, volume: 128 + 64 },
      [0, 3] => { effect: 'V', param: 64 },
    }
    r = run(write(cells, speed: 3))
    a, b, c = r.logs
    expect(a.volume[0..6].map { |v| (v * 64 * 2).round }).to eq([32, 32, 32, 32, 36, 40, 32])
    # (64 x channel volume / 64 x global 32 / 64: N20 raises the channel volume 2 a tick)
    expect(b.volume[0..5].map { |v| (v * 64 * 2).round }).to eq([16, 16, 16, 16, 18, 20])
    expect(c.pan[0]).to eq(1.0)
  end

  it 'imports background voices as tracks' do
    set = MB::Sound.mod_import(write({ [0, 0] => { note: 48, instrument: 1 }, [1, 0] => { note: 50, instrument: 1 } }, speed: 3))
    expect(set.tracks).to eq(%i[ch1 bg1])
    ev = set[:p00][:bg1].events[0]
    expect([ev.start, ev.value]).to eq([3/96r, 1])
    expect(set[:p00][:bg1].control(20).points.last[1]).to be > 0
  end
end
