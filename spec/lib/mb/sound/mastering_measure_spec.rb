# Section-aware loudness targets (measure: :loudest) and the first pass's
# clipping warning (omnibus9); kept apart from mastering_spec.rb for its
# time budget.
RSpec.describe(MB::Sound::Mastering, :aggregate_failures) do
  describe 'render loudness targeting' do
    it 'reaches the target with the loudest 8 bars, leaving a quiet part where the mix put it, with measure: :loudest' do
      # 8 quiet bars (keys alone), then 8 loud ones (keys and drums); at 480 BPM a bar is 0.5 s
      song = -> {
        MB::Sound.bpm 480
        MB::Sound.master :club, loudest_bars: 8
        c = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3).n8.loop
        MB::Sound.bg :keys, c.synth(voices: 4) { |v| v.hz.saw.rnd * v.env }.at(0.1)
        MB::Sound.at_bar(9) { MB::Sound.bg :drums, MB::Sound.tr808(MB::Sound.grid(16, kick: 'x.x.x.x.x.x.x.x.', snare: '....x.......x...').loop) }
      }
      a = tmp_path('loudest.flac')
      MB::Sound.seed(5)
      expect { MB::Sound.render(a, bars: 16, overwrite: true, &song) }.to output(/mastering :club: pass.*\n.*loudest 8 bars -8\.5\d LUFS, target -8\.5/).to_stdout
      result = described_class::Targeting.last
      expect(result).to have_attributes(measure: :loudest)
      expect(result.loudest).to be_within(0.01).of(-8.5)
      expect(result.integrated).to be < -9 # the quiet half pulls the song down

      data = MB::Sound.read(a)
      part = ->(from, to) {
        an = MB::Sound::Loudness::Analyzer.new(channels: data.length, true_peak: false)
        an.process(data.map { |ch| ch[(from * 48000)...(to * 48000)] })
        an.integrated
      }
      expect(part.(4.5, 8)).to be_within(0.5).of(-8.5)
      expect(part.(0.5, 3.5)).to be < part.(4.5, 8) - 3
    ensure
      MB::Sound.bpm 120
    end

    it "warns about clipping only for the file it writes, not a targeted render's first pass" do
      a = tmp_path('hot.flac')
      expect {
        expect {
          MB::Sound.render(a, bars: 1, overwrite: true) {
            MB::Sound.master :vinyl
            MB::Sound.bg 220.hz.sine.at(2).until(1.bar)
          }
        }.to output(/mastering :vinyl/).to_stdout
      }.not_to output(/over full scale/).to_stderr
      expect(MB::Sound.loudness(a).true_peak).to be <= -0.9
    end

    it 'starts loudest windows on bar lines through the meter map, falling back to 1 s hops without a transport' do
      t = MB::Sound::Sequence::Transport.new(bpm: 120) # a 4/4 bar is 2 s
      t.meter(3/4r, at: 3) # bars 4.. (whole note 3): 3/4 (1.5 s)
      w = described_class::Targeting.loudest_windows(t, 0, 48000 * 12, 48000, 2)
      expect(w[:ranges]).to eq([[0.0, 4.0], [2.0, 6.0], [4.0, 7.5], [6.0, 9.0], [7.5, 10.5], [9.0, 12.0]])
      # A window starting late (frame origin mid-bar) begins at the next bar line
      w = described_class::Targeting.loudest_windows(t, 24000, 48000 * 6, 48000, 2)
      expect(w[:ranges].first).to eq([1.5, 5.5])
      # Shorter than the window: no ranges (the whole integrated loudness)
      expect(described_class::Targeting.loudest_windows(t, 0, 48000 * 3, 48000, 2)[:ranges]).to eq([])
      expect(described_class::Targeting.loudest_windows(nil, 0, 48000, 48000, 16)).to eq(seconds: 32.0, hop: 1.0)

      an = MB::Sound::Loudness::Analyzer.new(channels: 1, true_peak: false)
      an.process([Numo::SFloat.new(48000 * 2).rand(-0.01, 0.01).concatenate(Numo::SFloat.new(48000 * 2).rand(-0.5, 0.5))])
      expect(an.loudest_in([])).to eq(an.integrated)
      expect(an.loudest_in([[2.0, 4.0]])).to be > an.loudest_in([[0.0, 2.0]]) + 20
    end

    it 'measures the loudest 16 bars for :club by default, and rejects unknown measures and windows' do
      expect { described_class.preset(:club, measure: :peak) }.to raise_error(ArgumentError, /measure: is :integrated or :loudest or :bars/)
      expect { described_class.preset(:club, loudest_bars: 0) }.to raise_error(ArgumentError, /loudest_bars: is a number of bars/)
      expect(described_class.preset(:club)).to have_attributes(measure: :loudest, loudest_bars: 16)
      expect(described_class.preset(:streaming).measure).to eq(:integrated)
      expect(described_class.preset(:club, measure: :integrated).call_ruby).to eq(':club, measure: :integrated')
    end

    it 'measures a percentile of the bars for :hot by default, rejecting percentiles outside 0..1' do
      expect(described_class.preset(:hot)).to have_attributes(measure: :bars, percentile: 0.25, measure_text: 'bars at the 25th percentile')
      expect(described_class.preset(:club, measure: :bars, percentile: 0.5).measure_text).to eq('bars at the 50th percentile')
      expect(described_class.preset(:club).measure_text).to eq('loudest 16 bars')
      expect(described_class.preset(:quiet).measure_text).to be_nil
      expect(described_class.preset(:hot).summary).to start_with('hot: -8.5 LUFS (bars at the 25th percentile), -0.5 dBTP')
      expect { described_class.preset(:hot, percentile: 1.5) }.to raise_error(ArgumentError, /percentile: is a share of bars from 0 to 1/)
      expect(described_class.ordinal(1)).to eq('1st')
      expect(described_class.ordinal(12)).to eq('12th')
      expect(described_class.ordinal(23)).to eq('23rd')
    end

    it 'reads the level a share of the bars sit at or under, leaving out bars more than BARS_RANGE LU down' do
      # Bars of 1 s: silence, then noise at -40, -20, -14, -10 dBFS RMS (plus K-weighting)
      levels = [0, 0.01, 0.1, 0.2, 0.3162]
      an = MB::Sound::Loudness::Analyzer.new(channels: 1, true_peak: false)
      noise = Numo::SFloat.new(48000).rand(-1, 1) * Math.sqrt(3)
      an.process([Numo::SFloat.hstack(levels.map { |l| noise * l })])
      ranges = (0...5).map { |b| [b.to_f, b + 1.0] }
      bars = an.loudness_in(ranges)
      expect(bars[0]).to eq(-Float::INFINITY).or be_nil
      expect(bars[4] - bars[2]).to be_within(0.2).of(10)

      at = ->(p) { described_class::Targeting.loudest_of(an, { ranges: ranges, percentile: p }) }
      # (the -40 bar is 30 LU under the loudest: out, like the silent one)
      expect(at.(0)).to eq(bars[2])
      expect(at.(0.5)).to eq(bars[3])
      expect(at.(1)).to eq(bars[4])
      expect(described_class::Targeting.bar_windows(nil, 0, 48000 * 5, 48000, 0.25)).to eq(ranges: [[0.0, 2.0], [2.0, 4.0]], percentile: 0.25)
    end

    it "makes :hot at Kez's drive the same chain as bin/synths/dnb.rb's dnb_master, sample for sample" do
      require File.expand_path('../../../../bin/synths/dnb.rb', __dir__)
      MB::Sound.seed(3)
      kez = MB::Sound.dnb_master(MB::Sound.stereo(MB::Sound.noise.at(0.3), MB::Sound.noise.at(0.3)), drive: 11.0).outputs
      MB::Sound.seed(3)
      mix = MB::Sound.stereo(MB::Sound.noise.at(0.3), MB::Sound.noise.at(0.3)).filter(:highpass, cutoff: 20, quality: 0.7)
      hot = described_class.preset(:hot, drive: 11.db).apply(mix).outputs
      6.times do
        a = kez.map { |o| o.sample(800).dup }
        b = hot.map { |o| o.sample(800).dup }
        expect(a).to eq(b)
      end
    end

    it 'reaches the target with the quieter bars on :hot, closing the gap to the loud part, with measure: :bars' do
      song = -> {
        MB::Sound.bpm 480
        MB::Sound.master :hot, lufs: -12
        c = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3).n8.loop
        MB::Sound.bg :keys, c.synth(voices: 4) { |v| v.hz.saw.rnd * v.env }.at(0.1)
        MB::Sound.at_bar(9) { MB::Sound.bg :drums, MB::Sound.tr808(MB::Sound.grid(16, kick: 'x.x.x.x.x.x.x.x.', snare: '....x.......x...').loop) }
      }
      a = tmp_path('bars.flac')
      MB::Sound.seed(5)
      expect { MB::Sound.render(a, bars: 16, overwrite: true, &song) }.to output(/mastering :hot: pass.*\n.*bars at the 25th percentile -12\.\d\d LUFS, target -12\.0/).to_stdout
      result = described_class::Targeting.last
      expect(result).to have_attributes(measure: :bars, percentile: 0.25)
      expect(result.loudest).to be_within(0.1).of(-12)

      data = MB::Sound.read(a)
      part = ->(from, to) {
        an = MB::Sound::Loudness::Analyzer.new(channels: data.length, true_peak: false)
        an.process(data.map { |ch| ch[(from * 48000)...(to * 48000)] })
        an.integrated
      }
      expect(part.(0.5, 3.5)).to be_within(0.6).of(-12) # the quiet half reaches the target
      expect(part.(4.5, 8)).to be > part.(0.5, 3.5)
    ensure
      MB::Sound.bpm 120
    end

  end
end
