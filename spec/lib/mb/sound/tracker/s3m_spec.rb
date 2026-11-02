require_relative '../../../../support/module_writer'

# Scream Tracker 3 modules (tracker-1): synthetic files from ModuleWriter.
RSpec.describe(MB::Sound::Tracker::S3MReader, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }
  let(:clock) { MB::Sound::Tracker::Player::S3M::CLOCK }

  def samples
    [{ name: 'saw', data: w.saw(4000), loop: [2000, 4000], c2spd: 8363 }, { name: 'hi', data: w.saw(1000), volume: 40, c2spd: 16726, bits: 16 }]
  end

  def write(cells = {}, patterns: nil, orders: [0], **options)
    path = tmp_path('spec.s3m')
    w.s3m(path, samples: options.delete(:samples) || samples, patterns: patterns || [w.pattern(4, cells)], orders: orders, **options)
  end

  def run(path, mode: :musical)
    t::Player.for(t.read(path), mode: mode).run
  end

  it 'reads the header, channels, samples, and packed cells' do
    cells = { [0, 0] => { note: 60, sample: 1, volume: 32, effect: 'D', param: 0x04 }, [3, 3] => { note: :cut }, [5, 1] => { effect: 'A', param: 3 } }
    song = t.read(write(cells, orders: [0, 0], speed: 4, tempo: 140, title: 'scream', pans: [0, 15, 7, 8]))
    expect(song.format).to eq(:s3m)
    expect([song.title, song.channels, song.speed, song.tempo, song.orders]).to eq(['scream', 4, 4, 140, [0, 0]])
    expect(song.pans).to eq([-1.0, 1.0, 7 / 7.5 - 1, 8 / 7.5 - 1])
    expect(song.samples[0].loop).to eq([2000, 4000])
    expect(song.samples[1].rate).to eq(16726)
    expect(song.samples[1].bits).to eq(16)
    expect(song.samples[1].volume).to eq(40)
    expect(song.samples[1].data[0][10]).to be_within(1e-4).of(w.saw(1000)[10])
    c = song.patterns[0].rows[0][0]
    expect([c.note, c.instrument, c.volume, c.effect, c.param]).to eq([60, 1, 32, 4, 4])
    expect(song.patterns[0].rows[3][3].note).to eq(:cut)
    expect(song.patterns[0].rows[5][1].effect).to eq(1)
    expect(t.read(write(signed: true)).samples[0].data[0][10]).to be_within(1 / 128.0).of(w.saw(4000)[10])
    expect(t.read(write(stereo: false)).pans).to eq([0.0] * 4)
  end

  it 'plays ST3 periods by C2Spd, slides, and shared effect memory' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 'F', param: 2 }, [1, 0] => { effect: 'F', param: 0 }, [2, 0] => { effect: 'F', param: 0xF1 },
      [0, 1] => { note: 60, sample: 2 },
      [0, 2] => { note: 60, sample: 1 }, [1, 2] => { note: 72, effect: 'G', param: 32 },
      [0, 3] => { note: 60, sample: 1, volume: 40, effect: 'D', param: 0x02 }, [1, 3] => { effect: 'D', param: 0x0F + 0x30 },
    }
    r = run(write(cells), mode: :hardware)
    a, b, c, d = r.logs
    expect(a.freq[0..2]).to eq([clock / 1712, clock / 1704, clock / 1696])
    expect(a.freq[6..7]).to eq([clock / (1712 - 40), clock / (1712 - 48)]) # (F00 reuses F02)
    expect(a.freq[12]).to eq(clock / (1712 - 80 - 4)) # (FF1: fine, on the row's first tick)
    expect(b.freq[0]).to eq(clock / 856)
    expect(c.freq[6..8]).to eq([clock / 1712, clock / (1712 - 128), clock / (1712 - 256)])
    expect(c.triggers.length).to eq(1)
    expect(d.volume[0..6].map { |v| (v * 64).round }).to eq([40, 38, 36, 34, 32, 30, 33])
    expect(b.volume[0]).to eq(40 / 64.0)
  end

  it 'plays retriggers with volume changes, tremor, cuts, delays, and tempo' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 'Q', param: 0x22 },
      [0, 1] => { note: 60, sample: 1, effect: 'I', param: 0x10 },
      [0, 2] => { note: 60, sample: 1, effect: 'S', param: 0xC3 },
      [0, 3] => { note: 60, sample: 1, effect: 'S', param: 0xD4 }, [1, 3] => { effect: 'T', param: 150 },
    }
    r = run(write(cells))
    a, b, c, d = r.logs
    expect(a.triggers.map(&:tick)).to eq([0, 2, 4])
    expect(a.volume[0..4].map { |v| (v * 64).round }).to eq([64, 64, 62, 62, 60])
    expect(b.volume[0..5].map { |v| (v * 64).round }).to eq([64, 64, 0, 64, 64, 0])
    expect(c.volume[2..3]).to eq([1.0, 0.0])
    expect(d.triggers.map(&:tick)).to eq([4])
    expect(r.tempos).to eq([[0, 125], [6, 150]])
  end

  it 'imports as a set' do
    set = MB::Sound.mod_import(write({ [0, 0] => { note: 60, sample: 2 }, [4, 1] => { note: 72, sample: 1, effect: 'O', param: 4 } }))
    expect(set.tracks).to eq(%i[ch1 ch2]) # (channels that never play get no track)
    ev = set[:p00][:ch2].events[0]
    expect([ev.start, ev.value, ev.pitch]).to eq([24/96r, 1, 12])
    expect(set[:p00][:ch2].control(20).points).to include([24/96r, 1024 / 4000.0])
  end
end
