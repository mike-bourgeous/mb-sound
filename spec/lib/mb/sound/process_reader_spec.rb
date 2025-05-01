RSpec.describe(MB::Sound::ProcessReader) do
  it 'processes read audio through the block given to the constructor' do
    d = Numo::SFloat[1,2,3,4,5,6,7,8].freeze
    ai = MB::Sound::ArrayInput.new(data: [d].freeze, buffer_size: 2)
    pr = MB::Sound::ProcessReader.new(ai) do |data|
      data.map { |c| -2 * c }
    end

    expect(pr.read).to eq([Numo::SFloat[-2, -4]])
    expect(pr.read).to eq([Numo::SFloat[-6, -8]])
    expect(pr.read(3)).to eq([Numo::SFloat[-10, -12, -14]])
  end

  it 'passes through rate and buffer size' do
    ai = MB::Sound::ArrayInput.new(data: [[5, 5].freeze].freeze, buffer_size: 2, sample_rate: 60)
    pr = MB::Sound::ProcessReader.new(ai) { |data| data }
    expect(pr.buffer_size).to eq(2)
    expect(pr.sample_rate).to eq(60)
    expect(pr.channels).to eq(1)
  end
end
