RSpec.describe(MB::Sound::Constant) do
  it 'returns a constant value forever' do
    expect(MB::Sound::Constant.new(123).sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))
  end

  it 'can use a complex constant' do
    expect(MB::Sound::Constant.new(123+45i).sample(480)).to eq(Numo::SComplex.zeros(480).fill(123+45i))
  end

  it 'can change to a complex constant' do
    c = MB::Sound::Constant.new(123)
    expect(c.sample(480)).to eq(Numo::SFloat.zeros(480).fill(123))

    c.constant = 1+1i
    expect(c.sample(480)).to eq(Numo::SComplex.zeros(480).fill(1+1i))
  end
end
