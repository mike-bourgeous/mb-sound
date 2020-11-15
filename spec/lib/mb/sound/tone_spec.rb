RSpec.describe MB::Sound::Tone do
  describe MB::Sound::Tone::Meters do
    it 'can be converted to feet' do
      expect(1.meter.feet).to be_a(MB::Sound::Tone::Feet)
      expect(1.meter.feet).to eq(100 / 2.54 / 12.0)
    end

    it 'pluralizes' do
      # https://en.wikipedia.org/wiki/Plural suggests negative one is singular
      expect(-1.meter.to_s).to end_with('meter')
      expect(-1.meters.to_s).to end_with('meter')
      expect(1.meter.to_s).to end_with('meter')
      expect(1.meters.to_s).to end_with('meter')
      expect(1.1.meter.to_s).to end_with('meters')
      expect(1.1.meters.to_s).to end_with('meters')
    end

    it 'can be used in arithmetic' do
      added = 1.meter + 1
      expect(added).to be_a(MB::Sound::Tone::Meters)
      expect(added).to eq(2.meters)

      subtracted = 3.meters - 1
      expect(subtracted).to be_a(MB::Sound::Tone::Meters)
      expect(subtracted).to eq(2.meters)

      multiplied = 1.5.meters * 2
      expect(multiplied).to be_a(MB::Sound::Tone::Meters)
      expect(multiplied).to eq(3.meters)

      divided = 4.0.meters / 2
      expect(divided).to be_a(MB::Sound::Tone::Meters)
      expect(divided).to eq(2.meters)
    end

    it 'converts feet to meters when adding' do
      with_feet = 1.meter + 1.foot
      expect(with_feet).to be_a(MB::Sound::Tone::Meters)
      expect(with_feet).to eq((0.0254 * 12 + 1).meters)
    end

    it 'can be compared to feet' do
      expect(1.meter.feet).to eq(1.meter)
      expect(1.meter.feet).not_to eq(2.meters)
      expect(2.meters.feet).to be > (1.meters)
      expect(1.meters.feet).to be < (2.meters)
    end
  end

  describe MB::Sound::Tone::Feet do
    it 'can be converted to meters' do
      expect(1.foot.meters).to be_a(MB::Sound::Tone::Meters)
      expect(1.foot.meters).to eq(0.0254 * 12)
    end

    it 'pluralizes' do
      # https://en.wikipedia.org/wiki/Plural suggests negative one is singular
      expect(-1.foot.to_s).to end_with('foot')
      expect(-1.feet.to_s).to end_with('foot')
      expect(1.foot.to_s).to end_with('foot')
      expect(1.feet.to_s).to end_with('foot')
      expect(1.1.foot.to_s).to end_with('feet')
      expect(1.1.feet.to_s).to end_with('feet')
    end

    it 'can be used in arithmetic' do
      added = 1.foot + 1
      expect(added).to be_a(MB::Sound::Tone::Feet)
      expect(added).to eq(2.feet)

      subtracted = 3.feet - 1
      expect(subtracted).to be_a(MB::Sound::Tone::Feet)
      expect(subtracted).to eq(2.feet)

      multiplied = 1.5.feet * 2
      expect(multiplied).to be_a(MB::Sound::Tone::Feet)
      expect(multiplied).to eq(3.feet)

      divided = 4.0.feet / 2
      expect(divided).to be_a(MB::Sound::Tone::Feet)
      expect(divided).to eq(2.feet)
    end

    it 'converts meters to feet when adding' do
      with_meters = 1.foot + 1.meter
      expect(with_meters).to be_a(MB::Sound::Tone::Feet)
      expect(with_meters).to eq((0.0254 * 12 + 1).meters)
    end

    it 'can be compared to meters' do
      expect(1.foot.meters).to eq(1.foot)
      expect(1.foot.meters).not_to eq(2.feet)
      expect(1.inch.meters).to eq(0.0254.meters)
      expect(2.inches.meters).to eq(0.0508.meters)
      expect(2.inches.meters).to be > (0.0254.meters)
      expect(2.inches.meters).to be < (0.06.meters)
    end
  end

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

    describe '#meter' do
      it 'returns a Meters object' do
        expect(1.meter).to be_a(MB::Sound::Tone::Meters)
      end
    end

    describe '#meters' do
      it 'returns a Meters object' do
        expect(1.meters).to be_a(MB::Sound::Tone::Meters)
      end
    end

    describe '#foot' do
      it 'returns a Feet object' do
      end
    end

    describe '#feet' do
      it 'returns a Feet object' do
        expect(1.feet).to be_a(MB::Sound::Tone::Feet)
      end
    end

    describe '#inch' do
      it 'returns a Feet object' do
        expect(1.inch).to be_a(MB::Sound::Tone::Feet)
        expect(1.inch).to eq(1.0 / 12.0)
      end
    end

    describe '#inches' do
      it 'returns a Feet object' do
        expect(2.inches).to be_a(MB::Sound::Tone::Feet)
        expect(2.inches).to eq(2.0 / 12.0)
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

  describe '#initialize' do
    it 'can be constructed from a wavelength' do
      expect(MB::Sound::Tone.new(frequency: 343.meters).wavelength).to eq(343.meters)
      expect(MB::Sound::Tone.new(frequency: 30.feet).wavelength).to eq(30.feet)
    end
  end

  describe '#wavelength' do
    it 'returns the wavelength of a sound at sealevel' do
      expect(1.hz.wavelength).to eq(MB::Sound::Tone::SPEED_OF_SOUND)
      expect(100.hz.wavelength).to eq(MB::Sound::Tone::SPEED_OF_SOUND * 0.01)
    end
  end
end
