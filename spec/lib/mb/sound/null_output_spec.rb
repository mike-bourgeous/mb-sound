require 'benchmark'

RSpec.describe(MB::Sound::NullOutput) do
  let(:null_sleep) { MB::Sound::NullOutput.new(channels: 1, sleep: true) }
  let(:null_sleep_44k) { MB::Sound::NullOutput.new(channels: 1, sleep: true, rate: 44100) }
  let(:null_no_sleep) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:null_3ch) { MB::Sound::NullOutput.new(channels: 3, sleep: false) }
  let(:short_data) { [Numo::SFloat.zeros(12000)] }
  let(:long_data) { [Numo::SFloat.zeros(96000)] }

  describe '#initialize' do
    describe 'strict_buffer_size parameter' do
      it 'defaults to false' do
        expect(null_3ch.strict_buffer_size?).to eq(false)
      end

      it 'can be set to false' do
        expect(MB::Sound::NullOutput.new(channels: 1, strict_buffer_size: false).strict_buffer_size?).to eq(false)
      end

      it 'can be set to true' do
        expect(MB::Sound::NullOutput.new(channels: 1, strict_buffer_size: true).strict_buffer_size?).to eq(true)
      end
    end
  end

  describe '#close' do
    it 'prevents further writing' do
      expect { null_3ch.write([short_data] * 3) }.not_to raise_error
      null_3ch.close
      expect { null_3ch.write([short_data] * 3) }.to raise_error(/closed/)
    end
  end

  describe '#write' do
    context 'when sleep is true' do
      it 'waits for the length of the buffer' do
        expect(Kernel).to receive(:sleep).with(0.25)
        null_sleep.write(short_data)

        expect(Kernel).to receive(:sleep).with(2.0)
        null_sleep.write(long_data)
      end

      it 'waits based on sample rate' do
        expect(Kernel).to receive(:sleep).with(1.0)
        null_sleep_44k.write([Numo::SFloat.zeros(44100)])
      end
    end

    context 'when sleep is false' do
      it 'returns instantly' do
        expect(Kernel).not_to receive(:sleep)
        null_no_sleep.write(short_data)
        null_no_sleep.write(long_data)
      end
    end

    it 'raises an error if given the wrong number of channels' do
      expect { null_no_sleep.write(short_data + long_data) }.to raise_error(/channels/i)
    end
  end
end
