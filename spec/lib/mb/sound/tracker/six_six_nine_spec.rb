require_relative '../../../../support/module_writer'

# Composer 669 modules (tracker-1): synthetic files from ModuleWriter.
RSpec.describe(MB::Sound::Tracker::SixSixNineReader, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:t) { MB::Sound::Tracker }
  let(:off) { described_class::NOTE_OFFSET }
  let(:p669) { MB::Sound::Tracker::Player::SixSixNine }

  def write(cells = {}, patterns: nil, orders: [0], tempos: nil, breaks: nil, **options)
    path = tmp_path('spec.669')
    w.six_six_nine(path, samples: [{ name: 'saw', data: w.saw(4000), loop: [2000, 4000] }, { name: 'click', data: w.click(300) }],
                         patterns: patterns || [w.pattern(8, cells)], orders: orders, tempos: tempos, breaks: breaks, **options)
  end

  def run(path, mode: :musical)
    t::Player.for(t.read(path), mode: mode).run
  end

  it 'reads the message, samples, orders, speeds, breaks, and cells' do
    song = t.read(write({ [0, 0] => { note: 60, sample: 2, volume: 8, effect: 0, param: 3 }, [1, 7] => { volume: 4 } }, orders: [0, 0], tempos: [6, 3],
                        breaks: [63, 31], loop: 1, message: 'hi there'))
    expect(song.format).to eq(:"669")
    expect(song.title).to eq('hi there')
    expect(song.channels).to eq(8)
    expect(song.orders).to eq([0, 0])
    expect(song.flags[:tempos]).to eq([6, 3])
    expect(song.flags[:breaks]).to eq([63, 31])
    expect(song.restart).to eq(1)
    expect(song.samples[0].loop).to eq([2000, 4000])
    expect(song.samples[1].loop).to be_nil
    expect(song.samples[0].data[0][10]).to be_within(1 / 128.0).of(w.saw(4000)[10])
    c = song.patterns[0].rows[0][0]
    expect([c.note, c.instrument, c.volume, c.effect, c.param]).to eq([60, 2, 8, 0, 3])
    v = song.patterns[0].rows[1][7]
    expect([v.note, v.volume, v.effect]).to eq([nil, 4, nil])
    expect(song.patterns[0].rows[2][0]).to be_nil
    expect(t.read(write(unis: true)).tracker).to eq('UNIS 669')
  end

  it 'plays each order at its speed up to its break row, at 78 BPM' do
    r = run(write({ [0, 0] => { note: 60, sample: 1 } }, orders: [0, 0], tempos: [6, 3], breaks: [63, 15], loop: 255))
    expect(r.visits.map { |v| [v.rows.length, v.ticks] }).to eq([[64, 384], [16, 48]])
    expect(r.tempos).to eq([[0, 78]])
    expect(r.restart).to be_nil
  end

  it 'carries effects on until a new note or effect, in Hz per tick (the measured constants)' do
    cells = {
      [0, 0] => { note: 60, sample: 1, effect: 0, param: 2 }, [2, 0] => { note: 60, sample: 1 },
      [0, 1] => { note: 60, sample: 1, effect: 4, param: 3 },
      [0, 2] => { note: 60, sample: 1 }, [1, 2] => { note: 72, sample: 1, effect: 2, param: 5 },
      [0, 3] => { note: 60, sample: 1, effect: 3, param: 1 }, [1, 3] => { effect: 5, param: 2 },
      [0, 4] => { note: 60, sample: 1, volume: 6 }, [1, 4] => { volume: 15 },
    }
    r = run(write(cells))
    base = 8363.0
    a, b, c, d, e = r.logs
    expect(a.freq[0..2]).to eq([base + 160, base + 320, base + 480])
    expect(a.freq[4]).to eq(base + 800) # (row 1 is empty: the slide carries on)
    expect(a.freq[8]).to eq(base)
    expect(b.freq[0..3]).to eq([base, base + 3 * 668, base, base + 3 * 668])
    expect(c.triggers.length).to eq(1)
    expect(c.freq[4..5]).to eq([base + 200, base + 400])
    expect(d.freq[0]).to eq(base + 80)
    expect(r.visits[0].rows[1][2]).to eq(2) # (f2 on row 1: two ticks)
    expect(e.volume[0]).to be_within(1e-12).of((6 * 64 / 15.0).round / 64.0)
    expect(e.volume[4]).to eq(1.0)
  end

  it 'imports as a set with the 669 tempo' do
    set = MB::Sound.mod_import(write({ [0, 0] => { note: 60, sample: 2 }, [4, 1] => { note: 72, sample: 2 } }, breaks: [7]))
    expect(set.bpm).to eq(78)
    expect(set.plays).to eq([[:p00, 8 * 4/96r]])
    expect(set[:p00][:ch2].events.map { |ev| [ev.start, ev.value, ev.pitch] }).to eq([[16/96r, 2, 12]])
  end
end
