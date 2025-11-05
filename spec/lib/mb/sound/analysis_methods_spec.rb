RSpec.describe(MB::Sound::AnalysisMethods) do
  pending '#crosscorrelate'
  pending '#freq_estimate'

  describe '#fetch_oob' do
    [Array, Numo::SFloat, Numo::DComplex].each do |ctx|
      context ctx do
        it 'returns values within bounds' do
          val = ctx[1,2,3]
          expect(MB::Sound.fetch_oob(val, 0, before: -1, after: -2)).to eq(1)
          expect(MB::Sound.fetch_oob(val, 1, before: -1, after: -2)).to eq(2)
          expect(MB::Sound.fetch_oob(val, 2, before: -1, after: -2)).to eq(3)
        end

        it 'returns before and after for out of bounds values' do
          val = ctx[1,2,3]
          expect(MB::Sound.fetch_oob(val, -1, before: -1, after: -2)).to eq(-1)
          expect(MB::Sound.fetch_oob(val, 3, before: -1, after: -2)).to eq(-2)
        end

        it 'returns first and last value for out of bounds values if before/after not present' do
          val = ctx[1,2,3]
          expect(MB::Sound.fetch_oob(val, -2)).to eq(1)
          expect(MB::Sound.fetch_oob(val, -1)).to eq(1)
          expect(MB::Sound.fetch_oob(val, 3)).to eq(3)
          expect(MB::Sound.fetch_oob(val, 4)).to eq(3)
        end
      end
    end
  end
end
