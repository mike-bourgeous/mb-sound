RSpec.describe(MB::Sound::Pitch, :aggregate_failures) do
  describe 'Numeric#hz' do
    it 'returns a constant Pitch' do
      p = 440.hz
      expect(p).to be_a(MB::Sound::Pitch)
      expect(p.frequency).to eq(440)
      expect(p).to be_constant
      expect(p.freq.sample(2).to_a).to eq([440, 440])
    end

    it 'accepts wavelengths' do
      expect(MB::Sound::SPEED_OF_SOUND.meters.hz.frequency).to be_within(1e-9).of(1)
    end
  end

  describe 'oscillator methods' do
    it 'make a new full-scale Tone each time' do
      p = 220.hz
      a = p.ramp
      b = p.triangle.at(0.5)
      expect(a).to be_a(MB::Sound::Tone)
      expect(a).not_to equal(p.ramp)
      expect(a.wave_type).to eq(:ramp)
      expect(b.wave_type).to eq(:triangle)
      expect(p.tone.wave_type).to eq(:sine)
      expect(p.hz.wave_type).to eq(:sine)
      expect(a.frequency).to eq(220)
      expect(p.at(0.25).sample(800).abs.max).to be_within(1e-3).of(0.25)
      expect(p.sine.sample(800).abs.max).to be_within(1e-3).of(1)
    end

    it 'make a Phasor' do
      ph = 4800.hz.phasor
      expect(ph).to be_a(MB::Sound::Phasor)
      expect(ph.sample(3).to_a.map { |v| v.round(6) }).to eq([0, 0.1, 0.2])
    end
  end

  describe 'as a signal' do
    it 'plays as a full-scale sine' do
      data = 1000.hz.sample(48)
      expect(data).to all_be_within(1e-5).of_array(1000.hz.sine.sample(48))
    end

    it 'does arithmetic on the signal' do
      data = (1000.hz * 0.5).sample(48)
      expect(data).to all_be_within(1e-5).of_array(1000.hz.sine.sample(48) * 0.5)
    end
  end

  describe '#transpose' do
    it 'moves the frequency by semitones' do
      expect(440.hz.transpose(12).frequency).to eq(880)
      expect(440.hz.transpose(-12).frequency).to eq(220)
    end
  end

  describe '#to_note' do
    it 'finds the nearest note in the current tuning' do
      expect(440.hz.to_note.name).to eq('A4')
      MB::Sound.tuning a4: 432
      expect(432.hz.to_note.name).to eq('A4')
    end
  end

  describe 'filter helpers' do
    it 'use the current frequency' do
      expect(1000.hz.lowpass.center_frequency).to eq(1000)
      expect(100.hz.highpass(quality: 2).quality).to eq(2)
    end
  end

  describe '#freewheel' do
    it 'works only for tempo-synced pitches' do
      expect { 2.hz.freewheel }.to raise_error(ArgumentError, /tempo-synced/)
      expect(1.beat.hz.freewheel).to be_a(MB::Sound::Pitch)
    end
  end

  describe 'in sequences' do
    it 'keeps a fixed frequency while notes follow the tuning' do
      clip = MB::Sound.seq(MB::Sound::A4, 300.hz).n4.loop
      expect(clip.events.map(&:to_s)).to eq(['69@0+n4', '300.0 Hz@1/4+n4'])

      MB::Sound.tuning a4: 432
      hz = clip.freq
      first = hz.sample(24000)[12000]
      second = hz.sample(24000)[12000]
      expect(first).to be_within(1e-3).of(432)
      expect(second).to be_within(1e-3).of(300)
    end

    it 'transposes fixed frequencies' do
      clip = MB::Sound.seq(300.hz).n4.transpose(12)
      expect(clip.events.map(&:to_s)).to eq(['600.0 Hz@0+n4'])
    end
  end
end
