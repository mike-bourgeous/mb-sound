require_relative '../../../../support/bar_stats_sounds'

# Measures per beat, bar, section, and song (BarStats::Measures through
# BarStats.analyze) on synthetic songs with known answers: loudness from
# the BS.1770 analyzer, bars built from their beats' sums, a gain step, a
# stereo collapse, a missing band, a transpose.
RSpec.describe(MB::Sound::BarStats::Measures, :aggregate_failures) do
  let(:options) { { bpm: 120, offset: BarStatsSounds::OFFSET, sections: false } }

  def analyze(song, **extra) = MB::Sound::BarStats.analyze(song, **options, **extra)

  it 'measures a steady sine the same per beat, per bar, and over the song' do
    t = Numo::DFloat.new(48000 * 5).seq / 48000
    x = Numo::NMath.sin(t * 2 * Math::PI * 1000) * 0.5
    r = MB::Sound::BarStats.analyze([x, x], bpm: 120, offset: 0.5, sections: false)
    whole = MB::Sound.loudness([x, x])
    inner = r.beats.select { |b| b[:seconds] >= 1.0 && b[:seconds] + b[:length] <= 4.5 }
    expect(inner.length).to eq(7)
    inner.each do |b|
      expect(b[:lufs]).to be_within(0.02).of(whole.integrated)
      expect(b[:rms]).to be_within(0.01).of(20 * Math.log10(0.5 / Math.sqrt(2)))
      expect(b[:peak]).to be_within(0.01).of(20 * Math.log10(0.5))
      expect(b[:crest]).to be_within(0.02).of(3.01)
      expect(b[:true_peak]).to be_within(0.05).of(b[:peak])
      expect(b[:centroid]).to be_within(20).of(1000)
      expect(b[:correlation]).to be_within(1e-9).of(1)
      expect(b[:width]).to eq(-Float::INFINITY)
      expect(b[:bands].each_with_index.max[1]).to eq(MB::Sound::Analysis::Spectrum::OCTAVE_CENTERS.index(1000.0))
    end
    expect(r.bar(2)[:integrated]).to be_within(0.02).of(whole.integrated)
    expect(r.song.row(0)[:momentary_max]).to be_within(0.01).of(whole.momentary_max)
    expect(r.song.row(0)[:true_peak]).to be_within(0.01).of(whole.true_peak)
    expect(r.broadcast.integrated).to be_within(0.01).of(whole.integrated)
  end

  it 'builds bars from their beats: energies add, peaks take the largest' do
    r = analyze(BarStatsSounds.song(bars: 4, gain: ->(b) { b.odd? ? 1.0 : 0.5 }))
    bar = r.bar(2)
    beats = r.beats.select { |b| b[:bar] == 2 }
    expect(beats.length).to eq(4)
    energy = beats.sum { |b| 10**(b[:rms] / 10) * b[:length] } / beats.sum { |b| b[:length] }
    expect(bar[:rms]).to be_within(0.02).of(10 * Math.log10(energy))
    expect(bar[:peak]).to eq(beats.map { |b| b[:peak] }.max)
    expect(bar[:true_peak]).to eq(beats.map { |b| b[:true_peak] }.max)
    expect(r.bar(1)[:lufs] - r.bar(2)[:lufs]).to be_within(0.05).of(6.02)
    expect(r.bar(1)[:crest]).to be_within(0.05).of(r.bar(2)[:crest])
    expect(bar[:key]).to eq(:C)
  end

  it 'sees a stereo collapse, a missing band, and a transpose in their bars' do
    r = analyze(BarStatsSounds.song(bars: 4, mono: [3], drop: { low: 2..2 }, transpose: { 4..4 => 2 }))
    expect(r.bar(1)[:width]).to be > -10
    expect(r.bar(3)[:side_mid]).to be < -40
    expect(r.bar(3)[:correlation]).to be > 0.99
    expect(r.bar(1)[:correlation]).to be < 0.7
    low = MB::Sound::Analysis::Spectrum::OCTAVE_CENTERS.index(63.0)
    expect(r.bar(1)[:bands][low] - r.bar(2)[:bands][low]).to be > 30
    expect(r.bar(1)[:key]).to eq(:C)
    expect(r.bar(4)[:key]).to eq(:D)
    expect(r.bar(4)[:chroma].each_with_index.max[1]).to eq(r.bar(1)[:chroma].each_with_index.max[1] + 2)
  end

  it 'reads tails after hits from each beat\'s second half' do
    dry = analyze(BarStatsSounds.song(bars: 2, drop: { mid: 1..2 }))
    wet = analyze(BarStatsSounds.song(bars: 2, drop: { mid: 1..2 }, tail: true))
    expect(dry.bar(1)[:tail]).to be < -60
    expect(wet.bar(1)[:tail]).to be > -40
  end

  it 'measures sections and stems on the same grid' do
    grid = MB::Sound::BarStats::Grid.constant(bpm: 120, offset: BarStatsSounds::OFFSET, duration: 9.25)
    sections = [MB::Sound::Structure::Section.new(label: 'A', name: :a, first_bar: 1, bars: 2, seconds: grid.bars[0].seconds, end_seconds: grid.bars[1].end_seconds, beats: 8),
                MB::Sound::Structure::Section.new(label: 'B', name: :b, first_bar: 3, bars: 2, seconds: grid.bars[2].seconds, end_seconds: grid.bars[3].end_seconds, beats: 8)]
    kick = BarStatsSounds.song(bars: 4, drop: { mid: 1..4, high: 1..4 })
    r = MB::Sound::BarStats.analyze(BarStatsSounds.song(bars: 4, gain: ->(b) { b > 2 ? 0.5 : 1.0 }), grid: grid, sections: sections, stems: { kick: kick })
    expect(r.sections.keys).to eq(%w[A B])
    expect(r.section('A')[:lufs] - r.section('B')[:lufs]).to be_within(0.05).of(6.02)
    expect(r.stems.keys).to eq([:kick])
    expect(r.stems[:kick].grid.bars).to eq(grid.bars)
    expect(r.stems[:kick].section('A')[:lufs]).to be < r.section('A')[:lufs]
  end
end
