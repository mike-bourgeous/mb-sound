RSpec.describe(MB::Sound::Tee) do
  it 'can be created' do
    a, b = 123.hz.tee
    expect(a).to be_a(MB::Sound::Tee::Branch)
    expect(b).to be_a(MB::Sound::Tee::Branch)
  end

  it 'can create more than two branches' do
    branches = 123.hz.tee(5)
    expect(branches.length).to eq(5)
    expect(branches.all?(MB::Sound::Tee::Branch)).to eq(true)
  end
end
