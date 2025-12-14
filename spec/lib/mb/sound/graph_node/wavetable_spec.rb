RSpec.describe(MB::Sound::GraphNode::Wavetable) do
  let(:data) { Numo::SFloat[[1, -1, 1, 1, -1 -1], [0, 1, -1, 1, 0, -1]] }

  it 'can be created' do
    expect(120.hz.ramp.wavetable(wavetable: data, number: 0.constant)).to be_a(MB::Sound::GraphNode::Wavetable)
  end

  describe '#sample' do
    it 'treats the upstream data as the phase source' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(0, 2, 13)])
      number = 0.constant
      expect(MB::M.round(phase.wavetable(wavetable: data, number: number).sample(12), 5)).to eq(
        Numo::SFloat[1, -1, 1, 1, -1, -1, 1, -1, 1, 1, -1, -1]
      )
    end

    it 'changes wave number based on the number source' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0, 1.0 / 6.0, 1.0 / 6.0]], repeat: true)
      number = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0.5, 1, 1.5]], repeat: true)
      expect(MB::M.round(phase.wavetable(wavetable: data, number: number).sample(8), 6)).to eq(
        Numo::SFloat[1, 0, -1, 1, 1, 0, -1, 1]
      )
    end

    it 'changes wave number based on the number source using linspace' do
      phase = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0, 1.0 / 6.0, 1.0 / 6.0]], repeat: true)
      number = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(0, 4, 9)])
      expect(MB::M.round(phase.wavetable(wavetable: data, number: number).sample(8), 6)).to eq(
        Numo::SFloat[1, 0, -1, 1, 1, 0, -1, 1]
      )
    end
  end
end
