require_relative '../../../../support/bar_stats_sounds'

# The sidecar beside a render (BarStats::Sidecar): readable Ruby that reads
# back to the same tables without running anything, a staleness rule by
# the file's digest and the request, and the broadcast loudness report
# (BarStats::Broadcast) checked against ffmpeg's ebur128 filter.
RSpec.describe(MB::Sound::BarStats::Sidecar, :aggregate_failures) do
  let(:options) { { bpm: 120, offset: BarStatsSounds::OFFSET } }

  # A 4-bar song written to a FLAC file; returns its path.
  def song_file(name = 'song.flac', **song)
    path = tmp_path(name)
    MB::Sound.write(path, BarStatsSounds.song(bars: 4, **song))
    path
  end

  it 'saves a sidecar of readable Ruby beside the file and reads it back to the same Report' do
    path = song_file
    r = MB::Sound::BarStats.analyze(path, **options, save: true)
    side = "#{path}.bar_stats.rb"
    expect(File.file?(side)).to be(true)
    text = File.read(side)
    expect(text.lines.first).to start_with('# mb-sound bar statistics of song.flac')
    expect(text).to include('bar_stats 1, file: "song.flac", digest: "sha256:', 'grid :given, tempo: 120', 'table :beats, [:bar, :beat, :seconds')
    expect(text).to match(/^loudness integrated: -?\d/)

    back = MB::Sound::BarStats.load(path)
    expect(back.to_ruby(base: File.dirname(side))).to eq(text)
    %i[beats bars sections song].each do |level|
      expect(back.send(level).keys).to eq(r.send(level).keys)
      r.send(level).each_with_index { |row, i| expect(back.send(level).row(i)).to eq(row) }
    end
    expect(back.grid.bars).to eq(r.grid.bars.map { |b| b.with(seconds: b.seconds.round(6), end_seconds: b.end_seconds.round(6)) })
    expect(back.broadcast.to_h).to eq(r.broadcast.to_h)
    expect(back.file).to eq(File.expand_path(path))
  end

  it 'reads a fresh sidecar from the cache and measures again when the file or the request changed' do
    path = song_file
    MB::Sound::BarStats.analyze(path, **options, save: true)
    side = "#{path}.bar_stats.rb"
    expect(described_class.fresh?(side, path, MB::Sound::BarStats.request_settings(grid: nil, bpm: 120, offset: BarStatsSounds::OFFSET, beats_per_bar: 4, sections: :auto, window: 0.25))).to be(true)
    expect(MB::Sound::BarStats).not_to receive(:resolve_grid)
    MB::Sound::BarStats.analyze(path, **options, cache: true)
    RSpec::Mocks.space.proxy_for(MB::Sound::BarStats).reset

    expect(described_class.fresh?(side, path, { bpm: 121.0 })).to be(false)
    MB::Sound.write(path, BarStatsSounds.song(bars: 4, gain: ->(_) { 0.5 }), overwrite: true)
    expect(described_class.fresh?(side, path)).to be(false)
    r = MB::Sound::BarStats.analyze(path, **options, cache: true)
    expect(r.bar(1)[:lufs]).to be < -20
  end

  it 'refuses sidecars that hold code' do
    path = tmp_path('bad.flac.bar_stats.rb')
    File.write(path, "bar_stats 1, file: \"bad.flac\"\nsystem(\"echo hi\")\n")
    expect { described_class.read(path) }.to raise_error(ArgumentError, /not a sidecar line|unknown sidecar call/)
    File.write(path, "bar_stats 1, file: `echo hi`\n")
    expect { described_class.read(path) }.to raise_error(ArgumentError, /not a plain value/)
    File.write(path, "bar_stats 99, file: \"bad.flac\"\ngrid :given\n")
    expect { described_class.read(path) }.to raise_error(ArgumentError, /format 99/)
  end

  describe MB::Sound::BarStats::Broadcast do
    it 'checks delivery targets, and extends to others' do
      b = described_class.new(integrated: -23.2, threshold: -33.2, range: 6.0, range_low: -28.0, range_high: -22.0, true_peak: -0.5,
                              sample_peak: -0.6, momentary_max: -15.0, short_term_max: -18.0, plr: 22.7, seconds: 60.0,
                              targets: [:ebu_r128, :atsc_a85, :spotify, -16])
      r128, a85, spotify, custom = b.checks
      expect(r128.pass).to be(false)
      expect(r128.reasons).to eq(['true peak -0.5 dBTP over -1.0'])
      expect(a85.pass).to be(false)
      expect(spotify.reasons.first).to start_with('9.2 LU under -14.0 LUFS')
      expect(custom.target.lufs).to eq(-16.0)
      expect(b.to_s).to include('Integrated     -23.2 LUFS', 'Range (LRA)      6.0 LU', 'PLR             22.7 LU', 'EBU R 128: fail')
    end

    it 'agrees with ffmpeg ebur128 within 0.1 LU, 0.2 LU of range, and 0.3 dB of true peak' do
      skip 'ffmpeg is not installed' unless system('ffmpeg -version > /dev/null 2>&1')
      # 12 s of noise bursts at three levels, so the range is not 0, under
      # 10 kHz (white noise's top octave is the true-peak filters' worst
      # case, where Annex 2's 12 taps and ffmpeg's interpolator differ by
      # 0.6 dB; music sits well under it)
      rng = Random.new(5)
      x = MB::Sound::Analysis::DSP.brickwall(Numo::DFloat.cast(Array.new(48000 * 12) { rng.rand * 2 - 1 }), 48000, 10_000)
      gain = Numo::DFloat.new(x.length).seq.map { |i| [0.05, 0.3, 0.12][(i / 48000) % 3] }
      path = tmp_path('bursts.flac')
      MB::Sound.write(path, [x * gain, x.reverse * gain])
      b = described_class.of(path)
      out, err, = MB::Sound::Starter.capture('ffmpeg', '-nostats', '-hide_banner', '-i', path, '-af', 'ebur128=peak=true', '-f', 'null', '-')
      text = err.to_s + out.to_s
      summary = text[/Summary:.*/m]
      expect(summary).not_to be_nil
      expect(b.integrated).to be_within(0.1).of(summary[/I:\s+(-?[\d.]+) LUFS/, 1].to_f)
      expect(b.range).to be_within(0.2).of(summary[/LRA:\s+(-?[\d.]+) LU/, 1].to_f)
      expect(b.true_peak).to be_within(0.3).of(summary[/Peak:\s+(-?[\d.]+) dBFS/, 1].to_f)
    end
  end
end
