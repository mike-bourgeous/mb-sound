RSpec.describe(MB::Sound::Filter::HilbertIIR, :aggregate_failures) do
  it 'can be constructed' do
    expect { MB::Sound::Filter::HilbertIIR.new }.not_to raise_error
  end

  it 'can process a signal' do
    result = MB::Sound::Filter::HilbertIIR.new.process(Numo::SFloat[1,2,3])
    expect(result.length).to eq(2)
    expect(result).to all(be_a(Numo::SFloat))
  end

  pending 'its magnitude response is approximately flat'

  # FIXME: phase difference deviates quite a bit above nyquist/2
  pending 'its phase difference is approximately flat'
end
