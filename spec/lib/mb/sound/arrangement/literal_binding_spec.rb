require_relative '../../../../support/ui_helpers'

# Live literals (envelope-view-1): a number in a track's patch (or a graph
# document's param) bound to a new knob by `bind`, the patch rebuilt with
# knob(...) in that argument's place and swapped in at the track's launch
# point; the same samples at the knob's starting value, turning moves
# them, undo brings the literal back, takes replay it.  Also the recipe
# keys (Recipe.counting, .key_of, .substituting) it names calls with, and
# the inspector's Enter on a literal param.
RSpec.describe(MB::Sound::Arrangement::LiteralBinding, :aggregate_failures) do
  LEAD = ->(c) { c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }

  after { MB::Sound.rewind }

  # A Session playing LEAD on track :lead (or +patch+ on +track+, from
  # +clip+), 4 buffers in, captured; +act+ runs then (in its context),
  # then +buffers+ more.
  def play(act = nil, track: :lead, patch: LEAD, clip: MB::Sound.seq(MB::Sound::E3, MB::Sound::G3).n4.loop, buffers: 200)
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(track, &patch)
      MB::Sound.bg(track, clip)
    end
    4.times { s.process_buffer }
    result = act && MB::Sound::Session.with_context(session: s) { act.call(s) }
    buffers.times { s.process_buffer }
    [s, Numo::DFloat.cast(out.captured[0]), result]
  end

  # The same rebuild as a bind, without binding: the track's patch built
  # again at its launch point.
  REBUILD = ->(s) {
    arr = s.arrangement
    tr = arr.tracks.values.first
    s.command('rebuild') { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil) }
  }

  def code_of(s, track = :lead)
    MB::Sound::UI::Inspect.roots(s.ui_graphs[track]).first.to_ruby
  end

  before { @sessions = [] }
  after { @sessions.each(&:close) }

  it 'names recorded calls by where they were made, and builds the same code again with some arguments substituted' do
    rec = MB::Sound::GraphNode::Recipe
    g = rec.counting { LEAD.call(MB::Sound.seq(MB::Sound::C3).notes) }
    lp4 = g.graph.find { |n| n.is_a?(MB::Sound::GraphNode::FourPole) }
    call = lp4.instance_variable_get(:@graph_recipe).call
    expect(rec.key_of(call)).to eq([:top, :synth, 0, :lp4, 0])
    outside = LEAD.call(MB::Sound.seq(MB::Sound::C3).notes).graph.find { |n| n.is_a?(MB::Sound::GraphNode::FourPole) }
    # (a build block outside a counting block is the top level of its calls)
    expect(rec.key_of(outside.instance_variable_get(:@graph_recipe).call)).to eq([:top, :lp4, 0])
    expect(rec.key_of(MB::Sound::GraphNode::Recipe.record_of(220.hz.saw.lp4(800)).call)).to be_nil # (not counted: no key)

    seen = []
    sub = { [:top, :synth, 0, :lp4, 0] => ->(args, kwargs) { seen << kwargs[:resonance]; [args, kwargs.merge(resonance: 0.5)] } }
    g2 = rec.substituting(sub) { LEAD.call(MB::Sound.seq(MB::Sound::C3).notes) }
    expect(seen.length).to be >= 2 # (every lane: the voices and spares)
    expect(seen.uniq).to eq([0.25])
    expect(g2.to_ruby).to include('lp4(1200.hz, resonance: 0.5)')
  end

  it 'binds a literal to a new knob: the same samples at its starting value, then turning moves them' do
    [
      [{ lp4: :resonance }, :"lead/reso", 0.25, 'resonance: knob(:"lead/reso")'],
      [{ lp4: :cutoff }, :"lead/cutoff", 1200.0, 'lp4(knob(:"lead/cutoff"), resonance: 0.25)'],
      [{ amp_env: :attack }, :"lead/attack", 0.05, 'amp_env(knob(:"lead/attack"), 0.2, 0.5, 0.3)'],
      [{ amp_env: :sustain }, :"lead/sustain", 0.5, 'amp_env(0.05, 0.2, knob(:"lead/sustain"), 0.3)'],
      [{ amp_env: :release }, :"lead/release", 0.3, 'amp_env(0.05, 0.2, 0.5, knob(:"lead/release"))'],
    ].each do |what, kname, value, code|
      s, bound, entry = play(->(_) { MB::Sound.bind(:lead, what) })
      _, ref, = play(REBUILD)
      expect(entry.to_s).to eq('bg :lead lands 2:1 (queued)'), what.inspect
      expect(s.knobs[kname].value).to be_within(1e-12).of(value)
      expect(code_of(s)).to include(code)
      expect(bound.length).to eq(ref.length)
      expect((bound - ref).abs.max).to eq(0.0), "#{what}: #{(bound - ref).abs.max}"
      expect(bound.abs.max).to be > 0.05
    end

    # The knob ranges come from the Param names table, holding the value
    s, = play(->(_) { MB::Sound.bind(:lead, amp_env: :attack) })
    expect(s.knobs[:"lead/attack"].spec.range).to eq(0.0001..10.0)
    expect(s.knobs[:"lead/cutoff"]).to be_nil

    # Turning moves it
    s, bound, = play(->(_) { MB::Sound.bind(:lead, lp4: :resonance) })
    _, ref, = play(REBUILD, buffers: 260)
    MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"lead/reso", 0.9) }
    60.times { s.process_buffer }
    turned = Numo::DFloat.cast(s.output.captured[0])
    expect((turned[0...bound.length] - ref[0...bound.length]).abs.max).to eq(0.0)
    expect((turned[bound.length..] - ref[bound.length..]).abs.max).to be > 0.01
  end

  it 'binds a graph document\'s param like a preset keyword' do
    reese = ->(c) { MB::Sound.preset(:dnb_reese, midi: c) }
    clip = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n4.loop
    s, bound, entry = play(->(_) { MB::Sound.bind(:bass, :cutoff) }, track: :bass, patch: reese, clip: clip)
    _, ref, = play(REBUILD, track: :bass, patch: reese, clip: clip)
    expect(entry.to_s).to eq('bg :bass lands 2:1 (queued)')
    expect(s.knobs[:"bass/cutoff"].value).to eq(2400.0)
    expect(code_of(s, :bass)).to include('lp4(knob(:"bass/cutoff") * lfo')
    expect((bound - ref).abs.max).to eq(0.0)

    # A preset's literals are fixed in its text: the reason names the
    # preset and its params, never a node class (the inspector shows it)
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.bind(:bass, filter: :quality) }.to raise_error(described_class::Error, 'quality is fixed in the dnb_reese preset; bind its param instead: cutoff')
    end
    roots = Array(s.arrangement.instance_variable_get(:@built)[:bass])
    wrapper = roots.flat_map { |r| MB::Sound::GraphNode.graph(r) }.grep(MB::Sound::Filter::SampleWrapper).first
    expect { described_class.target(roots, wrapper, :quality) }.to raise_error(described_class::Error, 'quality is fixed in the dnb_reese preset; bind its param instead: cutoff')
  end

  it 'is one undo step: the old patch and graph come back' do
    s, = play(->(_) { MB::Sound.bind(:lead, lp4: :resonance) })
    expect(code_of(s)).to include('knob(:"lead/reso")')
    expect(s.arrangement.tracks[:lead].patch).to respond_to(:literal_bindings)
    MB::Sound::Session.with_context(session: s) { MB::Sound.undo(on: :now) }
    4.times { s.process_buffer }
    expect(code_of(s)).to include('resonance: 0.25')
    expect(s.arrangement.tracks[:lead].patch).not_to respond_to(:literal_bindings)
    # Binding twice keeps both (the second wraps the first's patch)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.bind(:lead, lp4: :resonance, on: :now)
      MB::Sound.bind(:lead, amp_env: :release, on: :now)
    end
    4.times { s.process_buffer }
    expect(code_of(s)).to include('knob(:"lead/reso")', 'knob(:"lead/release")')

    # A set document saves the patch reading the knobs (the user's block,
    # built with the bindings)
    text = MB::Sound::GraphIO.dump(s.arrangement, name: 'bound')
    expect(text).to include('knob :"lead/reso"', 'track(:lead) { |c|', 'lp4(1200.hz, resonance: knob(:"lead/reso"))', 'knob(:"lead/release")')
    s2 = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    @sessions << s2
    doc = MB::Sound::GraphIO.load(text, session: s2)
    expect(MB::Sound::GraphIO.dump(doc.session.arrangement, name: 'bound').lines.reject { |l| l.include?('saved:') }).to eq(text.lines.reject { |l| l.include?('saved:') })
  end

  it 'says why a param can\'t be bound' do
    s, = play(nil, buffers: 2)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.bg(:pad, 220.hz.saw.lp4(800, resonance: 0.3))
      expect { MB::Sound.bind(:pad, lp4: :resonance) }.to raise_error(ArgumentError, /No track :pad/)
      MB::Sound.track(:pad2, 220.hz.saw.lp4(800, resonance: 0.3))
      expect { MB::Sound.bind(:pad2, lp4: :resonance) }.to raise_error(described_class::Error, /pad2 plays a graph, not a patch/)
      expect { MB::Sound.bind(:lead, synth: :voices) }.to raise_error(described_class::Error, /voices of synth is a count \(2; read once while the patch builds\): shown read-only/)
      expect(s.knobs).not_to have_key(:"lead/voices")
      expect { MB::Sound.bind(:lead, lp5: :resonance) }.to raise_error(described_class::Error, /no lp5 in the track's graph \(did you mean lp4\?\)/)
      expect { MB::Sound.bind(:lead, lp4: :drive) }.to raise_error(described_class::Error, /drive isn't an argument of lp4/)
      expect { MB::Sound.bind(:lead, :cutoff) }.to raise_error(described_class::Error, /no document param :cutoff/)
      MB::Sound.bind(:lead, lp4: :resonance, on: :now)
    end
    2.times { s.process_buffer }
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.bind(:lead, lp4: :resonance) }.to raise_error(described_class::Error, /resonance of lp4 is not a number/)
    end
  end

  it 'replays from a take bit for bit' do
    lines = {
      0 => ['track(:lead) { |c| c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }', 'bg :lead, seq(E3, G3).n4.loop'],
      30 => ['bind :lead, lp4: :resonance'],
      200 => ['turn :"lead/reso", 0.8, over: 1'],
      300 => ['undo'],
    }
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
    @sessions << session
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    400.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    live = SpecBuffers.join(out)
    expect(live.abs.max).to be > 0.05
    MB::Sound.seed(5)
    data = []
    t.replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [800], tail: 0) { |mix| data << mix[0].dup }
    data = SpecBuffers.join(data)
    expect((data[0...live.length] - live).abs.max).to eq(0)
  end

  it 'lets the inspector bind a picked literal param with Enter, naming what it rebuilds first' do
    ui = MB::Sound::UI
    s, = play(nil, buffers: 2)
    g = ui::Inspect::Gatherer.new
    info = g.call(s, { track: :lead, node: nil })
    i = info.nodes.index { |n| n.label == 'lp4' }
    info = g.call(s, { track: :lead, node: i })
    lp4 = info.selected
    expect(lp4.binds[:resonance]).to have_attributes(line: 'bind :lead, lp4: :resonance', knob: :"lead/reso", reason: nil)
    expect(lp4.binds[:cutoff].line).to eq('bind :lead, lp4: :cutoff')
    synth = g.call(s, { track: :lead, node: info.nodes.index { |n| n.label == 'synth' } }).selected
    expect(synth.params.values[:voices].value).to eq(2) # (shown, read-only)
    expect(synth.binds[:voices]).to have_attributes(line: nil, reason: a_string_including('a count'))
    expect(Ractor.shareable?(info)).to eq(true)

    snap = ui_fake_snapshot
    snap = snap.with(slow: snap.slow.with(inspector: info), knobs: [].freeze)
    pane = ui.panes.fetch(:inspector)
    st = { title_in_rule: true, mode: true, snap: snap }
    names = lp4.params.values.keys
    st[:pick] = names.index(:resonance) # (no knobs: the params come first)
    grid = MB::Sound::Plot::Text::Cells.new(80, 16)
    pane.draw(ui::Canvas.new(grid, 0, 0, 80, 16), snap, st)
    expect(grid.to_text(:none)).to include('Enter: knob :"lead/reso"')
    expect(pane.enter_hint(st)).to eq('make resonance knob :"lead/reso": rebuilds lead at its launch point (voices and tails start fresh)')
    ask = pane.key_action(:ask, st).last
    expect(ask).to eq(ui::PaneKeys::Ask['', 'bind :lead, lp4: :resonance', :bind])
    run = pane.key_action(:bind, st, ask.text)
    expect(run.code).to eq('bind :lead, lp4: :resonance')
    ui.run_line(run.code, s)
    300.times { s.process_buffer }
    expect(code_of(s)).to include('knob(:"lead/reso")')

    # A param a knob drives turns its knob; a graph track's literal says why not
    info = g.call(s, { track: :lead, node: i })
    expect(info.selected.binds).not_to have_key(:resonance)
    MB::Sound::Session.with_context(session: s) { MB::Sound.bg(:pad, 220.hz.saw.lp4(800, resonance: 0.3), on: :now) }
    2.times { s.process_buffer }
    pad = g.call(s, { track: :pad, node: nil })
    expect(pad.track).to eq(:pad), pad.tracks.inspect
    pad = g.call(s, { track: :pad, node: pad.nodes.index { |n| n.label == 'lp4' } })
    expect(pad.selected.binds[:resonance].reason).to include('pad plays a graph, not a patch')
  end
end
