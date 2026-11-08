require_relative '../../../../support/bar_stats_sounds'

# Bar-by-bar comparison (BarStats::Comparison): synthetic songs with one
# thing changed, where the comparison must name the measure, the bars,
# and the likely cause, with pass/fail thresholds for specs and scripts.
RSpec.describe(MB::Sound::BarStats::Comparison, :aggregate_failures) do
  let(:options) { { bpm: 120, offset: BarStatsSounds::OFFSET, sections: false } }
  let(:base) { BarStatsSounds.song(bars: 4) }

  def compare(b, a = base, **extra) = MB::Sound::BarStats.compare(a, b, **options, **extra)

  def kinds(c) = c.causes.map(&:kind)

  it 'finds exactly the band and the samples one band is late by, and names a late bus or track' do
    c = compare(BarStatsSounds.song(bars: 4, delay: { high: 37 }), thresholds: { timing: 0.5 })
    (1..4).each do |n|
      bar = c.bars.find { |x| x.bar == n }
      expect(bar.lags[:high][0]).to be_within(0.001).of(37 / 48.0)
      expect(bar.lags[:low][0].abs).to be < 0.002
      expect(bar.lags[:mid][0].abs).to be < 0.002
      expect(bar.moved).to eq([:lag_high])
    end
    expect(c.band_lags[:high][0]).to be_within(0.001).of(37 / 48.0)
    cause = c.causes.find { |x| x.kind == :band_offset }
    expect(cause.measure).to eq(:lag_high)
    expect(cause.text).to include('the high band of B is 0.77 ms late', 'while low and mid stay on time', 'a late (or early) bus or track')
    expect(kinds(c)).to eq([:band_offset])
  end

  it 'tells a file offset (every band alike) from a mix problem, and aligns it away' do
    shifted = BarStatsSounds.song(bars: 4, shift: 480)
    c = compare(shifted)
    expect(kinds(c)).to eq([:file_offset])
    expect(c.causes[0].value).to eq(10.0)
    aligned = compare(shifted, align: 0.01)
    expect(aligned.pass?).to be(true)
    expect(aligned.band_lags.values.map(&:first)).to all(be_within(0.01).of(0))
  end

  it 'names a loudness step, its bars, and its size' do
    c = compare(BarStatsSounds.song(bars: 4, gain: ->(b) { b >= 3 ? 0.5 : 1.0 }))
    level = c.causes.find { |x| x.kind == :level }
    expect(level.bars).to eq([3, 4])
    expect(level.value).to be_within(0.1).of(-6.0)
    expect(c.worst(2).map(&:bar).sort).to eq([3, 4])
    expect(c.worst.first.moved).to include(:lufs, :rms)
    expect(c.failures.map(&:bar).uniq.sort).to eq([3, 4])
    expect { c.check! }.to raise_error(RuntimeError, /lufs in bars 3-4/)
    expect(c.failures(lufs: 7, rms: 7, true_peak: 7).map(&:to_s)).to eq(['bar 3: bands 31.5 Hz -6.0 dB (threshold 6.0)', 'bar 4: bands 31.5 Hz -6.0 dB (threshold 6.0)'])
    expect(c.pass?(lufs: 7, rms: 7, true_peak: 7, bands: 7)).to be(true)
  end

  it 'names a stereo collapse in one section' do
    c = compare(BarStatsSounds.song(bars: 4, mono: [3, 4]))
    stereo = c.causes.find { |x| x.kind == :stereo }
    expect(stereo.bars).to eq([3, 4])
    expect(kinds(c)).not_to include(:level, :band_level)
  end

  it 'names a missing band' do
    c = compare(BarStatsSounds.song(bars: 4, drop: { low: 2..3 }))
    band = c.causes.find { |x| x.kind == :band_level }
    expect(band.bars).to eq([2, 3])
    expect(band.text).to match(/the 31.5 Hz to 125 Hz octaves of B are \d+-\d+ dB down \(missing\) in bars 2-3: .*EQ, or a missing part/)
  end

  it 'names a transpose' do
    c = compare(BarStatsSounds.song(bars: 4, transpose: { 2..2 => 2 }))
    chroma = c.causes.find { |x| x.kind == :chroma }
    expect(chroma.bars).to eq([2])
    expect(chroma.value).to eq(2)
    expect(chroma.text).to include('+2 semitones', 'a transpose')
  end

  it 'names missing tails after hits (reverb or delay) and over-compression' do
    wet = BarStatsSounds.song(bars: 2, drop: { mid: 1..2 }, tail: true)
    dry = BarStatsSounds.song(bars: 2, drop: { mid: 1..2 })
    tail = compare(dry, wet).causes.find { |x| x.kind == :tail }
    expect(tail.bars).to eq([1, 2])
    expect(tail.text).to include('shorter', 'reverb or delay')

    squashed = base.map { |ch| Numo::NMath.tanh(ch * 4) / 2 }
    expect(kinds(compare(squashed))).to include(:over_compression)
  end

  it 'passes a recording against itself' do
    c = compare(base)
    expect(c.pass?).to be(true)
    expect(c.causes).to be_empty
    expect(c.narrative).to include('every bar is within the thresholds')
  end

  it 'writes a narrative from the same data' do
    c = compare(BarStatsSounds.song(bars: 4, delay: { high: 480 }))
    text = c.narrative
    expect(text).to include('B against A, 5 bars compared', 'high +10.0 ms', 'Likely: the high band of B is 10.0 ms late')
    expect(c.to_s).to include('bar 1: lag_high +10.0 ms')
  end

  it 'compares two sections of one recording' do
    grid = MB::Sound::BarStats::Grid.constant(bpm: 120, offset: BarStatsSounds::OFFSET, duration: 9.25)
    sections = [MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 1, bars: 2, seconds: grid.bars[0].seconds, end_seconds: grid.bars[1].end_seconds, beats: 8),
                MB::Sound::Structure::Section.new(label: "A'", name: :a2, first_bar: 3, bars: 2, seconds: grid.bars[2].seconds, end_seconds: grid.bars[3].end_seconds, beats: 8)]
    r = MB::Sound::BarStats.analyze(BarStatsSounds.song(bars: 4, gain: ->(b) { b > 2 ? 0.5 : 1.0 }), grid: grid, sections: sections)
    c = described_class.sections(r, 'A', "A'")
    expect(c.labels).to eq(['A', "A'"])
    expect(c.bars.map(&:bar)).to eq([1, 2])
    expect(c.bars.map(&:b_bar)).to eq([3, 4])
    expect(c.causes.find { |x| x.kind == :level }.value).to be_within(0.1).of(-6.0)
  end
end
