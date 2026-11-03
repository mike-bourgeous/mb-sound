require_relative '../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::AnalysisMethods) do
  pending '#crosscorrelate'
  pending '#peak_correlation'

  describe '#freq_estimate' do
    it 'works with complex values' do
      data = 150.hz.complex_saw.sample(48000)
      expect(MB::Sound.freq_estimate(data).round(6)).to eq(150)
    end

    it 'returns nil if no correlation peak is in range' do
      data = 300.hz.saw.sample(48000)
      expect(MB::Sound.freq_estimate(data, range: 10000..12000)).to eq(nil)
    end
  end

  describe 'sound-matching commands (analyze, compare, look)' do
    it 'analyze returns the report, printing it only in live mode' do
      r = nil
      expect { r = MB::Sound.analyze(SyntheticSounds.tone(220, 0.5)) }.not_to output.to_stdout
      expect(r).to be_a(MB::Sound::Analysis::Report)
      allow(MB::Sound).to receive(:live?).and_return(true)
      expect { MB::Sound.analyze(SyntheticSounds.tone(220, 0.5)) }.to output(/pitch:\n  pitch A3/).to_stdout
    end

    it 'compare compares one candidate or ranks several' do
      t = SyntheticSounds.tone(220, 0.5)
      expect(MB::Sound.compare(t, SyntheticSounds.tone(220, 0.5, harmonics: 3))).to be_a(MB::Sound::Analysis::Comparison)
      r = MB::Sound.compare(t, 'a' => SyntheticSounds.tone(330, 0.5), 'b' => t)
      expect(r.labels).to eq(%w[b a])
      expect(MB::Sound.compare(t, [t, SyntheticSounds.tone(330, 0.5)]).labels).to eq(%w[1 2])
      expect { MB::Sound.compare(t) }.to raise_error(ArgumentError, /Pass a candidate/)
    end

    it 'look writes an image and returns its path' do
      path = tmp_path('look.png')
      t = SyntheticSounds.tone(220, 0.3)
      expect(MB::Sound.look(t, SyntheticSounds.tone(330, 0.3), path: path)).to eq(path)
      expect(File.size(path)).to be > 1000
      labeled = tmp_path('labeled.png')
      MB::Sound.look('orig' => t, 'fit' => t, path: labeled)
      expect(File.exist?(labeled)).to eq(true)
      expect { MB::Sound.look(path: labeled) }.to raise_error(ArgumentError, /Pass one or more sounds/)
    end
  end
end
