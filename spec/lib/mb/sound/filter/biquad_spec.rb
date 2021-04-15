RSpec.describe(MB::Sound::Filter::Biquad) do
  describe '.from_pole_zero' do
    let(:f) {
      MB::Sound::Filter::Biquad.new(0.2, 0.5, -0.3, 0.6, 0.1)
    }

    let(:g) {
      MB::Sound::Filter::Biquad.from_pole_zero(**f.polezero)
    }

    it 'results in the same poles and zeros it started with' do
      f_pz = f.polezero
      f_zeros = MB::M.round(f_pz[:zeros], 4).sort_by { |v| [v.imag, v.real] }
      f_poles = MB::M.round(f_pz[:poles], 4).sort_by { |v| [v.imag, v.real] }

      g_pz = g.polezero
      g_zeros = MB::M.round(g_pz[:zeros], 4).sort_by { |v| [v.imag, v.real] }
      g_poles = MB::M.round(g_pz[:poles], 4).sort_by { |v| [v.imag, v.real] }

      expect(g_poles).to eq(f_poles)
      expect(g_zeros).to eq(f_zeros)
    end

    it 'results in the same coefficients it started with' do
      pending 'FIXME: there is a gain factor that is not captured by the list of poles and zeros'
      f_coeff = MB::M.round(f.coefficients, 4)
      g_coeff = MB::M.round(g.coefficients, 4)
      expect(f_coeff).to eq(g_coeff)
    end
  end

  describe '#initialize' do
    it 'creates a filter with specified coefficients' do
      f = MB::Sound::Filter::Biquad.new(0.3, -0.2, 0.1, 0.0, 0.5)
      expect(f.coefficients).to eq([0.3, -0.2, 0.1, 0.0, 0.5])
    end
  end

  describe '#response' do
    it 'returns the gain at all points for a simple pass-through filter' do
      f = MB::Sound::Filter::Biquad.new(1, 0, 0, 0, 0)
      expect(f.response(0)).to eq(1.0)
      expect(f.response(0.5)).to eq(1.0)
      expect(f.response(0.9)).to eq(1.0)

      f = MB::Sound::Filter::Biquad.new(2, 0, 0, 0, 0)
      expect(f.response(0)).to eq(2.0)
      expect(f.response(0.5)).to eq(2.0)
      expect(f.response(0.9)).to eq(2.0)
    end

    it 'returns expected gain for a simple low-pass filter' do
      f = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 12000, quality: 0.5 ** 0.5)
      expect(f.response(0).abs.round(3)).to eq(1)
      expect(f.response(0.5 * Math::PI).abs.round(3)).to eq((0.5 ** 0.5).round(3))
      expect(f.response(Math::PI).abs.round(3)).to eq(0)
    end

    it 'accepts an NArray for calculating multiple response points' do
      points = Numo::SComplex.linspace(0, Math::PI, 100)
      f = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 4800, quality: 0.5 ** 0.5)
      expect(MB::M.round(f.response(points), 4)).to eq(points.map { |v| MB::M.round(f.response(v), 4) })
    end
  end

  describe '#reset' do
    [0, 0.5, -0.75].each do |v|
      it "can reset to #{v}" do
        f = MB::Sound::Filter::Cookbook.new(:lowshelf, 48000, 100, shelf_slope: 1.0, db_gain: -6.0)
        f.reset(v)
        input = Numo::SFloat.zeros(500).fill(v)
        output = input * f.response(0).real
        expect(MB::M.round(f.process(input), 5)).to eq(MB::M.round(output, 5))
      end
    end
  end

  describe '#z_response' do
    it 'returns the same value as #response for values on the unit circle' do
      f = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 12000, quality: 0.5 ** 0.5)
      expect(MB::M.round(f.z_response(1), 5)).to eq(MB::M.round(f.response(0), 5))
      expect(MB::M.round(f.z_response(0+1i), 5)).to eq(MB::M.round(f.response(Math::PI / 2), 5))
      expect(MB::M.round(f.z_response(-1), 5)).to eq(MB::M.round(f.response(Math::PI), 5))

      expect(MB::M.round(f.z_response(CMath.exp(0+1i)), 5)).to eq(MB::M.round(f.response(1), 5))
    end

    it 'accepts an NArray for calculating multiple response points' do
      grid_size = 20
      points = Numo::DComplex[
        Numo::DComplex.linspace(-1, 1, grid_size).to_enum.map { |v|
          Numo::DComplex.linspace(v - 1i, v + 1i, grid_size)
        }
      ].reshape(grid_size, grid_size)

      f = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 4800, quality: 0.5 ** 0.5)
      expect(MB::M.round(f.z_response(points), 4)).to eq(points.map { |v| MB::M.round(f.z_response(v), 4) })
    end
  end

  describe '#polezero' do
    it 'returns expected poles and zeros for a test filter' do
      f = MB::Sound::Filter::Biquad.new(0.17039, 0.22048, 0.10905, -0.5, 0)
      pz = f.polezero
      poles = MB::M.round(pz[:poles], 2)
      zeros = MB::M.round(pz[:zeros], 2)
      expect(poles).to eq([0.5])
      expect(zeros.sort_by{|v| v.imag}).to eq([-0.65-0.47i, -0.65+0.47i])
    end
  end
end
