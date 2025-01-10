RSpec.describe MB::Sound::WindowReader do
  describe '#read' do
    def read_everything(frames:, window_size:, hop:, fill_value:)
      w = MB::Sound::Window::DoubleHann.new(1024)
      w.force_hop(hop)

      ni = MB::Sound::NullInput.new(channels: 1, length: frames, fill: fill_value, strict_buffer_size: true)
      wr = MB::Sound::WindowReader.new(ni, w)

      data = []
      # limit to some really high overestimate to prevent the test stalling if read never returns nil
      (frames * window_size * 10).times do
        d = wr.read
        break if d.nil?
        data << d[0]
      end

      data
    end

    it 'reads all zeros when the input is zero' do
      data = read_everything(frames: 123456, window_size: 1024, hop: 128, fill_value: 0)
      expect(data.map(&:sum).reduce(&:+)).to eq(0)
    end

    it 'reads nonzero data when the input is all nonzero' do
      data = read_everything(frames: 123456, window_size: 1024, hop: 128, fill_value: 1)
      expect(data.map(&:sum).reduce(&:+)).not_to eq(0)
      expect(data[100].sum.round(5)).to eq(1024)
    end

    context 'when the hop size divides the input size' do
      it 'reads the expected number of frames for a multiple of hop/window size' do
        data = read_everything(frames: 500000, window_size: 1000, hop: 100, fill_value: 0)
        # Expect length/hops rounded up, plus an extra window/hop-1 to get to the last nonzero output
        expected_hops = (500000 + 100 - 1) / 100 + (1000 / 100) - 1
        expect(data.size).to eq(expected_hops)
      end

      it 'does not read any all-zero frames at the end' do
        data = read_everything(frames: 123456, window_size: 1024, hop: 128, fill_value: 1)
        expect(data.map(&:sum).count(&:zero?)).to eq(0)
      end
    end

    context 'when the hop size does not divide the input size' do
      it 'reads the expected number of hops for a non-multiple of hop/window size' do
        data = read_everything(frames: 123456, window_size: 1024, hop: 128, fill_value: 0)
        expected_hops = (123456 + 128 - 1) / 128 + (1024 / 128) - 1
        expect(data.size).to eq(expected_hops)
      end

      it 'does not read any all-zero frames at the end' do
        data = read_everything(frames: 123456, window_size: 1024, hop: 128, fill_value: 1)
        expect(data.map(&:sum).count(&:zero?)).to eq(0)
      end
    end
  end

  pending 'pad factor'
end
