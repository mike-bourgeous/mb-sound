RSpec.describe(MB::Sound::Filter::Gain) do
  let(:f) { MB::Sound::Filter::Gain.new(2, sample_rate: 12345) }
  let(:f_complex) { MB::Sound::Filter::Gain.new(2i, sample_rate: 12345) }

  it 'can be constructed' do
    expect { f }.not_to raise_error
  end

  it 'multiplies by the gain factor' do
    expect(f.process(Numo::SFloat[1,2,3,4,5])).to eq(Numo::SFloat[2,4,6,8,10])
  end

  it 'can use a complex gain' do
    expect(f_complex.process(Numo::SFloat[1,2,3,4,5])).to eq(Numo::SComplex[2i,4i,6i,8i,10i])
  end
end
