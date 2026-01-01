RSpec.describe(MB::Sound::FastWavetable, aggregate_failures: true) do
  # Additional tests are in specs for MB::Sound::Wavetable and MB::Sound::GraphNode::Wavetable.

  describe '.outer_linear' do
    it 'can retrieve a value from a wavetable' do
      expect(MB::Sound::FastWavetable.outer_linear(Numo::SFloat[[0, 1], [-1, 2]], 0, 0 * 2 - 1, :wrap)).to eq(0)
      expect(MB::Sound::FastWavetable.outer_linear(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0.5 * 2 - 1, :wrap)).to eq(2)
      expect(MB::Sound::FastWavetable.outer_linear(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0 * 2 - 1, :wrap)).to eq(-1)
    end
  end

  describe '.outer_cubic' do
    it 'can retrieve a value from a wavetable' do
      expect(MB::Sound::FastWavetable.outer_cubic(Numo::SFloat[[0, 1], [-1, 2]], 0, 0 * 2 - 1, :wrap)).to eq(0)
      expect(MB::Sound::FastWavetable.outer_cubic(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0.5 * 2 - 1, :wrap)).to eq(2)
      expect(MB::Sound::FastWavetable.outer_cubic(Numo::SFloat[[0, 1], [-1, 2]], 0.5, 0 * 2 - 1, :wrap)).to eq(-1)
    end
  end

  describe '.wavetable_lookup' do
    let(:table) { Numo::SFloat[[0, 1, -2], [-1, 2, -3]] }
    let(:number) { Numo::SFloat[0, 0.5, 0.5] }
    let(:phase) { Numo::SFloat[0, 1.0 / 3.0, 1] * 2 - 1 }

    it 'can retrieve values from a wavetable using narrays and linear interpolation' do
      expect(MB::Sound::FastWavetable.wavetable_lookup(table, number, phase, :linear, :wrap)).to all_be_within(1e-6).of_array(Numo::SFloat[0, 2, -1])
    end

    it 'can retrieve values from a wavetable using narrays and cubic interpolation' do
      expect(MB::Sound::FastWavetable.wavetable_lookup(table, number, phase, :cubic, :wrap)).to all_be_within(1e-6).of_array(Numo::SFloat[0, 2, -1])
    end

    it 'can bounce oob' do
      expect(MB::Sound::FastWavetable.wavetable_lookup(table, number, phase, :cubic, :bounce)).to all_be_within(1e-6).of_array(Numo::SFloat[0, 2, 2])
    end
  end

  describe '.fetch_oob' do
    let(:table) { Numo::SFloat[1, -2, 3, -4] }
    let(:table5) { Numo::SFloat[1, -2, 3, -4, 5] }
    let(:table6) { Numo::SFloat[1, 2, 3, 4, 5, -6] }

    it 'can bounce when length is 4' do
      expect(MB::Sound::FastWavetable.fetch_oob(table, -5, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -4, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -3, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -2, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -1, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 0, :bounce)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 1, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 2, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 3, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 4, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 5, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 6, :bounce)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 7, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 8, :bounce)).to eq(3)
    end

    it 'can bounce when length is 5' do
      expect(MB::Sound::FastWavetable.fetch_oob(table5, -5, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, -4, :bounce)).to eq(5)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, -3, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, -2, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, -1, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 0, :bounce)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 1, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 2, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 3, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 4, :bounce)).to eq(5)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 5, :bounce)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 6, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 7, :bounce)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 8, :bounce)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table5, 9, :bounce)).to eq(-2)
    end

    it 'can return data from a 6-element array' do
      expect(MB::Sound::FastWavetable.fetch_oob(table6, -11, :bounce)).to eq(2)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, -6, :bounce)).to eq(5)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, -5, :bounce)).to eq(-6)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, -1, :bounce)).to eq(2)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 0, :bounce)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 1, :bounce)).to eq(2)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 2, :bounce)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 3, :bounce)).to eq(4)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 4, :bounce)).to eq(5)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 5, :bounce)).to eq(-6)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 6, :bounce)).to eq(5)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 7, :bounce)).to eq(4)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 11, :bounce)).to eq(2)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 15, :bounce)).to eq(-6)
      expect(MB::Sound::FastWavetable.fetch_oob(table6, 16, :bounce)).to eq(5)
    end

    it 'can wrap' do
      expect(MB::Sound::FastWavetable.fetch_oob(table, -9, :wrap)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -8, :wrap)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -7, :wrap)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -6, :wrap)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -5, :wrap)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -4, :wrap)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -3, :wrap)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -2, :wrap)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -1, :wrap)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 0, :wrap)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 1, :wrap)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 2, :wrap)).to eq(3)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 3, :wrap)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 4, :wrap)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 5, :wrap)).to eq(-2)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 8, :wrap)).to eq(1)
    end

    it 'can clamp' do
      expect(MB::Sound::FastWavetable.fetch_oob(table, 0, :clamp)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -1, :clamp)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 3, :clamp)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 4, :clamp)).to eq(-4)
    end

    it 'can zero' do
      expect(MB::Sound::FastWavetable.fetch_oob(table, 0, :zero)).to eq(1)
      expect(MB::Sound::FastWavetable.fetch_oob(table, -1, :zero)).to eq(0)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 3, :zero)).to eq(-4)
      expect(MB::Sound::FastWavetable.fetch_oob(table, 4, :zero)).to eq(0)
    end
  end

  describe '.cubic_coeffs' do
    it 'behaves like MB::M.cubic_coeffs_direct' do
      y_1 = -5
      y0 = 2
      y1 = 1
      y2 = -3

      d0 = (y1 - y_1) / 2.0
      d1 = (y2 - y0) / 2.0

      expect(MB::Sound::FastWavetable.cubic_coeffs(y_1, y0, y1, y2)).to all_be_within(1e-7).of_array(MB::M.cubic_coeffs_direct(y0, d0, y1, d1))
    end
  end

  describe '.cubic_interp' do
    it 'behaves like MB::M.cubic_interp' do
      y_1 = -5
      y0 = 2
      y1 = 1
      y2 = -3

      d0 = (y1 - y_1) / 2.0
      d1 = (y2 - y0) / 2.0

      expect(MB::Sound::FastWavetable.cubic_interp(y_1, y0, y1, y2, 0.1)).to be_within(1e-7).of(MB::M.cubic_interp(y0, d0, y1, d1, 0.1))
      expect(MB::Sound::FastWavetable.cubic_interp(y_1, y0, y1, y2, 0.3234)).to be_within(1e-7).of(MB::M.cubic_interp(y0, d0, y1, d1, 0.3234))
      expect(MB::Sound::FastWavetable.cubic_interp(y_1, y0, y1, y2, 0.45)).to be_within(1e-7).of(MB::M.cubic_interp(y0, d0, y1, d1, 0.45))
      expect(MB::Sound::FastWavetable.cubic_interp(y_1, y0, y1, y2, 0.89)).to be_within(1e-7).of(MB::M.cubic_interp(y0, d0, y1, d1, 0.89))
    end
  end
end
