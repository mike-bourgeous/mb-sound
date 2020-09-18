RSpec.describe MB::Sound::Tone do
  describe MB::Sound::Tone::NumericToneMethods do
    describe '#hz' do
      it 'creates a Tone object' do
        tone = 5.hz
        expect(tone).to be_a(MB::Sound::Tone)
        expect(tone.frequency).to eq(5)
        expect(tone.wave_type).to eq(:sine)
        expect(tone.rate).to eq(48000)
      end
    end

    describe '#db' do
      it 'converts positive decibel values to a value greater than one' do
        expect(20.db).to eq(10)
      end

      it 'converts 0dB to 1.0' do
        expect(0.db).to eq(1)
      end

      it 'converts negative decibel values to a value less than one' do
        expect(-20.db).to eq(0.1)
      end
    end

    describe '#to_db' do
      it 'converts positive values' do
        expect(0.1.to_db).to eq(-20)
      end

      it 'converts negative values' do
        expect(-0.1.to_db).to eq(-20)
      end
    end
  end

  describe '#generate' do
    it 'can generate triangle wave samples in an NArray' do
      data = 500.hz.triangle.at(0.85).generate(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.median.round(3)).to eq(0.425)
      expect(data.abs.mean.round(3)).to eq(0.425)
    end

    it 'can generate square wave samples in an NArray' do
      data = 500.hz.square.at(0.85).generate(48000)
      expect(data.length).to eq(48000)
      expect(data.max.round(3)).to eq(0.85)
      expect(data.min.round(3)).to eq(-0.85)
      expect(data.abs.mean.round(3)).to eq(0.85)
      expect(data.abs.median.round(3)).to eq(0.85)
    end

    it 'can write tone samples to a file' do
      name = 'tmp/tonegen.flac'
      FileUtils.mkdir_p('tmp')
      output = MB::Sound::FFMPEGOutput.new(name, channels: 1, rate: 48000)
      100.hz.for(311713.0 / 48000.0).write(output)
      output.close

      info = MB::Sound::FFMPEGInput.parse_info(name)
      expect(info[:streams][0][:duration_ts]).to eq(311713)
    end
  end
end
