RSpec.describe(MB::Sound::HaasPan) do
  it 'can be constructed' do
    expect { MB::Sound::HaasPan.new }.not_to raise_error
  end
end
