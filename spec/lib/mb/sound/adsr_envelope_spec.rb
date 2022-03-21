RSpec.describe(MB::Sound::ADSREnvelope) do
  let(:env) {
    MB::Sound::ADSREnvelope.new(
      attack_time: 0.1,
      decay_time: 0.2,
      sustain_level: 0.75,
      release_time: 0.5,
      rate: 48000
    )
  }

  it 'produces the expected attack/decay curve and sustain level' do
    env.trigger(2)
    result = env.sample(48000)
    expect(result[0].round(6)).to eq(0)
    expect(result[4800].round(1)).to eq(2)
    expect(result[9600..9700].mean.round(2)).to eq(1.75)
    expect(result[14400].round(2)).to eq(1.5)
    expect(result[-1].round(6)).to eq(1.5)
  end

  it 'produces the expected release curve' do
    env.trigger(1)
    env.sample(48000)
    env.release
    result = env.sample(48000)
    expect(result[0].round(6)).to eq(0.75)
    expect(result[11900..12100].mean.round(2)).to eq(0.38)
    expect(result[24000].round(2)).to eq(0)
    expect(result[-1].round(6)).to eq(0)
  end

  it 'can be released early' do
    env.trigger(1)
    env.sample(4800)
    expect(env.sample.round(1)).to eq(1)
    env.release
    result = env.sample(30000)
    expect(result[0].round(1)).to eq(1)
    expect(result[11500..12500].mean.round(2)).to eq(0.5)
    expect(result[24000].round(2)).to eq(0)
    expect(result[-1].round(6)).to eq(0)
  end

  it 'reuses the same buffer' do
    env.trigger(1)
    r1 = env.sample(48)
    r1_data = r1.dup
    r2 = env.sample(48)
    expect(r1.__id__).to eq(r2.__id__)

    expect(r2).not_to eq(r1_data)
  end

  [:sample, :sample_c, :sample_ruby_c].each do |m|
    describe "##{m}" do
      [false, true].each do |filt|
        context "with filter #{filt}" do
          it 'returns the same curve as the original Ruby for a full cycle' do
            env.reset
            env.trigger(0.75)
            a = env.send(m, 24000, filter: filt)
            env.release
            b = env.send(m, 36000, filter: filt)
            c = a.concatenate(b)

            env.reset
            env.trigger(0.75)
            a = env.sample_ruby(24000, filter: filt)
            env.release
            b = env.sample_ruby(36000, filter: filt)
            ruby = a.concatenate(b)

            # 32-bit float resolution of 0.5 ** 24 is 5.960464477539063e-08
            # For some reason rounding to 6 or 8 decimals and then comparing
            # fails, but rounding the delta works
            delta = (c - ruby).abs
            expect(MB::M.round(delta, filt ? 6 : 7).max).to eq(0)
          end

          it 'returns the same curve as the original Ruby for an interrupted cycle' do
            env2 = env.dup

            env.reset
            env.trigger(0.75)
            c_rise = env.send(m, 5000, filter: filt)
            env.release

            env2.reset
            env2.trigger(0.75)
            ruby_rise = env2.sample_ruby(5000, filter: filt)
            env2.release

            c_fall = env.send(m, 36000, filter: filt)
            ruby_fall = env2.sample_ruby(36000, filter: filt)

            c = c_rise.concatenate(c_fall)
            ruby = ruby_rise.concatenate(ruby_fall)

            # 32-bit float resolution of 0.5 ** 24 is 5.960464477539063e-08
            # For some reason rounding to 6 or 8 decimals and then comparing
            # fails, but rounding the delta works
            delta = (c - ruby).abs
            expect(MB::M.round(delta, filt ? 6 : 7).max).to eq(0)
          end
        end
      end
    end
  end

  describe '#active?' do
    it 'returns true while the envelope is sustaining or releasing, false otherwise' do
      expect(env).not_to be_active

      env.attack_time = 0
      env.decay_time = 0
      env.sustain_level = 1

      env.trigger(1)
      expect(env).to be_active

      env.sample(100)
      expect(env).to be_active

      env.release
      expect(env).to be_active

      env.sample(23999)
      expect(env).to be_active

      env.sample(1)
      expect(env).not_to be_active
    end
  end

  describe '#on?' do
    it 'returns true while sustaining, false otherwise' do
      expect(env).not_to be_on

      env.attack_time = 0
      env.decay_time = 0
      env.sustain_level = 1

      env.trigger(1)
      expect(env).to be_on

      env.sample(100)
      expect(env).to be_on

      env.release
      expect(env).not_to be_on

      env.sample(23999)
      expect(env).not_to be_on

      env.sample(1)
      expect(env).not_to be_on
    end
  end

  describe '#dup' do
    it 'returns a new envelope with a new filter' do
      dup = env.dup

      filter = env.instance_variable_get(:@filter)
      filter_dup = dup.instance_variable_get(:@filter)

      expect(dup.object_id).not_to eq(env.object_id)
      expect(filter_dup.object_id).not_to eq(filter.object_id)

      expect(dup.rate).to eq(env.rate)
      expect(filter_dup.sample_rate).to eq(filter.sample_rate)
    end

    it 'can change sample rate without changing the original' do
      dup = env.dup(1500)

      filter = env.instance_variable_get(:@filter)
      filter_dup = dup.instance_variable_get(:@filter)

      expect(dup.object_id).not_to eq(env.object_id)
      expect(filter_dup.object_id).not_to eq(filter.object_id)

      expect(dup.rate).to eq(1500)
      expect(env.rate).to eq(48000)
      expect(filter_dup.sample_rate).to eq(1500)
      expect(filter.sample_rate).to eq(48000)
    end
  end

  describe '#trigger' do
    it 'can set an automatic release' do
      env.trigger(1.0, auto_release: 0.1)

      6.times do
        expect(env.on?).to eq(true)
        expect(env.sample(800)).to be_a(Numo::SFloat)
      end

      30.times do |t|
        expect(env.on?).to eq(false)
        expect(env.sample(800)).to be_a(Numo::SFloat)
      end

      expect(env.sample(800)).to eq(nil)
    end
  end

  describe '#reset' do
    it 'can disable an automatic release' do
      env.trigger(1.0, auto_release: 0.1)
      env.reset

      60.times do
        expect(env.on?).to eq(false)
        expect(env.sample(800)).to be_a(Numo::SFloat)
      end
    end
  end
end
