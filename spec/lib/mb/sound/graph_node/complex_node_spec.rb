RSpec.describe(MB::Sound::GraphNode::ComplexNode, :aggregate_failures) do
  describe '#sample' do
    test_values = {
      Numo::SComplex[1, -1i, 0.5+0.5i, 0] => {
        real: Numo::SFloat[1, 0, 0.5, 0],
        imag: Numo::SFloat[0, -1, 0.5, 0],
        abs: Numo::SFloat[1, 1, Math.sqrt(2) / 2, 0],
        arg: Numo::SFloat[0, -Math::PI / 2, Math::PI / 4, 0],
      },
      Numo::DComplex[1, -1i, 0.5+0.5i, 0] => {
        real: Numo::DFloat[1, 0, 0.5, 0],
        imag: Numo::DFloat[0, -1, 0.5, 0],
        abs: Numo::DFloat[1, 1, Math.sqrt(2) / 2, 0],
        arg: Numo::DFloat[0, -Math::PI / 2, Math::PI / 4, 0],
      },
      Numo::SFloat[4, -4, 0] => {
        real: Numo::SFloat[4, -4, 0],
        imag: Numo::SFloat[0, 0, 0],
        abs: Numo::SFloat[4, 4, 0],
        arg: Numo::SFloat[0, Math::PI, 0],
      },
      Numo::DFloat[4, -4, 0] => {
        real: Numo::DFloat[4, -4, 0],
        imag: Numo::DFloat[0, 0, 0],
        abs: Numo::DFloat[4, 4, 0],
        arg: Numo::DFloat[0, Math::PI, 0],
      },
    }

    test_values.each do |input, cases|
      context "when given a #{input.class}" do
        cases.each do |mode, expected|
          context "when mode is #{mode}" do
            it 'returns expected outputs for given inputs' do
              chain = MB::Sound::ArrayInput.new(data: [input]).send(mode)
              expect(chain).to be_a(MB::Sound::GraphNode::ComplexNode)
              expect(chain.mode).to eq(mode)

              result = chain.sample(input.length)
              expect(result).to be_a(expected.class)
              expect(result).to eq(expected)
            end
          end
        end
      end
    end

    pending 'returns nil for nil input'
  end

  describe '#sources' do
    it 'returns the input as its sole source' do
      source = 5.constant
      chain = source.real
      expect(chain).to be_a(MB::Sound::GraphNode::ComplexNode)
      expect(chain.sources).to eq([source])
    end
  end
end
