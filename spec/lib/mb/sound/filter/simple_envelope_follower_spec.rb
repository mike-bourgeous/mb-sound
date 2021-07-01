RSpec.describe(MB::Sound::Filter::SimpleEnvelopeFollower) do
  it 'can be constructed' do
    expect { MB::Sound::Filter::SimpleEnvelopeFollower.new(rate: 48000) }.not_to raise_error
  end

  pending 'more tests'
end
