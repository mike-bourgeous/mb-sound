RSpec.describe(MB::Sound::Session::Undo) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v.round(4)] }
  end

  it 'undoes a replacement at the next bar, bringing back the same graph with a declick crossfade' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    old = session.instance_variable_get(:@players).values.first.input
    within { MB::Sound.bg(:x, 2.constant, at: :now) }
    run(800)

    step = within { MB::Sound.undo }
    expect(step.to_s).to eq('undo bg :x lands 2:1')
    data = run(96000)
    bar = 96000 - 1600
    expect(data[bar - 1]).to eq(2)
    expect(data[bar + 120]).to be_within(1e-6).of(1.5)
    expect(data[bar + 240]).to eq(1)
    expect(session.instance_variable_get(:@players).values.map(&:input)).to eq([old])
  end

  it 'undoes right away with at: :now, and redoes' do
    within { MB::Sound.bg(:x, 1.constant) }
    within { MB::Sound.bg(:x, 2.constant, at: :now) }
    run(800)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)

    step = within { MB::Sound.redo!(at: :now) }
    expect(step.label).to eq('bg :x')
    expect(run(1600)[-1]).to eq(2)
    expect(session.undo_steps.map(&:label)).to eq(['bg :x', 'bg :x'])
    expect(session.redo_steps).to eq([])
  end

  it 'cancels a change that has not landed yet, and redo queues it again' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    within { MB::Sound.bg(:x, 2.constant) } # next bar
    expect(session.queued(:x).length).to eq(1)

    step = within { MB::Sound.undo }
    expect(step.to_s).to eq('undo bg :x (cancelled)')
    expect(session.queued(:x)).to eq([])
    expect(session.journal.changes.map(&:status)).to include(:cancelled)

    within { MB::Sound.redo! }
    data = run(96000 * 2)
    expect(changes(data)).to eq([[0, 1], [96000 - 800, 2]])
  end

  it 'undoes a stop by resuming the stopped graph' do
    within { MB::Sound.bg(:x, 1.constant) }
    run(800)
    within { MB::Sound.stop(:x, fade: 0) }
    expect(run(800).to_a.uniq).to eq([0])
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
    expect(session.stopped).to eq({})
  end

  it 'undoes swaps, putting the old clips back' do
    a = MB::Sound.seq(MB::Sound::C3).n1.loop
    b = MB::Sound.seq(MB::Sound::D3).n1.loop
    within { MB::Sound.bg(:n, a.number) }
    within { MB::Sound.swap(:n, b, at: :now) }
    expect(run(1600)[-1]).to eq(50)
    within { MB::Sound.undo }
    data = run(96000)
    expect(changes(data)).to eq([[0, 50], [96000 - 1600, 48]])
  end

  it 'undoes mutes and solos' do
    within { MB::Sound.bg(:x, 1.constant); MB::Sound.bg(:y, 2.constant) }
    within { MB::Sound.solo(:x) }
    expect(run(1600)[-1]).to eq(1)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(3)
    expect(session.strip_info[:soloed]).to eq([])
  end

  it 'undoes master effects by rebuilding the old chain from its block' do
    within { MB::Sound.bg(:x, 1.constant) }
    within { MB::Sound.master(at: :now) { |m| m * 2 } }
    within { MB::Sound.master(at: :now) { |m| m * 3 } }
    expect(run(1600)[-1]).to eq(3)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(2)
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
  end

  it 'undoes a scene launch as one step, restoring the set state' do
    set = session.arrangement
    a1 = MB::Sound.seq(MB::Sound::C3).n1.loop
    a2 = MB::Sound.seq(MB::Sound::D3).n1.loop
    set.track(:a) { |c| c.number }
    set.track(:b) { |c| c.number * 100 }
    set.scene(:one, a: a1)
    set.scene(:two, a: a2, b: a1)
    within { MB::Sound.go(:one, at: :now) }
    run(800)
    within { MB::Sound.go(:two, at: :now) }
    expect(run(1600)[-1]).to eq(50 + 4800)

    within { expect(MB::Sound.changes).to eq(['1. go :one lands 1:1', '2. go :two lands 1:1.033']) }
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(48)
    expect(set.current_scene).to eq(:one)
    expect(set.tracks[:a].clip).to equal(a1)
  end

  it 'groups the commands of a scheduled block into one step' do
    within do
      MB::Sound.bg(:x, 1.constant)
      MB::Sound.at_bar(2) { MB::Sound.bg(:y, 2.constant); MB::Sound.bg(:z, 4.constant) }
    end
    run(96000 + 800)
    expect(session.undo_steps.map(&:label)).to eq(['bg :x', 'bar 2'])
    within { MB::Sound.undo(at: :now) }
    expect(run(1600)[-1]).to eq(1)
  end

  it 'drops the oldest steps when they keep too many retired graphs alive' do
    stub_const('MB::Sound::Session::Undo::RETIRED_GRAPH_LIMIT', 3)
    within do
      MB::Sound.bg(:x, 0.constant)
      6.times { |i| MB::Sound.bg(:x, (i + 1).constant, at: :now) }
    end
    run(800)
    expect(session.retired_graphs.length).to be <= 3
    expect(session.undo_steps.length).to eq(3)
  end
end
