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
end
