# Section-aware loudness targets (measure: :loudest) and the first pass's
# clipping warning (omnibus9); kept apart from mastering_spec.rb for its
# time budget.
RSpec.describe(MB::Sound::Mastering, :aggregate_failures) do
  describe 'render loudness targeting' do
    it 'reaches the target with the loudest 8 bars, leaving a quiet part where the mix put it, with measure: :loudest' do
      # 8 quiet bars (keys alone), then 8 loud ones (keys and drums); at 480 BPM a bar is 0.5 s
      song = -> {
        MB::Sound.bpm 480
        MB::Sound.master :club, measure: :loudest
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

    it 'rejects unknown measures' do
      expect { described_class.preset(:club, measure: :peak) }.to raise_error(ArgumentError, /measure: is :integrated or :loudest/)
      expect(described_class.preset(:club).measure).to eq(:integrated)
      expect(described_class.preset(:club, measure: :loudest).call_ruby).to eq(':club, measure: :loudest')
    end

  end
end
