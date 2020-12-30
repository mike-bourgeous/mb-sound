RSpec.describe(MB::Sound::Filter::FilterChain) do
  describe '#reset' do
    pending
  end

  describe '#response' do
    it 'accepts an NArray for calculating multiple response points' do
      points = Numo::SComplex.linspace(0, Math::PI, 100)
      f = MB::Sound::Filter::Butterworth.new(:lowpass, 5, 48000, 4800)
      expect(MB::Sound::M.round(f.response(points), 4)).to eq(points.map { |v| MB::Sound::M.round(f.response(v), 4) })
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

  pending
end
