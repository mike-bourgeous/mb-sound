RSpec.describe(MB::Sound::GainMethods) do
  describe '#normalize_max' do
    context 'when louder is false' do
      # Test various limits
      [0.75, 1.0, 1.5].each do |limit|
        context "with a limit of #{limit}" do
          pending 'does not make quieter sounds louder'
          pending 'makes louder sounds quieter'
        end
      end

      context 'when no limit is given' do
        pending 'uses a limit of 1.0'
      end
    end

    context 'when louder is true' do
      pending 'raises a quieter sound to the default limit of 1.0'
      pending 'raises a quieter sound to a different limit of 1.5'
      pending 'makes a louder sound quieter'
    end

    context 'when louder is a fraction' do
      context 'when no limit is given' do
        pending 'makes a louder sound match the limit'
        pending 'makes a quieter sound louder, but not to the limit'
      end

      context 'when a custom limit is given' do
        pending 'makes a louder sound match the limit'
        pending 'makes a quieter sound louder, but not to the limit'
      end
    end
  end

  describe '#normalize_max_sum' do
    pending 'can use a custom limit'
    pending 'makes louder sounds quieter'
    pending 'does not make quieter sounds louder'
  end
end
