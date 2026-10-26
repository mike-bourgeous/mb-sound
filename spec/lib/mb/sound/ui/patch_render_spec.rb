require_relative '../../../../support/ui_helpers'

# The RENDER pane's offline renders (sound-design-ui-2): the debounce's
# states and timing, the driver's staleness rules, renders of a fresh
# patch instance that leave the live graph and the shared seeds alone,
# the worker thread, the pane, and Poll's source.
RSpec.describe(MB::Sound::UI::PatchRender, :aggregate_failures) do
  let(:pr) { MB::Sound::UI::PatchRender }
  let(:ui) { MB::Sound::UI }

  # A Session playing a dnb_reese bass on a knob and a graph track, with a
  # CaptureOutput (realtime: false).
  def bass_session
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
    s = MB::Sound::Session.new(output: out, realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.instance_eval do
        knob :cut, 2400.hz, range: 150.hz..8000.hz
        track(:bass) { |c| preset :dnb_reese, midi: c, cutoff: :cut }
        bg :bass, seq(MB::Sound::E1, MB::Sound::G1).n8.loop
        bg :pad, 220.hz.saw.at(-30.db)
      end
    end
    [s, out]
  end

  def source_of(s, name = :bass, patch: nil)
    tr = s.arrangement.tracks[name]
    t = s.transport
    pr::Source.new(track: name, patch: patch || tr&.patch, clip: tr&.clip, bpm: t.bpm, bar_length: t.bar_length, key: t.key, tuning: s.tuning,
                   channels: 2, sample_rate: 48000, note: nil)
  end

  def job_for(s, seq = 1, source: source_of(s), seconds: 1.0, knobs: nil)
    knobs ||= s.knobs.map { |n, k| [n, k.value, k.spec] }
    pr::Job.new(seq: seq, key: [source.track, seq].freeze, source: source, knobs: knobs, seconds: seconds, demo: false)
  end

  after do
    @session&.close
    @other&.close
    @driver&.close
    MB::Sound.rewind
  end

  describe MB::Sound::UI::PatchRender::Debounce do
    it 'has a transition for each state it reaches and refuses the rest' do
      expect(pr::Debounce::TABLE.keys.map(&:first).uniq.sort).to eq(pr::Debounce::STATES.sort)
      d = pr::Debounce.new
      expect { d.done }.to raise_error(ArgumentError, /no :done in state :idle/)
      expect(d.submit?(0.0)).to eq(false) # (idle: nothing to render)
    end

    it 'renders after DEBOUNCE of quiet, or every SWEEP while changes keep coming' do
      d = pr::Debounce.new
      d.change(0.0)
      expect(d.submit?(0.2)).to eq(false)
      expect(d.submit?(0.26)).to eq(true)
      expect(d.state).to eq(:busy)
      d.done
      expect(d.state).to eq(:idle)

      # A held sweep: a change every 50 ms renders at most every SWEEP
      starts = []
      busy_until = nil
      t = 10.0
      200.times do
        d.change(t)
        if busy_until && t >= busy_until
          d.done
          busy_until = nil
        end
        if d.submit?(t)
          starts << t
          busy_until = t + 0.1 # (each render takes 100 ms)
        end
        t += 0.05
      end
      gaps = starts.each_cons(2).map { |a, b| (b - a).round(3) }
      expect(starts.length).to be > 10
      expect(gaps.min).to be >= pr::SWEEP - 1e-9
      expect(gaps.max).to be <= pr::SWEEP + 0.1 + 0.05 + 1e-9
      expect(d.state).to eq(:dirty).or eq(:busy).or eq(:waiting)

      # Changes during a render come back as a waiting render after it
      e = pr::Debounce.new
      e.change(0.0)
      expect(e.submit?(0.0, urgent: true)).to eq(true)
      e.change(0.05)
      expect(e.state).to eq(:dirty)
      e.done
      expect(e.state).to eq(:waiting)
      expect(e.submit?(0.2)).to eq(false)
      expect(e.submit?(0.31)).to eq(true)
    end
  end

  describe MB::Sound::UI::PatchRender::Driver do
    # A Worker stand-in: keeps the jobs, finishes them when told.
    let(:fake) {
      Class.new {
        attr_reader :jobs
        def initialize = (@jobs = []; @result = nil; @busy = false)
        def submit(job) = (@jobs << job; @busy = true; self)
        def finish(**over)
          j = @jobs.last
          @result = MB::Sound::UI::PatchRender::Result.new(seq: j.seq, key: j.key, track: j.source.track, lo: nil, hi: nil, frames: 0, sample_rate: 48000,
                                                           peak: 0.0, rms: 0.0, lufs: 0.0, ms: 1.0, input: :clip, spectrum: nil, error: nil, **over)
          @busy = false
        end
        attr_reader :result
        def busy? = @busy
        def close = nil
      }.new
    }

    it 'renders the first time at once, then after the knobs it reads settle, dropping renders of a track no longer inspected' do
      now = 0.0
      @driver = pr::Driver.new(clock: -> { now }, worker: fake)
      src = ui_fake_render_source(:bass)
      cut = ui_knob_spec(:cut, 800.0, 100.0..8000.0, curve: :exp)
      knobs = ->(v) { [ui::KnobValue.new(name: :cut, value: v, spec: cut), ui::KnobValue.new(name: :other, value: v, spec: cut)].freeze }

      @driver.tick(src, knobs.(800.0), [:cut])
      expect(fake.jobs.length).to eq(1) # (nothing shown yet: at once)
      expect(@driver.state).to eq(:busy)
      fake.finish
      now += 0.1
      @driver.tick(src, knobs.(800.0), [:cut])
      expect(@driver.shown.seq).to eq(1)
      expect(@driver.pending?).to eq(false)

      # A knob the graph doesn't read changes nothing
      @driver.tick(src, [knobs.(800.0)[0], knobs.(5.0)[1]], [:cut])
      expect(@driver.state).to eq(:idle)

      # A turn waits for quiet
      now += 0.1
      @driver.tick(src, knobs.(1000.0), [:cut])
      now += 0.1
      @driver.tick(src, knobs.(1000.0), [:cut])
      expect(fake.jobs.length).to eq(1)
      now += 0.2
      @driver.tick(src, knobs.(1000.0), [:cut])
      expect(fake.jobs.length).to eq(2)
      expect(fake.jobs.last.knobs.assoc(:cut)[1]).to eq(1000.0)

      # The inspector moves to another track while it renders: its result
      # is dropped (stale), and the new track renders at once
      pad = ui_fake_render_source(:pad)
      @driver.tick(pad, knobs.(1000.0), [:cut])
      fake.finish
      @driver.tick(pad, knobs.(1000.0), [:cut])
      expect(@driver.shown.seq).to eq(1) # (job 2's bass render was dropped)
      expect(fake.jobs.last.source.track).to eq(:pad)
      fake.finish
      @driver.tick(pad, knobs.(1000.0), [:cut])
      expect(@driver.shown.track).to eq(:pad)
      expect(@driver.previous).to be_nil # (no overlay of another track's render)

      # again renders the same key once more
      n = fake.jobs.length
      @driver.again.tick(pad, knobs.(1000.0), [:cut])
      now += 0.3
      @driver.tick(pad, knobs.(1000.0), [:cut])
      expect(fake.jobs.length).to eq(n + 1)
    end
  end

  describe 'renders' do
    it 'renders a fresh instance of the patch with the knobs given, the same each time, without touching the live graph or the shared seeds' do
      MB::Sound.seed(0)
      @session, out = bass_session
      4.times { @session.process_buffer }
      MB::Sound.seed(0)
      @other, other_out = bass_session
      4.times { @other.process_buffer }

      shared = MB::Sound::Internal.root_rng.dup
      cache = {}.compare_by_identity
      a = pr.render(job_for(@session, 1), contained: cache)
      expect(a.error).to be_nil
      expect(a.input).to eq(:clip)
      expect(a.peak).to be_between(-30, 6)
      expect(a.lufs).to be_between(-40, 0)
      expect(a.lo.length).to eq(pr::ENVELOPE)
      expect(a.frames).to eq(48000)
      expect(a.spectrum[0].length).to eq(pr::SPECTRUM_POINTS)
      expect(cache.values.first.values).to eq([true]) # (self-contained, checked once)
      b = pr.render(job_for(@session, 2), contained: cache)
      expect(b.hi).to eq(a.hi) # (same seeds: renders differ only by what changed)
      knobs = @session.knobs.map { |n, k| [n, n == :cut ? 300.0 : k.value, k.spec] }
      c = pr.render(job_for(@session, 3, knobs: knobs), contained: cache)
      expect(c.hi).not_to eq(a.hi)
      highs = ->(r) { r.spectrum[1][r.spectrum[0].gt(2000)].mean }
      expect(highs.(c)).to be < highs.(a) - 6 # (the cutoff turned down)
      expect(@session.knobs[:cut].value).to be_within(1e-9).of(2400) # (the live knob)

      # The session that rendered three times plays on exactly as the one
      # that didn't, and the shared generator gave no draws
      expect(MB::Sound.next_seed).to eq(shared.rand(1 << 62))
      8.times do
        @session.process_buffer
        @other.process_buffer
      end
      expect(out.captured).to eq(other_out.captured)
    end

    it 'renders the demo phrase for a track without a clip or when asked, and says why it cannot render' do
      @session, = bass_session
      src = source_of(@session).with(clip: nil)
      r = pr.render(job_for(@session, source: src, seconds: 0.5))
      expect(r.input).to eq(:demo)
      expect(r.error).to be_nil

      shared = 110.hz.saw
      patch = ->(clip) { clip.env * shared }
      r = pr.render(job_for(@session, source: source_of(@session, patch: patch), seconds: 0.5))
      expect(r.error).to include('reads nodes made outside it')

      bad = ->(_clip) { 220.hz.sine.nonexistent_dsl_method }
      r = pr.render(job_for(@session, source: source_of(@session, patch: bad), seconds: 0.5))
      expect(r.error).to start_with('NoMethodError')

      r = pr.render(job_for(@session, source: source_of(@session).with(patch: nil, note: 'pad plays a graph'), seconds: 0.5))
      expect(r.error).to eq('pad plays a graph')
    end

    it 'renders on a low-priority worker thread that ends when idle' do
      stub_const('MB::Sound::UI::PatchRender::IDLE', 0.2)
      @session, = bass_session
      done = Queue.new
      w = pr::Worker.new { |r| done << r }
      w.submit(job_for(@session, 5, seconds: 0.25))
      thread = w.thread
      expect(thread.priority).to eq(-3)
      r = done.pop(timeout: 30)
      expect(r.seq).to eq(5)
      expect(w.result).to equal(r)
      expect(wait_until { !thread.alive? }).to eq(true)
      expect(w.thread).to be_nil
      w.submit(job_for(@session, 6, seconds: 0.25)) # (a new thread)
      expect(done.pop(timeout: 30).seq).to eq(6)
      w.close
      expect(w.thread).to be_nil
    end
  end

  describe 'the pane' do
    def draw(snap, state, w: 60, h: 10)
      grid = MB::Sound::Plot::Text::Cells.new(w, h)
      ui.panes.fetch(:render).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
      grid.to_text(:none).lines.map(&:rstrip)
    end

    it 'draws the waveform with its figures, the spectrum on s, and says why there is nothing to draw' do
      snap = ui_fake_snapshot
      now = 0.0
      st = { title_in_rule: true, driver: pr::Driver.new(clock: -> { now }) }
      text = draw(snap, st)
      @driver = st[:driver]
      expect(text[0]).to match(/\Abass  -\d+\.\d LUFS  peak -\d+\.\d  rms -\d+\.\d  3 s clip, 0 ms\z/)
      expect(text[1..].join("\n")).to include('time (s)')
      pane = ui.panes.fetch(:render)
      expect(pane.key_action(:view, st)).to eq('render: the spectrum')
      expect(draw(snap, st).join("\n")).to include('frequency', '1k')

      first = @driver.shown
      expect(pane.key_action(:phrase, st)).to include('demo phrase')
      draw(snap, st)
      now += 0.3
      text = draw(snap, st)
      expect(text[0]).to include('demo phrase')
      expect(@driver.shown.input).to eq(:demo)
      expect(@driver.previous).to equal(first) # (drawn faintly behind)

      expect(pane.key_action(:length, st, 1)).to include('4 s')
      expect(pane.key_action(:length, st, -1)).to include('3 s')
      expect(pane.key_action(:again, st)).to eq('render: again')

      none = snap.with(slow: snap.slow.with(render_source: nil))
      expect(draw(none, {})[0]).to include('RENDER')
      expect(draw(none, { title_in_rule: true })[0]).to include('nothing to render')
      graph = snap.with(slow: snap.slow.with(render_source: ui_fake_render_source.with(patch: nil, note: 'pad plays a graph, not a patch')))
      expect(draw(graph, { title_in_rule: true })[0]).to include('pad plays a graph')
    ensure
      pr.seconds = pr::SECONDS
    end

    it 'gets its source from Poll: the inspected track\'s patch and clip, or why a graph track has none' do
      @session, = bass_session
      4.times { @session.process_buffer }
      poll = ui::Poll.new(@session)
      ui::Inspect.target = { track: :bass, node: nil }
      expect(poll.call([:inspect]).first.render_source).to be_nil
      src = poll.call([:inspect, :render]).first.render_source
      expect(src.patch).to equal(@session.arrangement.tracks[:bass].patch)
      expect(src.clip).to equal(@session.arrangement.tracks[:bass].clip)
      expect(src.bpm).to eq(@session.transport.bpm)
      ui::Inspect.target = { track: :pad, node: nil }
      src = poll.call([:inspect, :render]).first.render_source
      expect(src.patch).to be_nil
      expect(src.note).to include('no patch to rebuild')
    ensure
      ui::Inspect.target = nil
      poll&.close
    end
  end
end
