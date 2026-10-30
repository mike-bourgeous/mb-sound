RSpec.describe(MB::Sound::GraphNode::Dynamics::SimpleEnvelopeFollower) do
  it 'rises instantly to each peak and falls by decay_db every decay_s seconds' do
    f = described_class.new(sample_rate: 1000, decay_db: -6.0, decay_s: 0.1)
    out = f.process(Numo::DFloat[0.5, -1.0] .concatenate(Numo::DFloat.zeros(100)))
    expect(out[0]).to eq(0.5)
    expect(out[1]).to eq(1.0) # (the absolute value)
    expect(out[101]).to be_within(1e-9).of(-6.0.db.to_f)
    expect(out[51]).to be_within(1e-9).of(-3.0.db.to_f)
  end

  it 'reads Decibels decays and resets' do
    f = described_class.new(sample_rate: 48000, decay_db: -12.db)
    expect(f.decay_db).to eq(-12.0)
    f.process(Numo::DFloat[1.0])
    f.reset
    expect(f.process(Numo::DFloat[0.0])[0]).to eq(0.0)
  end
end
