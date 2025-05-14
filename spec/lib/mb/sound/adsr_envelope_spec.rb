RSpec.describe(MB::Sound::ADSREnvelope, :aggregate_failures) do
  let(:env) {
    MB::Sound::ADSREnvelope.new(
      attack_time: 0.1,
      decay_time: 0.2,
      sustain_level: 0.75,
      release_time: 0.5,
      sample_rate: 48000
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

    expect(r2).not_to eq(r1_data)

    # Use modification to verify the same buffer is used even if we receive
    # different view objects pointing to that buffer.
    r1[0] = 123.456
    expect(r2[0]).to be_within(0.00001).of(123.456)
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
            expect(c).to all_be_within(1e-6).of_array(ruby)
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
            require 'pry-byebug'; binding.pry # XXX
            expect(c).to all_be_within(1e-6).of_array(ruby)
          end

          it 'reuses the same buffer' do
            d1 = env.send(m, 500)
            d2 = env.send(m, 500)

            # d1 and d2 may have different object IDs if they are views onto
            # the same buffer, so modify one and then look at the other.
            d1[0] = 123.456
            expect(d2[0]).to be_within(0.00001).of(123.456)
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

      expect(dup.sample_rate).to eq(env.sample_rate)
      expect(filter_dup.sample_rate).to eq(filter.sample_rate)
    end

    it 'can change sample rate without changing the original' do
      dup = env.dup(1500)

      filter = env.instance_variable_get(:@filter)
      filter_dup = dup.instance_variable_get(:@filter)

      expect(dup.object_id).not_to eq(env.object_id)
      expect(filter_dup.object_id).not_to eq(filter.object_id)

      expect(dup.sample_rate).to eq(1500)
      expect(env.sample_rate).to eq(48000)
      expect(filter_dup.sample_rate).to eq(1500)
      expect(filter.sample_rate).to eq(48000)
    end

    it 'does not use the same buffer as the original' do
      env.sample(800)
      dup = env.dup(1000)
      expect(env.sample(800).object_id).not_to eq(dup.sample(800).object_id)

      data = env.sample(800)
      expect(data.minmax).to eq([0, 0])

      dup.sample_all
      expect(data.minmax).to eq([0, 0])
    end

    it 'does not use the same buffer as the original (using vis env)' do
      cenv2 = MB::Sound.adsr(0, 0.2, 0.0, 0.1).reset.named('cenv2')

      cenv2.sample(800)
      dup = cenv2.dup(1900)

      data = cenv2.sample(800)
      expect(data.minmax).to eq([0, 0])

      # Detect dup overwriting original buffer
      dup.sample_all
      expect(data.minmax).to eq([0, 0])

      expect(cenv2.sample(800).object_id).not_to eq(dup.sample(800).object_id)
    end
  end

  describe '#trigger' do
    it 'can set an automatic release for use in the interactive DSL' do
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

    it 'behaves correctly when given an integer peak values' do
      env.attack_time = 50
      env.reset
      env.trigger(1)
      expect(env.sample(500).max).to be_between(0.0, 0.01)
    end
  end

  describe '#sample_all' do
    context 'with sustain of 1' do
      it 'remains within the expected range for the envelope' do
        # These parameters were causing bizarre plots on one of my livestreams
        env = described_class.new(attack_time: 0.1385901240393387, decay_time: 0.9133346228248626, sustain_level: 1, release_time: 1.8523222156741201, sample_rate: 48000)

        d = env.sample_all
        expect(d[0]).to be_between(0, 0.01)
        expect(d[-1]).to be_between(0, 0.01)
        expect(d[env.sample_rate * env.attack_time]).to be_between(0.99, 1.0)
        expect(d[env.sample_rate * (env.attack_time + env.decay_time)]).to be_between(0.99, 1.0)
        expect(d.min).to be_between(0, 0.0001)
        expect(d.max).to be_between(0.99, 1.0)
      end
    end

    context 'with sustain of 0.5' do
      it 'remains within the expected range for the envelope' do
        # These parameters were causing bizarre plots on one of my livestreams
        env = described_class.new(attack_time: 0.1385901240393387, decay_time: 0.9133346228248626, sustain_level: 0.5, release_time: 1.8523222156741201, sample_rate: 48000)

        d = env.sample_all
        expect(d[0]).to be_between(0, 0.01)
        expect(d[-1]).to be_between(0, 0.01)
        expect(d[env.sample_rate * env.attack_time]).to be_between(0.99, 1.0)
        expect(d[env.sample_rate * (env.attack_time + env.decay_time)]).to be_between(0.49, 0.51)
        expect(d.min).to be_between(0, 0.0001)
        expect(d.max).to be_between(0.99, 1.0)
      end
    end
  end

  describe '#reset' do
    it 'resets the envelope time' do
      env.time = 0.5
      expect { env.reset }.to change { env.time }
    end

    it 'can disable an automatic release' do
      env.trigger(1.0, auto_release: 0.1)
      env.reset

      60.times do
        expect(env.on?).to eq(false)
        expect(env.sample(800)).to be_a(Numo::SFloat)
      end
    end
  end

  describe '#randomize' do
    it 'changes envelope parameters within the given range' do
      values = []

      100.times do
        env.randomize(0..5)
        values << env.attack_time
        values << env.decay_time
        values << env.release_time
        expect(env.sustain_level).to be_between(0, 1)
      end

      expect(values.min).to be_between(0, 1)
      expect(values.max).to be_between(4, 5)
      expect(values.sum / values.count).to be_between(1.5, 3.5)
    end

    it 'defaults to a range of 0 to 1' do
      env.randomize
      expect(env.attack_time).to be_between(0, 1)
      expect(env.decay_time).to be_between(0, 1)
      expect(env.sustain_level).to be_between(0, 1)
      expect(env.release_time).to be_between(0, 1)
    end

    it 'does not reset the envelope timer' do
      env.time = 0.5
      expect { env.randomize }.not_to change { env.time }
    end
  end
end
