RSpec.describe(MB::Sound::Filter::EnvelopeFollower) do
  it 'can be constructed' do
    expect { MB::Sound::Filter::EnvelopeFollower.new(rate: 48000) }.not_to raise_error
  end

  pending 'more tests'
end
