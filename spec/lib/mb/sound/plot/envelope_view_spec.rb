require_relative '../../../../support/ui_helpers'

# The envelope preview (envelope-view-1): Envelope#preview_data and
# #param_info, the copy rendered at a low rate with the sustain as a fixed
# share, breakpoint labels, the velocity trace, the playhead (from the
# inspector's poll, moved on by the clock), and the time axis's
# divisions title.
RSpec.describe(MB::Sound::Plot::Panels::EnvelopeView, :aggregate_failures) do
  let(:view) { described_class }

  def chart_of(env, live: nil)
    b = MB::Sound::Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
    expect(MB::Sound::Plot::Panels.preview(env.class, env.param_snapshot, b, live: live)).to equal(b)
    b.build
  end

  it 'lists an envelope\'s times in seconds and its sustain level as params, and its settings as preview data' do
    e = MB::Sound.adsr(0.05, 0.2, 0.5, 0.3)
    info = e.param_info
    expect(info.transform_values(&:value)).to eq({ attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.3 })
    expect(info[:attack].unit).to eq('s')
    d = e.preview_data
    expect(d).to include(kind: :envelope, names: %i[attack decay release], times: [0.05, 0.2, 0.3], levels: [1.0, 0.5, 0.0],
                         release_node: 2, gated: false, multi: false)
    expect(Ractor.shareable?(e.param_snapshot)).to eq(true)

    # Lengths as seconds; knobs at their value with their name
    k = MB::Sound::GraphNode::Knob.new(:att, 0.02, range: 0.001..2.0)
    e2 = MB::Sound.adsr(k, 250.ms, 0.4, 1.n4)
    expect(e2.preview_data[:times][0..1]).to eq([0.02, 0.25])
    expect(e2.param_info[:attack]).to have_attributes(value: 0.02, label: :att)

    m = MB::Sound.env([[1, 0.01], [0.3, 0.2], [0.6, 0.1], [0, 0.5]], release_at: 3, loop: 1)
    expect(m.preview_data).to include(names: %i[t1 t2 t3 t4], levels: [1.0, 0.3, 0.6, 0.0], release_node: 3, loop_node: 1, multi: true)
    expect(m.param_info.keys).to include(:t1, :t1_level, :t4, :t4_level)
  end

  it 'renders a copy at a low rate: the attack and decay at their times, the sustain a fixed share, then the release' do
    e = MB::Sound.adsr(0.05, 0.2, 0.5, 0.3, gate: 0.constant)
    d = e.preview_data
    expect(d[:gated]).to eq(true)
    tr = view.trace(d)
    expect(tr.rate).to be < 48000
    expect(tr.time.length).to be_within(4).of(view::POINTS)
    expect((tr.release_start - 0.25) / tr.release_end).to be_within(1e-9).of(view::SUSTAIN_SHARE)
    expect(tr.breaks).to eq([0.05, 0.25, tr.release_start, tr.release_end])
    at = ->(t) { tr.level[(t * tr.rate).round] }
    expect(at.(0.05)).to be_within(0.02).of(1.0)
    expect(at.(0.25)).to be_within(0.01).of(0.5)
    expect(at.(tr.release_start)).to be_within(0.01).of(0.5)
    expect(at.(tr.release_end)).to be_within(1e-3).of(0.0)
    expect(view.trace(d)).to equal(tr) # (kept per preview data)

    # The same shape as the envelope itself at 48 kHz (within a sample of the copy's rate)
    full = MB::Sound.adsr(0.05, 0.2, 0.5, 0.3, gate: MB::Sound::Envelope::PreviewGate.new((tr.release_start * 48000).round, 48000))
    ref = full.sample((tr.total * 48000).floor)
    worst = tr.time.to_a.each_with_index.map { |t, i| (ref[(t * 48000).round.clamp(0, ref.length - 1)] - tr.level[i]).abs }.max
    expect(worst).to be < 0.05

    # A one-shot releases after its hold, not the share
    one = MB::Sound.adsr(0.01, 0.1, 0.5, 0.2, hold: 0.3)
    expect(view.trace(one.preview_data).release_start).to eq(0.3)
  end

  it 'names the breakpoints in real units, marks node times, and draws the time axis\'s span and step' do
    chart = chart_of(MB::Sound.amp_env(0.02, 0.3, 0.6, 0.5))
    expect(chart.title).to eq('A 20ms D 300ms S -4.4dB R 500ms')
    expect(chart.x.title).to match(/\A\d+ms 200ms\/div\z/)
    expect(chart.marks.grep(MB::Sound::Plot::Mark::Rule).length).to eq(4)
    lfo = MB::Sound.adsr(1.hz.lfo.at(0.1..0.2), 0.3, 0.6, 0.5)
    expect(chart_of(lfo).title).to start_with('A ~ D 300ms')
    multi = MB::Sound.env([[1, 0.01], [0.3, 0.2], [0, 0.5]], release_at: 2, loop: 0)
    expect(chart_of(multi).title).to eq('t1 10ms→1 t2 200ms→0.3 | t3 500ms→0 loop t1')
    expect(chart_of(MB::Sound.filter_env(0.01, 0.3, 0.2, 0.4)).title).to end_with('×2^(2.0 oct)')
    text = chart.to_s(width: 60, height: 12)
    expect(text).to include('A 20ms D 300ms', '200')
  end

  it 'draws a playhead where a note is (held at the sustain point, moving on by +:elapsed+) and the levels a softer note reaches' do
    e = MB::Sound.amp_env(0.02, 0.3, 0.6, 0.5)
    tr = view.trace(e.preview_data)
    rule = ->(chart) { chart.marks.grep(MB::Sound::Plot::Mark::Rule).find { |r| r.color == 3 }&.at }
    expect(rule.(chart_of(e, live: { stage: :segment, segment: 1, position: 0.1, peak: 1.0 }))).to be_within(1e-9).of(0.12)
    expect(rule.(chart_of(e, live: { stage: :segment, segment: 1, position: 0.1, elapsed: 0.05, peak: 1.0 }))).to be_within(1e-9).of(0.17)
    expect(rule.(chart_of(e, live: { stage: :segment, segment: 1, position: 0.25, elapsed: 1, peak: 1.0 }))).to be_within(1e-9).of(0.32) # (stops at the sustain point)
    expect(rule.(chart_of(e, live: { stage: :sustain, segment: 1, position: 0.4, peak: 1.0 }))).to be_within(1e-9).of(0.32)
    expect(rule.(chart_of(e, live: { stage: :segment, segment: 2, position: 0.1, peak: 1.0 }))).to be_within(1e-9).of(tr.release_start + 0.1)
    expect(rule.(chart_of(e, live: { stage: :segment, segment: 2, position: 0.1, elapsed: 9, peak: 1.0 }))).to be_within(1e-9).of(tr.release_end)
    expect(rule.(chart_of(e, live: { stage: :idle, peak: 0.5 }))).to be_nil
    expect(rule.(chart_of(e))).to be_nil

    soft = chart_of(e, live: { stage: :idle, peak: 0.5 })
    expect(soft.title).to end_with(' pk -6.0dB')
    lines = soft.marks.grep(MB::Sound::Plot::Mark::Line)
    expect(lines.map(&:label)).to eq(['envelope', 'velocity 0.5'])
    expect(chart_of(e, live: { stage: :idle, peak: 1.0 }).marks.grep(MB::Sound::Plot::Mark::Line).length).to eq(1)
  end

  it 'gathers the newest sounding note of an envelope\'s synth lanes, and tells an amp envelope from a filter envelope' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.instance_eval do
        track(:bass) { |c| c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz * v.filter_env(0.01, 0.3, 0.2, 0.4)) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }
        bg :bass, seq(MB::Sound::E2, MB::Sound::G2).n2.loop
      end
    end
    g = MB::Sound::UI::Inspect::Gatherer.new
    6.times { s.process_buffer }
    info = g.call(s, { track: :bass, node: 0 })
    expect(info.nodes.map(&:label)).to include('amp_env', 'filter_env')
    expect(info.nodes.map(&:kind)).not_to include('GmTime')
    amp = info.selected
    expect(amp.label).to eq('amp_env')
    expect(amp.live).to include(stage: :segment, segment: 1)
    expect(amp.live[:position]).to be_within(1e-9).of((6 * 800 - 0.05 * 48000) / 48000.0)
    expect(amp.live[:peak]).to be_between(0.1, 1.0)
    expect(Ractor.shareable?(info)).to eq(true)
    expect(g.call(s, { track: :bass, node: info.nodes.index { |n| n.label == 'lp4' } }).selected.live).to be_nil # (not an envelope)
    expect(g.call(s, { track: :bass, node: info.nodes.index { |n| n.label == 'filter_env' } }).selected.live).to include(stage: :segment)
  ensure
    s&.close
    MB::Sound.rewind
  end

  it 'moves the pane\'s playhead on by the clock between polls while the segment runs' do
    now = 0.0
    MB::Sound::UI::Panes::Preview.clock = -> { now }
    snap = ui_fake_snapshot
    snap = snap.with(slow: snap.slow.with(inspector: ui_fake_envelope_inspector))
    pane = MB::Sound::UI.panes.fetch(:preview)
    state = {}
    draw = -> {
      grid = MB::Sound::Plot::Text::Cells.new(60, 12)
      pane.draw(MB::Sound::UI::Canvas.new(grid, 0, 0, 60, 12), snap, state)
      grid.to_text(:none)
    }
    first = draw.()
    expect(first).to include('A 20ms D 300ms S -4.4dB R 500ms pk -3.1dB')
    at = state[:chart].marks.grep(MB::Sound::Plot::Mark::Rule).find { |r| r.color == 3 }.at
    expect(at).to be_within(1e-9).of(0.12)
    now = 0.1
    draw.()
    expect(state[:chart].marks.grep(MB::Sound::Plot::Mark::Rule).find { |r| r.color == 3 }.at).to be_within(1e-9).of(0.22)
  ensure
    MB::Sound::UI::Panes::Preview.clock = nil
  end
end
