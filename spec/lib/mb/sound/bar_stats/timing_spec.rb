require_relative '../../../../support/bar_stats_sounds'

# Timing per band (BarStats::Bands, BarStats::Timing): the band split is
# zero phase and sums to the signal; onsets read 0 ms on the beat for
# kicks and hats; a band delayed by N samples reads N exactly between two
# recordings and against the grid.
RSpec.describe(MB::Sound::BarStats::Timing, :aggregate_failures) do
  let(:rate) { BarStatsSounds::RATE }
  let(:bands) { MB::Sound::BarStats::Bands }

  # A 4-bar grid at 120 BPM over +song+.
  def grid_of(song)
    MB::Sound::BarStats::Grid.constant(bpm: 120, offset: BarStatsSounds::OFFSET, duration: song[0].length / 48000.0)
  end

  def mono(song) = (song[0] + song[1]) / 2

  describe MB::Sound::BarStats::Bands do
    it 'splits into three zero-phase bands that sum to the signal' do
      x = Numo::DFloat.new(rate / 2).rand(-1, 1)
      parts = bands.split(x, rate)
      expect(parts.length).to eq(3)
      expect((parts.sum - x).abs.max).to be < 1e-12

      impulse = Numo::DFloat.zeros(rate / 2)
      impulse[rate / 4] = 1.0
      bands.split(impulse, rate).each { |b| expect(b.abs.max_index).to eq(rate / 4) }
    end

    it 'gives a slice with margins the same samples as the whole' do
      x = Numo::DFloat.new(rate).rand(-1, 1)
      whole = bands.split(x, rate)
      part = bands.split(x, rate, from: 20_000, to: 30_000, margin: 100)
      3.times { |i| expect((part[i] - whole[i][19_900...30_100]).abs.max).to be < 1e-9 }
    end
  end

  it 'reads kicks and hats on the beat within 0.5 ms, and a hat delayed 96 samples 2.0 ms late' do
    song = BarStatsSounds.song(bars: 4, drop: { mid: 1..4 })
    late = BarStatsSounds.song(bars: 4, drop: { mid: 1..4 }, delay: { high: 96 })
    on = described_class.grid_offsets(mono(song), rate, grid_of(song))
    off = described_class.grid_offsets(mono(late), rate, grid_of(late))
    beats = 1..15 # (beat 0 is the silent pickup)
    expect(on[:low][beats].map(&:abs).max).to be < 0.0005
    expect(on[:high][beats].map(&:abs).max).to be < 0.0005
    on[:mid][beats].compact.each { |v| expect(v.abs).to be < 0.001 } # (the others' leakage, at their times)
    beats.each { |i| expect(off[:high][i] - on[:high][i]).to be_within(1e-5).of(0.002) }
    beats.each { |i| expect(off[:low][i]).to be_within(0.0001).of(on[:low][i]) }
  end

  it 'finds exactly the band and the samples a recording is late by, bar by bar' do
    a = mono(BarStatsSounds.song(bars: 4))
    b = mono(BarStatsSounds.song(bars: 4, delay: { high: 37 }))
    spans = grid_of([a, a]).bars.first(4).map { |bar| [bar.seconds, bar.end_seconds] }
    lags = described_class.lags(a, b, rate, spans)
    lags[:high].each { |l| expect(l.samples).to be_within(0.01).of(37); expect(l.wave).to be > 0.9; expect(l.reliable?).to be(true) }
    (lags[:low] + lags[:mid]).each { |l| expect(l.samples.abs).to be < 0.05 }
  end

  it 'finds a lag longer than a 16th between hits (the 66 ms drum bus case)' do
    a = mono(BarStatsSounds.song(bpm: 140, bars: 4))
    b = mono(BarStatsSounds.song(bpm: 140, bars: 4, delay: { low: 3168, high: 3168 })) # 66 ms
    g = MB::Sound::BarStats::Grid.constant(bpm: 140, offset: BarStatsSounds::OFFSET, duration: a.length / 48000.0)
    lags = described_class.lags(a, b, rate, g.bars.first(4).map { |bar| [bar.seconds, bar.end_seconds] })
    expect(lags[:high].map(&:samples)).to all(be_within(0.01).of(3168))
    expect(lags[:low].map(&:samples)).to all(be_within(0.2).of(3168)) # (the chord's leakage into the low band stays put)
    expect(lags[:mid].map { |l| l.samples.abs }).to all(be < 0.05)
  end

  it 'gives no lag for spans of a few samples or bands with nothing in them' do
    a = mono(BarStatsSounds.kick_stem(bars: 2, extra: 8))
    n = a.length
    lags = described_class.lags(a, a, rate, [[0.0, 1.0], [(n - 8) / 48000.0, n / 48000.0]])
    expect(lags[:low][0].samples).to eq(0)
    expect(lags[:low][1]).to be_nil
    expect(lags[:high][0]).to be_nil.or(have_attributes(samples: be_within(0.5).of(0)))
  end

end
