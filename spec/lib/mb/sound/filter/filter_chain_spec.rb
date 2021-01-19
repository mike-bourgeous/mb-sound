RSpec.describe(MB::Sound::Filter::FilterChain) do
  let (:chain) {
    MB::Sound::Filter::FilterChain.new(
      MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 1000, shelf_slope: 1.0, db_gain: -6.0),
      MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 2000, shelf_slope: 1.0, db_gain: -3.0),
      MB::Sound::Filter::FIR.new({100 => -2.db, 20000 => 0.db})
    )
  }

  let (:biquad) {
    MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 4800)
  }

  [:chain, :biquad].each do |f|
    context "with #{f}" do
      let(:filter) { send(f) }

      describe '#reset' do
        [0, 0.5, -0.75].each do |v|
          it "returns the steady state output for #{v}" do
            expect(filter.reset(v).round(6)).to eq((v * filter.response(0).real).round(6))
          end

          it "can reset to #{v}" do
            noise = Numo::SFloat.zeros(20000).rand(-1, 1)
            filter.process(noise)
            filter.reset(v)
            input = Numo::SFloat.zeros(500).fill(v)
            output = input * filter.response(0).real
            expect(MB::Sound::M.round(filter.process(input), 5)).to eq(MB::Sound::M.round(output, 5))
          end
        end
      end

      describe '#response' do
        it 'accepts an NArray for calculating multiple response points' do
          points = Numo::DComplex.linspace(0, Math::PI, 100)
          expect(MB::Sound::M.round(filter.response(points), 4)).to eq(points.map { |v| MB::Sound::M.round(filter.response(v), 4) })
        end
      end
    end
  end

  describe '#z_response' do
    it 'accepts an NArray for calculating multiple response points' do
      grid_size = 20
      points = Numo::DComplex[
        Numo::DComplex.linspace(-1, 1, grid_size).to_enum.map { |v|
          Numo::DComplex.linspace(v - 1i, v + 1i, grid_size)
        }
      ].reshape(grid_size, grid_size)

      f = MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 4800)
      expect(MB::Sound::M.round(f.z_response(points), 4)).to eq(points.map { |v| MB::Sound::M.round(f.z_response(v), 4) })
    end
  end
end
