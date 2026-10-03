RSpec.describe(MB::FastSound) do
  [:smoothstep, :smootherstep].each do |m_base|
    m = "#{m_base}_buf".to_sym

    describe ".#{m}" do
      [Numo::SFloat, Numo::SComplex].each do |cls|
        context "(#{cls})" do
          let(:expected) {
            Numo::SFloat.zeros(752).inplace.map_with_index { |v, idx|
              MB::M.send(m_base, (idx.to_f + 0.5) / 752.to_f)
            }.not_inplace!
          }

          context 'not inplace' do
            it "creates a #{cls} with a #{m_base} curve from 0 to 1" do
              # Will create a new copy because it wasn't inplace
              buf = Numo::SFloat.zeros(752)
              result = MB::FastSound.send(m, buf)
              expect(MB::M.round(result, 6)).to eq(MB::M.round(expected, 6))
              expect(result).not_to equal(buf)
              expect(result.min.round(3)).to eq(0)
              expect(result.max.round(3)).to eq(1)
            end
          end

          context 'inplace' do
            it "fills an existing #{cls} with a #{m_base} curve from 0 to 1" do
              # Will create a new copy because it wasn't inplace
              buf = Numo::SFloat.zeros(752).inplace!
              result = MB::FastSound.send(m, buf)
              expect(MB::M.round(result, 6)).to eq(MB::M.round(expected, 6))
              expect(result).to equal(buf)
              expect(result.min.round(3)).to eq(0)
              expect(result.max.round(3)).to eq(1)
            end
          end
        end
      end
    end
  end

  describe '.matrix_mix' do
    let(:matrix) { Numo::DFloat[[1, -1, 0.5], [0, 2, -1]] }
    let(:inputs) { [Numo::SFloat[1, 2, 3, 9], Numo::SFloat[4, 5, 6, 9], Numo::SFloat[-2, 0, 2, 9]] }

    it 'multiplies the input column by the matrix into the outputs' do
      outputs = [Numo::SFloat.new(3).fill(7), Numo::SFloat.new(3).fill(7)]
      expect(MB::FastSound.matrix_mix(matrix, inputs, outputs)).to equal(outputs)
      expect(outputs[0].to_a).to eq([-4, -3, -2])
      expect(outputs[1].to_a).to eq([10, 10, 10])
    end

    it 'matches the Ruby Matrix product of NArrays' do
      m = Numo::DFloat.new(4, 4).rand(-1, 1)
      data = Array.new(4) { Numo::SFloat.new(100).rand(-1, 1) }
      expected = (Matrix[*m.to_a] * Vector[*data]).to_a
      result = MB::FastSound.matrix_mix(m, data, Array.new(4) { Numo::SFloat.zeros(100) })
      result.each_with_index do |r, idx|
        expect(r).to eq(expected[idx])
      end
    end

    it 'rejects outputs that are also inputs' do
      expect { MB::FastSound.matrix_mix(matrix, inputs, [inputs[0][0...3], Numo::SFloat.zeros(3)]) }.to raise_error(ArgumentError, /contiguous|also input/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [inputs[1], Numo::SFloat.zeros(4)]) }.to raise_error(ArgumentError, /also input/)
    end

    it 'rejects the wrong number or type of channels' do
      expect { MB::FastSound.matrix_mix(matrix, inputs[0..1], [Numo::SFloat.zeros(3)] * 2) }.to raise_error(ArgumentError, /inputs/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [Numo::SFloat.zeros(3)]) }.to raise_error(ArgumentError, /outputs/)
      expect { MB::FastSound.matrix_mix(matrix, inputs.map(&:to_a), [Numo::SFloat.zeros(3)] * 2) }.to raise_error(ArgumentError, /SFloat/)
      expect { MB::FastSound.matrix_mix(matrix, inputs, [Numo::SFloat.zeros(9), Numo::SFloat.zeros(9)]) }.to raise_error(ArgumentError, /shorter/)
    end
  end
end
