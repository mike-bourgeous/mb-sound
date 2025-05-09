RSpec.describe(MB::Sound::HaasPan) do
  let(:d_default) { MB::Sound::HaasPan.new }
  let(:d_32k_r) { MB::Sound::HaasPan.new(delay: 0.1, sample_rate: 32000) }
  let(:d_44k1_l) { MB::Sound::HaasPan.new(delay: -0.2, sample_rate: 44100) }

  describe '#initialize' do
    it 'can be constructed with no parameters' do
      d = nil
      expect { d = d_default }.not_to raise_error
      expect(d.delay).to eq(0)
      expect(d.sample_rate).to eq(48000)
      expect(d.left_delay).to eq(0)
      expect(d.right_delay).to eq(0)
      expect(d.left_delay_samples).to eq(0)
      expect(d.right_delay_samples).to eq(0)
    end

    it 'can use a custom delay and rate' do
      d = nil
      expect { d = d_32k_r }.not_to raise_error
      expect(d.delay).to eq(0.1)
      expect(d.sample_rate).to eq(32000)
      expect(d.left_delay).to eq(0)
      expect(d.right_delay).to eq(0.1)
      expect(d.left_delay_samples).to eq(0)
      expect(d.right_delay_samples).to eq(3200)
    end

    it 'can use a negative delay' do
      d = nil
      expect { d = d_44k1_l }.not_to raise_error
      expect(d.delay).to eq(-0.2)
      expect(d.sample_rate).to eq(44100)
      expect(d.left_delay).to eq(0.2)
      expect(d.right_delay).to eq(0)
      expect(d.left_delay_samples).to eq(8820)
      expect(d.right_delay_samples).to eq(0)
    end
  end

  describe '#process' do
    let(:data) { Numo::SFloat.zeros(8).rand(-1, 1) }

    it 'can process a single NArray' do
      result = d_default.process(data)
      expect(result).to eq([data, data])
    end

    it 'can process a one-element Array with a single NArray' do
      result = d_default.process([data])
      expect(result).to eq([data, data])
    end

    it 'can process a two-element Array of NArray' do
      result = d_default.process([data, data])
      expect(result).to eq([data, data])
    end

    it 'raises an error if given too many channels' do
      expect { d_default.process([data, data, data]) }.to raise_error(/channels/)
    end

    it 'delays the right channel when delay is positive' do
      expected = [
        data,
        MB::M.shr(data, 3)
      ]

      d_32k_r.delay_samples = 3
      d_32k_r.reset_delay

      result = d_32k_r.process(data)
      expect(result).to eq(expected)
    end

    it 'delays the left channel when delay is negative' do
      expected = [
        MB::M.shr(data, 4),
        data
      ]

      d_44k1_l.delay_samples = -4
      d_44k1_l.reset_delay

      result = d_44k1_l.process(data)
      expect(result).to eq(expected)
    end

    # TODO: Does this need to be re-tested here when it's tested on Filter::Delay?
    pending 'smooths delay changes'
  end
end
