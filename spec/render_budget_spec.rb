# The per-example render budget of unpaced NullOutputs
# (spec/support/render_budget.rb).
RSpec.describe(RenderBudget) do
  let(:buf) { [Numo::SFloat.zeros(48000)] } # one second

  before { allow(RenderBudget).to receive(:report?).and_return(false) } # (also under MB_SOUND_RENDER_BUDGET=report)

  it 'counts unpaced writes and raises past the default budget' do
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    RenderBudget::DEFAULT_SECONDS.times { out.write(buf) }
    expect(RenderBudget.used).to eq(RenderBudget::DEFAULT_SECONDS)
    expect { out.write(buf) }.to raise_error(RenderBudget::Exceeded, /rendered over 60 s .*realtime: false.*sleep: :virtual.*render_budget:/m)
    # The after hook would fail this example too; this one expects it
    expect(RenderBudget.finish).to be_a(RenderBudget::Exceeded)
  end

  it 'fails the example after a render thread rescued the raise' do
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    Thread.new { 61.times { out.write(buf) } rescue nil }.join
    expect(RenderBudget.finish).to be_a(RenderBudget::Exceeded)
  end

  it 'takes a larger budget with a reason', render_budget: { seconds: 120, reason: 'checks the override' } do
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    expect { 100.times { out.write(buf) } }.not_to raise_error
  end

  it 'refuses a budget without a reason' do
    ex = double(metadata: { render_budget: { seconds: 120 } }, location: './x_spec.rb:1')
    expect { RenderBudget.start(ex) }.to raise_error(ArgumentError, /reason/)
    expect { RenderBudget.start(double(metadata: { render_budget: 120 }, location: './x_spec.rb:2')) }.to raise_error(ArgumentError, /seconds:, reason:/)
  ensure
    RenderBudget.start(RSpec.current_example)
  end

  it 'leaves paced outputs alone' do
    out = MB::Sound::NullOutput.new(channels: 1, sample_rate: 48000 * 1000) # a second of samples is a millisecond here
    120.times { out.write(buf) }
    expect(RenderBudget.used).to eq(0)
  end
end
