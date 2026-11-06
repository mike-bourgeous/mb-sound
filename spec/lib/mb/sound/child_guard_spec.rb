# The child guard (spec/support/child_guard.rb, fix-batch-1106): which
# starter children it calls left running, and close_inputs.
RSpec.describe(ChildGuard, :aggregate_failures) do
  before { skip 'no process starter (MB_SOUND_STARTER=0)' unless MB::Sound::Starter.current }

  it 'names a child started after the snapshot and still running, and nothing once it ends' do
    before = described_class.snapshot
    child = MB::Sound::Starter.spawn('sleep', '30')
    left = described_class.leftovers(before, wait: 0.05)
    expect(left.map { |c| c[:argv] }).to eq([['sleep', '30']])
    expect(described_class.describe(left)).to match(/\A#\d+ pid \d+ sleep 30\z/)
    child.kill
    child.wait(5)
    expect(described_class.leftovers(before, wait: 1)).to eq([])
  end

  it 'leaves out children running before the snapshot (an earlier example named them)' do
    child = MB::Sound::Starter.spawn('sleep', '30')
    before = described_class.snapshot
    expect(described_class.leftovers(before, wait: 0)).to eq([])
  ensure
    child&.kill
    child&.wait(5)
  end

  it 'closes the file readers of a graph with close_inputs' do
    input = MB::Sound.file_input('sounds/sine/sine_100_1s_mono.flac')
    g = input.at(-6.db).filter(:lowpass, cutoff: 2000)
    g.sample(800)
    close_inputs(g)
    expect(input.closed?).to eq(true)
  end
end
