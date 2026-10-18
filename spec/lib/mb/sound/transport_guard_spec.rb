# The transport guard (spec/support/transport_guard.rb, ux-r4 item 4):
# what it reports as moved, and that the default transport starts each
# example at rest.
RSpec.describe(TransportGuard, :aggregate_failures) do
  let(:t) { MB::Sound::Sequence.transport }

  after do
    t.seek(0)
    t.bpm = 120
    t.meter(1, at: 0)
  end

  it 'finds nothing moved at the start of an example' do
    expect(described_class.moved).to be_nil
    expect(described_class.mode).to eq(ENV.fetch('MB_SOUND_TRANSPORT_CHECK', 'fail'))
  end

  it 'names the position, tempo, and meter left moved' do
    t.seek(3r / 2)
    t.bpm = 126
    expect(described_class.moved).to eq('position 3/2, bpm 126')
    t.seek(0)
    t.bpm = 120
    t.meter(7r / 8, at: 0)
    expect(described_class.moved).to start_with('meter ')
  end
end
