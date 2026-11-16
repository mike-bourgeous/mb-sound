require_relative '../../../../support/ui_helpers'

# The UI thread guard (spec/support/ui_thread_guard.rb, ui-perf-2 round 4):
# which threads it calls UI threads, which it calls left running, and its
# clean-up; and the screens' stop closing their panes' preview workers.
RSpec.describe(UIThreadGuard, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  it 'names a UI thread started after the snapshot and still running, and nothing once it ends' do
    before = Thread.list
    w = ui::ChartWorker.new
    w.send(:start)
    left = described_class.leftovers(before, wait: 0.05)
    expect(left).to eq([w.thread])
    expect(described_class.describe(left)).to match(/\A"mb-sound chart render" \(sleep at lib\/mb\/sound\/ui\/chart_worker\.rb:\d+/)
    w.close
    expect(described_class.leftovers(before, wait: 1)).to eq([])
  ensure
    w&.close
  end

  it 'tells UI threads by name or by a screen in their thread-locals, and leaves other threads out' do
    q = Queue.new
    names = ['MB::Sound::UI', 'MB::Sound::UI input', 'mb-sound patch render', 'MB::Term REPL', UIHelpers::FakeTerminal::READER_NAME, 'MB::Sound::Plan rebuilds', nil]
    threads = names.map { |n| Thread.new { Thread.current.name = n if n; q.pop } }
    marked = Thread.new { Thread.current[:mb_sound_ui_tiles] = :a_screen; q.pop }
    expect(wait_until { (threads + [marked]).all? { |t| t.status == 'sleep' } }).to eq(true)
    expect(threads.map { |t| described_class.ui_thread?(t) }).to eq([true, true, true, true, true, false, false])
    expect(described_class.ui_thread?(marked)).to eq(true)
  ensure
    (threads.to_a + [marked]).compact.each { q << nil }
    (threads.to_a + [marked]).compact.each(&:join)
  end

  it 'stops a screen left running and kills what is left' do
    require 'pty'
    master, slave = PTY.open
    slave.winsize = [30, 100]
    before = Thread.list
    t = ui::Tiles.new(layout: ui.tiles_layout_named(:tiles), input: slave, output: slave, repl: :none, probe: false,
                      keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    t.start
    # (the threads name themselves as they start)
    expect(wait_until { described_class.leftovers(before, wait: 0).length == 2 }).to eq(true)
    left = described_class.leftovers(before, wait: 0)
    expect(left.map(&:name)).to contain_exactly('MB::Sound::UI', 'MB::Sound::UI input')
    described_class.clean_up(left)
    expect(t.active?).to eq(false)
    expect(left.none?(&:alive?)).to eq(true)
  ensure
    t&.stop
    [master, slave].each { |io| io&.close rescue nil }
  end

  it 'has the tiled screen close its panes\' preview workers when it stops' do
    was = ui::PatchRender.inline
    ui::PatchRender.inline = false
    tiles, term = ui_tiles(:tiles)
    expect(term.wait_for('t> ')).to eq(true)
    state = tiles.pane_state(:transport) || tiles.instance_variable_get(:@states)[:transport]
    cw = state[:chart_worker] = ui::ChartWorker.new
    driver = state[:driver] = ui::PatchRender::Driver.new
    cw.send(:start)
    driver.worker.send(:start)
    threads = [cw.thread, driver.worker.thread]
    expect(threads.all?(&:alive?)).to eq(true)
    tiles.stop
    expect(threads.none?(&:alive?)).to eq(true)
    expect(state.key?(:chart_worker) || state.key?(:driver)).to eq(false) # (a started-again screen makes new ones)
  ensure
    tiles&.stop
    term&.close
    ui::PatchRender.inline = was
  end

  it 'has the band close its panes\' preview workers when it stops' do
    band, = ui_fake_band(:deck)
    band.start(thread: false)
    state = band.placed.first.state
    cw = state[:chart_worker] = ui::ChartWorker.new
    cw.send(:start)
    t = cw.thread
    band.stop
    expect(t.alive?).to eq(false)
    expect(state.key?(:chart_worker)).to eq(false)
  ensure
    band&.stop
  end
end
