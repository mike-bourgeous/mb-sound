require_relative '../../../../support/ui_helpers'

# The RENDER pane's previews (sound-design-ui-2, round 3: two copies): the
# debounce's states and timing, the driver's staleness rules, a second copy
# of one voice rendered from a reset state (knob turns without a rebuild)
# that leaves the live graph and the shared seeds alone, the cycle
# extraction (settling, zero crossings, unison), the rate choice, the
# worker thread, the pane, and Poll's source.
RSpec.describe(MB::Sound::UI::PatchRender, :aggregate_failures) do
  let(:pr) { MB::Sound::UI::PatchRender }
  let(:ui) { MB::Sound::UI }

  # A Session playing a dnb_reese bass on a knob, a plain saw synth and a
  # detuned unison synth reading the same knob, and a graph track, with a
  # CaptureOutput (realtime: false).
  def bass_session
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
    s = MB::Sound::Session.new(output: out, realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.instance_eval do
        knob :cut, 2400.hz, range: 150.hz..8000.hz
        track(:bass) { |c| preset :dnb_reese, midi: c, cutoff: :cut }
        track(:saw) { |c| c.synth(voices: 2) { |v| v.hz.saw.lp4(knob(:cut), resonance: 0.3) * v.amp_env * 0.5 } }
        track(:uni) { |c| c.synth(voices: 2) { |v| v.hz.unison(5, detune: 0.3) { |p, _i| p.saw }.lp4(knob(:cut)) * v.amp_env * 0.3 } }
        bg :bass, seq(MB::Sound::E1, MB::Sound::G1).n8.loop
        bg :saw, seq(MB::Sound::A2).n4.loop
        bg :uni, seq(MB::Sound::C3).n4.loop
        bg :pad, 220.hz.saw.at(-30.db)
      end
    end
    4.times { s.process_buffer }
    [s, out]
  end

  # The inspected track's Source as Poll gathers it.
  def source_of(s, name = :bass)
    poll = ui::Poll.new(s)
    ui::Inspect.target = { track: name, node: nil }
    poll.call([:inspect, :render]).first.render_source
  ensure
    ui::Inspect.target = nil
    poll&.close
  end

  def job_for(s, seq = 1, source: source_of(s), seconds: 0.5, knobs: nil, input: nil)
    knobs ||= s.knobs.map { |n, k| [n, k.value, k.spec] }
    input ||= pr.input(source, seconds)
    pr::Job.new(seq: seq, key: [source.track, seq].freeze, source: source, input: input, knobs: knobs, seconds: seconds)
  end

  after do
    @session&.close
    @other&.close
    @driver&.close
    @cache&.[](:copy)&.close
    pr.rate = nil
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
      q = pr::DEBOUNCE
      d.change(0.0)
      expect(d.submit?(q * 0.8)).to eq(false)
      expect(d.submit?(q * 1.05)).to eq(true)
      expect(d.state).to eq(:busy)
      d.done
      expect(d.state).to eq(:idle)

      # A held sweep: a change every 50 ms renders at most every SWEEP
      # (each render taking 100 ms)
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
      expect(e.submit?(0.05 + q * 0.8)).to eq(false)
      expect(e.submit?(0.05 + q * 1.05)).to eq(true)
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
          @result = MB::Sound::UI::PatchRender::Result.new(seq: j.seq, key: j.key, track: j.source.track, lo: nil, hi: nil, frames: 0,
                                                           peak: 0.0, rms: 0.0, lufs: 0.0, ms: 1.0, input: 'x', spectrum: nil, error: nil, cycle: nil, periods: nil, settled: nil, frequency: nil, rate: 48000, **over)
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
      now += 1
      @driver.tick(src, knobs.(1000.0), [:cut])
      now += pr::DEBOUNCE * 0.6
      @driver.tick(src, knobs.(1000.0), [:cut])
      expect(fake.jobs.length).to eq(1)
      now += pr::DEBOUNCE * 0.6
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
    it 'renders a second copy of one voice from a reset state, the same each time, turning knobs without a rebuild, leaving the live graph and the shared seeds alone' do
      MB::Sound.seed(0)
      @session, out = bass_session
      MB::Sound.seed(0)
      @other, other_out = bass_session

      shared = MB::Sound::Internal.root_rng.dup
      @cache = {}
      src = source_of(@session)
      expect(src.synth).to be_a(MB::Sound::Synth)
      a = pr.render(job_for(@session, 1, source: src), cache: @cache)
      expect(a.error).to be_nil
      expect(a.input).to eq('first note E1')
      expect(a.rate).to eq(48000) # (dnb_reese's cutoff moves with an LFO)
      expect(a.peak).to be_between(-30, 6)
      expect(a.lo.length).to eq(pr::ENVELOPE)
      expect(a.frames).to eq(24000)
      expect(a.spectrum[0].length).to eq(pr::SPECTRUM_POINTS)
      expect(a.periods).to eq(pr::UNISON_PERIODS) # (a detuned reese never repeats a period)
      copy = @cache[:copy]
      b = pr.render(job_for(@session, 2, source: src), cache: @cache)
      expect([b.hi, b.cycle]).to eq([a.hi, a.cycle]) # (every render from the same reset state)
      knobs = @session.knobs.map { |n, k| [n, n == :cut ? 300.0 : k.value, k.spec] }
      c = pr.render(job_for(@session, 3, source: src, knobs: knobs), cache: @cache)
      expect(@cache[:copy]).to equal(copy) # (a knob turn: no rebuild)
      expect(c.hi).not_to eq(a.hi)
      highs = ->(r) { r.spectrum[1][r.spectrum[0].gt(2000)].mean }
      expect(highs.(c)).to be < highs.(a) - 6 # (the cutoff turned down)
      d = pr.render(job_for(@session, 4, source: src), cache: @cache)
      expect(d.hi).to eq(a.hi) # (and back)
      expect(@session.knobs[:cut].value).to be_within(1e-9).of(2400) # (the live knob)
      guess = pr.render(job_for(@session, 5, source: src, input: pr.input(src, 0.5, guess: true)), cache: @cache)
      expect(guess.input).to eq('bass guess A1')
      expect(@cache[:copy]).not_to equal(copy) # (another note: a new copy)

      # The session that previewed plays on exactly as the one that didn't,
      # and the shared generator gave no draws
      expect(MB::Sound.next_seed).to eq(shared.rand(1 << 62))
      8.times do
        @session.process_buffer
        @other.process_buffer
      end
      expect(out.captured).to eq(other_out.captured)
    end

    it 'shows one settled cycle from a rising zero crossing, or a few cycles when detuned copies never repeat' do
      @session, = bass_session
      @cache = {}
      saw = pr.render(job_for(@session, source: source_of(@session, :saw)), cache: @cache)
      expect(saw.error).to be_nil
      expect(saw.periods).to eq(1)
      expect(saw.settled).to be_between(0.0, pr::SETTLE_MAX)
      period = saw.rate / saw.frequency
      expect(saw.cycle[0].length).to be_within(1).of(period)
      mix = saw.cycle.map { |d| Numo::DFloat.cast(d) }.sum / saw.cycle.length
      expect(mix[0].abs).to be < mix.abs.max * 0.1 # (from a zero crossing)
      expect(mix[1]).to be > mix[0] # (rising)
      @cache[:copy].close
      @cache = {}
      uni = pr.render(job_for(@session, source: source_of(@session, :uni)), cache: @cache)
      expect([uni.periods, uni.settled]).to eq([pr::UNISON_PERIODS, nil])
      expect(uni.cycle[0].length).to be_within(2).of(pr::UNISON_PERIODS * uni.rate / uni.frequency)

      # On data: a sine settling from a decaying offset settles; two
      # detuned sines never do
      rate = 24000
      t = Numo::DFloat.new(rate / 2).seq / rate
      settling = Numo::SFloat.cast(Numo::NMath.sin(2 * Math::PI * 100 * t + 1.0) + 0.5 * Numo::NMath.exp(-t / 0.02))
      cyc, periods, settled = pr.cycle([settling], rate, 100.0)
      expect(periods).to eq(1)
      expect(settled).to be_between(0.05, 0.2) # (several time constants)
      expect(cyc[0].length).to eq(240)
      expect(cyc[0][0].abs).to be < 0.03
      expect(cyc[0][1]).to be > cyc[0][0]
      beat = Numo::SFloat.cast(Numo::NMath.sin(2 * Math::PI * 100 * t) + Numo::NMath.sin(2 * Math::PI * 103 * t))
      cyc, periods, settled = pr.cycle([beat], rate, 100.0)
      expect([periods, settled]).to eq([pr::UNISON_PERIODS, nil])
      expect(cyc[0].length).to eq(960)
    end

    it 'runs a copy at the lowest rate that keeps its lowpass cutoffs under an eighth of it, else 48 kHz' do
      expect(pr.rate_for([])).to eq(48000) # (nothing limits the content)
      expect(pr.rate_for([1200.0, nil])).to eq(48000) # (a cutoff that moves)
      expect(pr.rate_for([1200.0])).to eq(24000) # (no lower than 24 kHz)
      expect(pr.rate_for([1500.0, 900.0])).to eq(24000)
      expect(pr.rate_for([2400.0])).to eq(24000)
      expect(pr.rate_for([3500.0])).to eq(32000)
      expect(pr.rate_for([7000.0])).to eq(48000)
      @session, = bass_session
      @cache = {}
      src = source_of(@session, :saw)
      low = pr.render(job_for(@session, source: src), cache: @cache)
      expect(low.rate).to eq(24000) # (cut at 2400 Hz)
      pr.rate = 48000
      @cache[:copy].close
      @cache = {}
      full = pr.render(job_for(@session, source: src), cache: @cache)
      expect(full.rate).to eq(48000)
      expect(low.rms).to be_within(0.5).of(full.rms)
      expect(low.cycle[0].length * 2).to be_within(2).of(full.cycle[0].length)
    end

    it 'plays the clip\'s first note or a note guessed from the role, and says why it cannot preview' do
      @session, = bass_session
      src = source_of(@session)
      clip = MB::Sound.seq(MB::Sound::Rest, (!MB::Sound::C3).n4, MB::Sound::E3).n8
      inp = pr.input(src.with(clip: clip), 0.5)
      expect([inp.kind, inp.note, inp.hold, inp.text]).to eq([:clip_note, 48, 0.5r, 'first note C3']) # (a quarter at 120 bpm)
      expect(pr.input(src.with(clip: clip), 0.5).id).to eq(inp.id)
      roles = {
        'bass' => [:bass, 33], 'dnb_reese' => [:bass, 33], 'warm pad' => [:pad, 48], 'lead' => [:lead, 67], 'keys' => [:pluck, 60],
        'kick' => [:kick, 36], 'mystery' => [:default, 48],
      }
      roles.each do |words, (role, note)|
        g = pr.input(src.with(clip: nil, words: words), 0.5)
        expect([g.kind, g.role, g.note]).to eq([:guess, role, note]), words
      end
      r = pr.render(job_for(@session, source: src.with(clip: nil)))
      expect(r.error).to be_nil
      expect(r.input).to eq('bass guess A1')

      shared = 110.hz.saw
      syn = MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::C3).n4.notes, voices: 1) { |v| shared * v.amp_env }
      r = pr.render(job_for(@session, source: src.with(synth: syn, live: syn.graph.to_h { |n| [n.__id__, true] })))
      expect(r.error).to include('reads nodes made outside it')

      pad = source_of(@session, :pad)
      expect(pad.synth).to be_nil
      r = pr.render(job_for(@session, source: pad))
      expect(r.error).to include('no synth voice to copy')
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

    it 'draws the settled cycle above the spectrum above the envelope (as many as fit; side by side in a wide, short pane) with the figures, and says why there is nothing to draw' do
      snap = ui_fake_snapshot
      now = 0.0
      st = { title_in_rule: true, driver: pr::Driver.new(clock: -> { now }) }
      text = draw(snap, st, w: 90, h: 18)
      @driver = st[:driver]
      expect(text[0]).to match(/\Abass  -\d+\.\d LUFS  peak -\d+\.\d  rms -\d+\.\d  first note C3, settled \d+ ms, 24 kHz, 0 ms\z/)
      body = text[1..].join("\n")
      expect(body).to include(' ms', 'frequency', 'time (')
      expect(body.index('frequency')).to be < body.index('time (') # (the cycle, the spectrum, then the envelope)
      wide = draw(snap, { title_in_rule: true, driver: st[:driver] }, w: 100, h: 9)
      expect(wide.find { |l| l.include?('frequency') }).to include('ms') # (side by side)
      small = draw(snap, { title_in_rule: true, driver: st[:driver] }, h: 9).join("\n")
      expect(small).not_to include('frequency')
      pane = ui.panes.fetch(:render)
      expect(pane.key_action(:view, st)).to include('settled cycle')
      expect(pane.key_action(:view, st)).to include('envelope')
      expect(draw(snap, st, h: 9).join("\n")).to include('time (')
      expect(pane.key_action(:view, st)).to include('spectrum')
      expect(draw(snap, st, h: 9).join("\n")).to include('frequency')

      first = @driver.shown
      expect(pane.key_action(:phrase, st)).to include('guessed note')
      draw(snap, st)
      now += 0.3
      text = draw(snap, st)
      expect(text[0]).to include('bass guess A1')
      expect(@driver.previous).to equal(first) # (drawn faintly behind)

      expect(pane.key_action(:length, st, 1)).to include('0.75 s')
      expect(pane.key_action(:length, st, -1)).to include('0.5 s')
      expect(pane.key_action(:again, st)).to eq('render: again')

      none = snap.with(slow: snap.slow.with(render_source: nil))
      expect(draw(none, {})[0]).to include('RENDER')
      expect(draw(none, { title_in_rule: true })[0]).to include('nothing to render')
      graph = snap.with(slow: snap.slow.with(render_source: ui_fake_render_source.with(synth: nil, note: 'pad has no synth voice to copy')))
      expect(draw(graph, { title_in_rule: true })[0]).to include('pad has no synth voice')
    ensure
      pr.seconds = pr::SECONDS
    end

    it 'gets its source from Poll: the Synth in the inspected graph, the live nodes, and the clip, or why a graph track has none' do
      @session, = bass_session
      poll = ui::Poll.new(@session)
      ui::Inspect.target = { track: :bass, node: nil }
      expect(poll.call([:inspect]).first.render_source).to be_nil
      src = poll.call([:inspect, :render]).first.render_source
      graph = ui::Inspect.roots(@session.ui_graphs[:bass]).flat_map { |r| [r, *r.graph] }
      expect(src.synth).to equal(graph.find { |n| n.is_a?(MB::Sound::Synth) })
      expect(src.synth.voice_block).to be_a(Proc)
      expect(src.live.length).to be > 20
      expect(src.clip).to equal(@session.arrangement.tracks[:bass].clip)
      expect(src.bpm).to eq(@session.transport.bpm)
      expect(src.words).to include('bass', 'synth(')
      expect(poll.call([:inspect, :render]).first.render_source.live).to equal(src.live) # (walked once per graph)
      ui::Inspect.target = { track: :pad, node: nil }
      src = poll.call([:inspect, :render]).first.render_source
      expect(src.synth).to be_nil
      expect(src.note).to include('no synth voice to copy')
    ensure
      ui::Inspect.target = nil
      poll&.close
    end
  end
end
