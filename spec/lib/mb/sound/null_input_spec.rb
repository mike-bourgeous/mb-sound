RSpec.describe MB::Sound::NullInput do
  describe '#buffer_size' do
    it 'returns nil by default' do
      expect(MB::Sound::NullInput.new(channels: 1).buffer_size).to be_nil
    end

    it 'returns an integer value if given' do
      expect(MB::Sound::NullInput.new(channels: 1, buffer_size: 12345).buffer_size).to eq(12345)
    end
  end

  describe '#close' do
    it 'prevents further reading' do
      input = MB::Sound::NullInput.new(channels: 3, fill: 0.3)
      expect(input.read(1)).to eq([Numo::SFloat[0.3]] * 3)
      input.close
      expect { input.read(1) }.to raise_error(/closed/)
    end
  end

  describe '#read' do
    context 'with no length set' do
      it 'returns the full frames count for a long time' do
        ni = MB::Sound::NullInput.new(channels: 1, initial_buffer: 4096)
        1000.times do
          result = ni.read(4096)
          expect(result.length).to eq(1)
          expect(result.first.length).to eq(4096)
          expect(result.first).to eq(Numo::SFloat.zeros(4096))
        end
      end

      it 'can grow the sample buffer' do
        ni = MB::Sound::NullInput.new(channels: 1, initial_buffer: 10)
        expect(ni.read(512)).to eq([Numo::SFloat.zeros(512)])
      end

      (1..10).each do |n|
        it "can return zero samples if zero are requested for #{n} channels" do
          ni = MB::Sound::NullInput.new(channels: n)
          expect(ni.read(0)).to eq([Numo::SFloat[]] * n)
        end

        it "returns the expected number of samples for #{n} channels" do
          ni = MB::Sound::NullInput.new(channels: n)
          expect(ni.read(1)).to eq([Numo::SFloat.zeros(1)] * n)
          expect(ni.read(2048)).to eq([Numo::SFloat.zeros(2048)] * n)
        end
      end
    end

    context 'with a finite length set' do
      it 'returns exactly the expected length' do
        ni = MB::Sound::NullInput.new(channels: 3, length: 54321)
        expect(ni.read(65432)).to eq([Numo::SFloat.zeros(54321)] * 3)
      end

      it 'can be used by stream-processing functions' do
        ni = MB::Sound::NullInput.new(channels: 7, length: 48000)
        window = MB::Sound::Window::Rectangular.new(480)
        MB::Sound.analyze_window(ni, window) do |dfts|
          expect(dfts.size).to eq(7)
          expect(dfts.map(&:sum).sum).to eq(0)
        end
      end

      (1..10).each do |n|
        it "can return zero samples if zero are requested for #{n} channels" do
          ni = MB::Sound::NullInput.new(channels: n, length: 114813)
          expect(ni.read(0)).to eq([Numo::SFloat[]] * n)
        end

        it "returns the expected number of samples for #{n} channels" do
          ni = MB::Sound::NullInput.new(channels: n, length: 114813)

          buffer = ni.read(1)
          expect(buffer.length).to eq(n)
          loop do
            result = ni.read(4096)
            break if result.first.length == 0
            buffer = result.each_with_index.map { |c, idx|
              buffer[idx].concatenate(c)
            }
          end

          expect(buffer.map(&:length).sum).to eq(114813 * n)
          expect(buffer.map(&:sum).sum).to eq(0)
        end
      end
    end
  end
end
