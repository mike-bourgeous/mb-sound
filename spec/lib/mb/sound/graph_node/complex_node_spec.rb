RSpec.describe(MB::Sound::GraphNode::ComplexNode, :aggregate_failures) do
  values = {
    real: {
      complex: {
        Numo::SComplex[1, -1i, 0.5+0.5i, 0] => Numo::SFloat[1, 0, 0.5, 0],
        Numo::DComplex[1, -1i, 0.5+0.5i, 0] => Numo::DFloat[1, 0, 0.5, 0],
      },
      real: {
        Numo::SFloat[4, -4, 0] => Numo::SFloat[4, -4, 0],
        Numo::DFloat[4, -4, 0] => Numo::DFloat[4, -4, 0],
      },
    },
    imag: {
      complex: {
        Numo::SComplex[1, -1i, 0.5+0.5i, 0] => Numo::SFloat[0, -1, Math.sqrt(2)/2, 0],
        Numo::DComplex[1, -1i, 0.5+0.5i, 0] => Numo::DFloat[0, -1, Math.sqrt(2)/2, 0],
      },
      real: {
        Numo::SFloat[4, -4, 0] => Numo::SFloat[4, -4, 0],
        Numo::DFloat[4, -4, 0] => Numo::DFloat[4, -4, 0],
      },
    },
    abs: {
      complex: {
        'TODO' => 'FIXME'
      },
      real: {
        'TODO' => 'FIXME'
      },
    },
    arg: {
      complex: {
        'TODO' => 'FIXME'
      },
      real: {
        'TODO' => 'FIXME'
      },
    },
  }

  values.each do |mode, inputs|
    context "when mode is #{mode}" do
      inputs.each do |input_type, values|
        context "given a #{input_type} signal" do
          it 'returns expected outputs for given inputs' do
            values.each do |input, expected|
              chain = MB::Sound::ArrayInput.new(data: [input]).real
              expect(chain).to be_a(MB::Sound::GraphNode::ComplexNode)

              result = chain.sample(input.length)
              expect(result).to be_a(expected.class)
              expect(result).to eq(expected)
            end
          end
        end
      end
    end
  end
end
