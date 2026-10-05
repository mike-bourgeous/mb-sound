RSpec.describe(MB::Sound::EnvelopeMethods) do
  {
    env: { curve: [12, 60, 60], sustain: 0.7, sensitivity: 0.5..1, velocity_scale: :linear, octaves: nil },
    amp_env: { curve: [12, 60, 40], sustain: 0.7, sensitivity: -18.db..0.db, velocity_scale: :db, octaves: nil },
    fm_env: { curve: [-30, 30, 30], sustain: 0, sensitivity: -18.db..0.db, velocity_scale: :db, octaves: nil },
    filter_env: { curve: [12, 60, 60], sustain: 0, sensitivity: 0.5..1, velocity_scale: :linear, octaves: 2 },
  }.each do |name, defaults|
    describe "##{name}" do
      it 'makes a one-shot Envelope with the preset defaults' do
        env = MB::Sound.public_send(name)
        expect(env).to be_a(MB::Sound::Envelope)
        expect(env.one_shot?).to eq(true)
        expect(env.curve.values).to eq(defaults[:curve])
        expect(env.attack).to eq(0.005)
        expect(env.decay).to eq(0.2)
        expect(env.sustain).to eq(defaults[:sustain])
        expect(env.release).to eq(0.3)
        expect(env.sensitivity.begin).to be_within(1e-12).of(defaults[:sensitivity].begin)
        expect(env.sensitivity.end).to eq(defaults[:sensitivity].end)
        expect(env.velocity_scale).to eq(defaults[:velocity_scale])
        expect(env.octaves).to eq(defaults[:octaves])
        expect(env.sample_rate).to eq(48000)
      end

      it 'takes positional times and options' do
        env = MB::Sound.public_send(name, 0.1, 0.2, 0.3, 0.4, curve: :linear, sample_rate: 44100, hold: 1)
        expect([env.attack, env.decay, env.sustain, env.release, env.hold]).to eq([0.1, 0.2, 0.3, 0.4, 1])
        expect(env.curve.values).to eq([0, 0, 0])
        expect(env.sample_rate).to eq(44100)
      end

      it 'takes times as keywords' do
        env = MB::Sound.public_send(name, decay: 1, sustain: 0.25)
        expect([env.attack, env.decay, env.sustain]).to eq([0.005, 1, 0.25])
        expect { MB::Sound.public_send(name, 1, attack: 2) }.to raise_error(ArgumentError, /attack/)
      end

      it 'plays to the end' do
        env = MB::Sound.public_send(name, 0.001, 0.002, 0.5, 0.003, hold: 0.004)
        total = 0
        while (buf = env.sample(100))
          total += buf.length
          raise 'too long' if total > 48000
        end
        expect(total).to eq(400) # released at 192 samples, ended at 336
      end
    end
  end

  it 'explains the replacements for auto_release: and log:' do
    expect { MB::Sound.adsr(auto_release: 1) }.to raise_error(ArgumentError, /hold:/)
    expect { 1.constant.adsr(log: -30) }.to raise_error(ArgumentError, /curve:/)
  end

  describe '#adsr' do
    it 'makes a generic Envelope with :analog curves and full velocity sensitivity' do
      env = MB::Sound.adsr
      expect(env).to be_a(MB::Sound::Envelope)
      expect(env.curve.values).to eq([12, 60, 60])
      expect(env.sensitivity).to eq(0.0..1.0)
      expect([env.attack, env.decay, env.sustain, env.release]).to eq([0.005, 0.2, 0.7, 0.3])
      expect(MB::Sound.adsr(0, 0, 1, 0, trigger: 1, velocity: 0.25, hold: false).sample(10)[5]).to eq(0.25)
    end
  end

  it 'has aliases' do
    expect(MB::Sound.method(:envelope)).to eq(MB::Sound.method(:env))
    expect(MB::Sound.method(:amp_envelope)).to eq(MB::Sound.method(:amp_env))
    expect(MB::Sound.method(:fm_envelope)).to eq(MB::Sound.method(:fm_env))
    expect(MB::Sound.method(:filt_env)).to eq(MB::Sound.method(:filter_env))
    expect(MB::Sound.method(:filter_envelope)).to eq(MB::Sound.method(:filter_env))
  end

  describe '#filter_env' do
    it 'outputs a cutoff multiplier of 2 ** (env * depth)' do
      env = MB::Sound.filter_env(100.samples, 100.samples, 0.5, 0, hold: false)
      data = env.sample(300)
      expect(data[0]).to eq(1)
      expect(data[100]).to eq(4)
      expect(data[250]).to eq(2)
    end

    it 'takes depth: or octaves:, and scales the depth by velocity' do
      expect(MB::Sound.filter_env(depth: 3).octaves).to eq(3)
      expect(MB::Sound.filter_env(octaves: 1.5).octaves).to eq(1.5)
      expect { MB::Sound.filter_env(depth: 1, octaves: 2) }.to raise_error(ArgumentError, /depth/)

      env = MB::Sound.filter_env(0, 0, 1, 0, trigger: 1, velocity: 0, hold: false)
      expect(env.sample(10)[5]).to eq(2) # 0.5 * 2 octaves
    end
  end

  describe '#amp_env' do
    it 'maps velocity in dB' do
      env = MB::Sound.amp_env(0, 0, 1, 0, trigger: 1, velocity: 0.5, hold: false)
      expect(env.sample(10)[5]).to be_within(1e-6).of(-9.db)
    end
  end

  describe '#env' do
    it 'maps velocity linearly' do
      env = MB::Sound.env(0, 0, 1, 0, trigger: 1, velocity: 0.5, hold: false)
      expect(env.sample(10)[5]).to eq(0.75)
    end
  end
end
