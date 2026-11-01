require_relative '../../../../support/ui_helpers'

# One cycle of the picked oscillator (ux-notes-2, the maintainer's note 4
# and his "Render one cycle"): the oscillator alone, sampled in a copy of
# the voice from the note-on, so wavetables, FM, pwm, and sync are exact;
# renders off the drawing thread, kept by the voice, note, oscillator, and
# knob values; drawn in the preview pane.
RSpec.describe(MB::Sound::UI::ToneCycle, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:tc) { MB::Sound::UI::ToneCycle }
  let(:pr) { MB::Sound::UI::PatchRender }

  after do
    @session&.close
    @driver&.close
    ui::Inspect.target = nil
    pr.inline = true
    MB::Sound.rewind
  end

  def draw(name, snap, state = {}, w: 60, h: 12)
    grid = MB::Term::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  def lead_session
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2)
    @session = s = MB::Sound::Session.new(output: out, realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.instance_eval do
        track(:lead, :init)
        track(:saw) { |c| c.synth(voices: 2) { |v| (v.hz.saw + v.hz.transpose(7).square.pwm(0.3)).lp4(1200) * v.amp_env * 0.5 } }
        bg :lead, seq(MB::Sound::A2).n4.loop
        bg :saw, seq(MB::Sound::A2).n4.loop
      end
    end
    4.times { s.process_buffer }
    s
  end

  def source_of(s, name)
    poll = ui::Poll.new(s)
    ui::Inspect.target = { track: name, node: nil }
    poll.call([:inspect, :render]).first.render_source
  ensure
    poll&.close
  end

  def tones_of(src) = src.synth.instance_variable_get(:@lane_graphs)[0].grep(MB::Sound::Tone).uniq { |t| tc.key_of(t) }

  def knob_rows(s, **values)
    s.knobs.map { |n, k| [n, values.fetch(n, k.value), k.spec] }
  end

  def render(s, src, tone, seq: 1, cache: {}, **values)
    job = tc::Job.new(seq: seq, key: [seq], source: src, input: pr.input(src, 0.5), knobs: knob_rows(s, **values), tone: tc.key_of(tone))
    tc.render(job, cache: cache)
  end

  it 'renders exactly one period of the oscillator, from a settled phase, the same as a fresh one' do
    s = lead_session
    src = source_of(s, :saw)
    saw, square = tones_of(src)
    live_state = Marshal.dump(saw.plan_snapshot)
    r = render(s, src, saw)
    expect(r.error).to be_nil
    expect(r.frequency).to be_within(1e-9).of(110.0)
    expect(r.frames).to eq((48000 / 110.0).ceil + 1)
    # (a fresh 110 Hz saw's second period: the copy skips whole periods
    # past the note-on's phase reset)
    expect(r.cycle).to eq(110.hz.saw.sample(3 * r.frames)[436...(436 + r.frames)])

    # The pulse a fifth up, as its pwm made it
    q = render(s, src, square)
    expect(q.frequency).to be_within(1e-3).of(110.0 * 2**(7 / 12.0)) # (float32 frequencies)
    expect(q.cycle.gt(0).count.to_f / q.cycle.length).to be_within(0.05).of(0.3)

    # The live graph isn't touched
    expect(Marshal.dump(saw.plan_snapshot)).to eq(live_state)
    expect(saw.singleton_methods).to be_empty # (the frequency tap is on the copy's tone)
  end

  it 'follows the voice\'s knobs: the wavetable morph, FM, and sync (whose period is the master\'s)' do
    s = lead_session
    src = source_of(s, :lead)
    osc = tones_of(src).find { |t| tc.key_of(t)[-1] == 1 } # (OSC2: the one FM, sync, and tune2 move)
    sine = render(s, src, osc, "lead/wave2": 0.0)
    ideal = Numo::SFloat.cast(Numo::DFloat.new(sine.frames).seq.map { |i| Math.sin(2 * Math::PI * i * sine.frequency / 48000.0) })
    expect((sine.cycle / sine.cycle.abs.max - ideal).abs.max).to be < 0.02
    saw = render(s, src, osc, "lead/wave2": 1.0)
    expect((saw.cycle - sine.cycle).abs.max).to be > 0.5

    fm = render(s, src, osc, "lead/wave2": 0.0, "lead/fm": 2.0)
    expect((fm.cycle - sine.cycle).abs.max).to be > 0.3

    s.process_buffer
    MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"lead/sync", 1) }
    # (a build knob: the track rebuilds at its launch point, a bar here)
    osc = nil
    30.times do
      10.times { s.process_buffer }
      src = source_of(s, :lead)
      osc = tones_of(src).find { |t| tc.key_of(t)[-1] == 1 }
      break if osc.instance_variable_get(:@sync_source)
    end
    expect(osc.instance_variable_get(:@sync_source)).not_to be_nil
    synced = render(s, src, osc, "lead/tune2": 7.0)
    expect(synced.error).to be_nil
    expect(synced.synced).to eq(true)
    expect(synced.frequency).to be_within(1e-3).of(110.0) # (the master's: OSC1 at the note)
  end

  it 'says why for an oscillator outside the voice or a track without one' do
    s = lead_session
    src = source_of(s, :saw)
    job = tc::Job.new(seq: 1, key: [1], source: src, input: pr.input(src, 0.5), knobs: [], tone: nil)
    expect(tc.render(job).error).to match(/no recorded call/)
    job = job.with(tone: [:top, :synth, 0, :triangle, 3])
    expect(tc.render(job).error).to match(/outside the voice/)
    job = job.with(source: src.with(synth: nil, note: 'pad has no synth voice to copy'))
    expect(tc.render(job).error).to eq('pad has no synth voice to copy')
  end

  it 'renders again when a knob the voice reads moves, and not when it comes back to a value kept' do
    s = lead_session
    src = source_of(s, :lead)
    osc = tones_of(src).find { |t| tc.key_of(t)[-1] == 0 } # (OSC1, which wave1 morphs)
    jobs = []
    worker = Class.new {
      def initialize(jobs) = (@jobs = jobs)
      def submit(job) = (@jobs << job; @result = MB::Sound::UI::ToneCycle.render(job); self)
      attr_reader :result
      def busy? = false
      def close = nil
    }.new(jobs)
    t = 0.0
    @driver = tc::Driver.new(clock: -> { t }, worker: worker)
    knobs = ->(v) { s.knobs.map { |n, k| ui::KnobValue.new(name: n, value: n == :"lead/wave1" ? v : k.value, spec: k.spec) } }
    read = s.knobs.keys
    @driver.tick(src, tc.key_of(osc), knobs.(0.0), read)
    expect(jobs.length).to eq(1) # (nothing shown yet: at once)
    first = @driver.shown
    expect(first.error).to be_nil
    t += 1
    @driver.tick(src, tc.key_of(osc), knobs.(0.0), read)
    expect(jobs.length).to eq(1)

    @driver.tick(src, tc.key_of(osc), knobs.(1.0), read)
    expect(@driver.shown).to equal(first) # (the last one shown while the new one waits)
    expect(@driver.pending?).to eq(true)
    t += 1
    @driver.tick(src, tc.key_of(osc), knobs.(1.0), read)
    expect(jobs.length).to eq(2)
    expect(@driver.shown.cycle).not_to eq(first.cycle)
    expect(@driver.pending?).to eq(false)

    @driver.tick(src, tc.key_of(osc), knobs.(0.0), read)
    t += 1
    @driver.tick(src, tc.key_of(osc), knobs.(0.0), read)
    expect(jobs.length).to eq(2) # (kept)
    expect(@driver.shown).to equal(first)
    expect(@driver.pending?).to eq(false)
  end

  it 'renders on a low-priority worker thread, not the drawing thread' do
    s = lead_session
    src = source_of(s, :saw)
    pr.inline = false
    @driver = tc::Driver.new
    knobs = s.knobs.map { |n, k| ui::KnobValue.new(name: n, value: k.value, spec: k.spec) }
    key = tc.key_of(tones_of(src).first)
    @driver.tick(src, key, knobs, [])
    expect(@driver.worker).to be_a(pr::Worker)
    expect(wait_until { @driver.tick(src, key, knobs, []).shown }).not_to be_nil
    expect(@driver.shown.error).to be_nil
    expect(@driver.worker.thread&.priority).to be < 0 if @driver.worker.thread
  end

  it 'draws the cycle in the preview pane, titled with its frequency and length' do
    s = lead_session
    poll = ui::Poll.new(s)
    ui::Inspect.target = { track: :saw, node: nil }
    slow = poll.call([:inspect, :render]).first
    info = slow.inspector
    i = info.nodes.index { |n| n.label == 'saw' }
    ui::Inspect.target = { track: :saw, node: i }
    slow = poll.call([:inspect, :render]).first
    poll.close
    n = slow.inspector.selected
    expect(n.recipe_key).to eq([:top, :synth, 0, :saw, 0])
    snap = ui_fake_snapshot.with(slow: slow, knobs: s.knobs.map { |nm, k| ui::KnobValue.new(name: nm, value: k.value, spec: k.spec) }.freeze)
    text = draw(:preview, snap, {}, w: 60, h: 12).join("\n")
    expect(text).to include('saw 110 Hz  one cycle 9.1 ms  first note A2')
    expect(text).to match(/[⠁-⣿▀▄█]/)
  end
end
