require_relative '../../../support/bar_stats_sounds'

# The console's bar statistics commands (BarStatsMethods): bar_stats and
# compare_bars, printing in live mode.
RSpec.describe(MB::Sound::BarStatsMethods, :aggregate_failures) do
  let(:options) { { bpm: 120, offset: BarStatsSounds::OFFSET, sections: false } }

  it 'measures a recording and prints its report live' do
    song = BarStatsSounds.song(bars: 2)
    allow(MB::Sound).to receive(:live?).and_return(true)
    r = nil
    expect { r = MB::Sound.bar_stats(song, **options) }.to output(/Bar statistics of audio data.*Integrated/m).to_stdout
    expect(r).to be_a(MB::Sound::BarStats::Report)
    expect(r.bars.length).to eq(3)
  end

  it 'compares two recordings, or two sections of one' do
    a = BarStatsSounds.song(bars: 2)
    b = BarStatsSounds.song(bars: 2, gain: ->(_) { 0.5 })
    c = MB::Sound.compare_bars(a, b, **options)
    expect(c.causes.map(&:kind)).to eq([:level])
    expect { MB::Sound.compare_bars(a) }.to raise_error(ArgumentError, /two recordings/)

    r = MB::Sound.bar_stats(a, **options)
    grid = r.grid
    sections = [MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 1, bars: 1, seconds: grid.bars[0].seconds, end_seconds: grid.bars[0].end_seconds, beats: 4),
                MB::Sound::Structure::Section.new(label: 'B', name: :b, first_bar: 2, bars: 1, seconds: grid.bars[1].seconds, end_seconds: grid.bars[1].end_seconds, beats: 4)]
    r = MB::Sound.bar_stats(a, grid: grid, sections: sections)
    s = MB::Sound.compare_bars(r, sections: %w[A B])
    expect(s.labels).to eq(%w[A B])
    expect(s.pass?).to be(true)
  end
end
