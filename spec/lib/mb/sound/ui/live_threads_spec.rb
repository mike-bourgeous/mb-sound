require_relative '../../../../support/ui_helpers'

# The live-threads guard (ui-perf-2): with a live Session playing and a
# screen up (the tiles, then the sound-design screen on a designed track),
# every Ruby thread the screen and the Session started is the render thread,
# a yielder (FastUI::GVLYield: it hands the GVL to the render thread the
# moment that wakes; UI::Yielding), or listed in ALLOWED with the reason it
# may hold the GVL without yielding.  A new thread on a live path (a worker,
# a poll, a probe) fails here until it joins the yielders or gets a reason.
# The table of threads is in design/notes/terminal_ui.md ("Threads of a
# live screen").
RSpec.describe('live threads with a screen up', :aggregate_failures) do
  # Thread names allowed not to yield, with why.
  ALLOWED_LIVE_THREADS = {
    'MB::Term pty' => 'blocks in read; feeds the console pty\'s bytes to the C VT in short calls (mb-term)',
    'MB::Term REPL' => 'the console\'s own Pry thread: the maintainer\'s lines run there (question 8: yielding it is his call)',
    'MB::Term command' => 'waits for a command child (ReplHost :command mode); never runs Ruby work',
    'mb-sound-warm-wait' => 'joins a warming worker (the worker itself yields); never runs Ruby work',
    'MB::Sound::UI keys' => 'one short take-over of the inspected keys at screen start, then ends',
    'MB::Sound::UI perf capture' => 'ui.perf :capture: sleeps between scripted keys (a diagnostic the maintainer starts)',
  }.freeze

  around do |ex|
    # (preview workers on their threads, as live; specs render inline)
    was = MB::Sound::UI::PatchRender.inline
    MB::Sound::UI::PatchRender.inline = false
    ex.run
  ensure
    MB::Sound::UI::PatchRender.inline = was
  end

  after do
    @tiles&.stop
    @term&.close
    @pump&.kill&.join
    @session&.close
    MB::Sound::UI::Inspect.target = nil
    MB::Sound.rewind
  end

  # Threads started since +base+, sampled every 20 ms for +seconds+: each
  # one neither the render thread nor a yielder nor allowed, with where it
  # was made.  A thread counts when two samples in a row see it so: a
  # worker joins the yielders in its first lines (ChartWorker#run), and a
  # loaded machine once let one sample land before that (the chart
  # worker, seed 47008 of the UI directory, 2026-11-18).
  def stragglers(base, seconds)
    gy = MB::Sound::FastUI::GVLYield
    found = {}
    seen = {}.compare_by_identity
    t0 = MB::U.clock_now
    while MB::U.clock_now - t0 < seconds
      yielders = gy.yielders
      # (yielders that follow another thread, or none, yield to nobody:
      # a new Session's render thread was followed only once a painter's
      # frame saw it; fixes-19)
      if !yielders.empty? && @session.render_thread&.alive? && !gy.priority.equal?(@session.render_thread)
        found['(GVLYield.priority is not the render thread)'] ||= gy.priority.inspect
      end
      now = {}.compare_by_identity
      (Thread.list - base - [@pump]).each do |t|
        next if t.equal?(@session.render_thread) || yielders.include?(t) || ALLOWED_LIVE_THREADS.key?(t.name.to_s)
        next if t.inspect.include?('/spec/') # (the spec's own: the fake terminal's reader)
        next unless t.alive?

        now[t] = true
        found[t.name.to_s] ||= t.inspect[%r{/\S+:\d+}] if seen.key?(t)
      end
      seen = now
      sleep 0.02
    end
    found
  end

  it 'starts no thread that holds the GVL without yielding to the render thread (tiles, then the sound screen)' do
    skip 'needs FastUI::GVLYield' unless MB::Sound::UI::Yielding.available?

    base = Thread.list
    out = MB::Sound::NullOutput.new(channels: 2, sleep: :virtual, buffer_size: 256)
    @session = MB::Sound::Session.new(output: out, realtime: true)
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.module_eval('track :bass, L.inst.acid; bg :bass, seq(E1, E1, G1, A1).n8.loop.legato(0.5)')
    end
    @session.schedule(0) {} # (the scheduler thread)
    # (the virtual clock: 20 ms of audio every 10 ms of wall time)
    @pump = Thread.new { loop { out.consume(0.02); sleep 0.01 } }
    expect(wait_until { @session.running? }).to eq(true)

    @tiles, @term = ui_tiles(:tiles, session: @session)
    expect(@term.wait_for('t> ')).to eq(true)
    # (the painter joins once it follows the render thread)
    expect(wait_until { MB::Sound::FastUI::GVLYield.yielders.include?(@tiles.thread) }).to eq(true)
    tiles = stragglers(base, 0.6)
    expect(Thread.list.map { |t| t.name.to_s }).to include('MB::Sound::Session scheduler', 'MB::Sound::UI input')
    @tiles.stop
    @term.close

    MB::Sound::UI::Inspect.target = { track: :bass }.freeze
    @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, session: @session)
    expect(@term.wait_for('diode')).to eq(true), @term.text # (the inspector shows the acid voice)
    expect(wait_until { Thread.list.any? { |t| t.name.to_s.match?(/\Amb-sound .* render\z/) } }).to eq(true), Thread.list.map(&:name).inspect # (a preview worker)
    sound = stragglers(base, 1.0)

    expect(tiles).to eq({}), "threads on the tiles that neither yield nor have a reason in ALLOWED_LIVE_THREADS: #{tiles.inspect}"
    expect(sound).to eq({}), "threads on the sound screen that neither yield nor have a reason in ALLOWED_LIVE_THREADS: #{sound.inspect}"
  end
end
