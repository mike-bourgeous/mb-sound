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
end
