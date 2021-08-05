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
end
