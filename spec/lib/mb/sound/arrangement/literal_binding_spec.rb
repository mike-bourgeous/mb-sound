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
  # again at its launch point, carrying the running state (Session::Carry).
  REBUILD = ->(s) {
    arr = s.arrangement
    tr = arr.tracks.values.first
    s.command('rebuild') { arr.send(:start_track, tr, tr.clip, arr.send(:resolve, tr.q || arr.quant, tr, MB::Sound::LaunchPoint::NONE), nil, carry: true) }
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
      [{ lp4: :resonance }, :"lead/resonance", 0.25, 'resonance: knob(:"lead/resonance")'],
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
    MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"lead/resonance", 0.9) }
    60.times { s.process_buffer }
    turned = Numo::DFloat.cast(s.output.captured[0])
    expect((turned[0...bound.length] - ref[0...bound.length]).abs.max).to eq(0.0)
    expect((turned[bound.length..] - ref[bound.length..]).abs.max).to be > 0.01
  end

  it 'binds a graph document\'s param like a preset keyword (already a knob on its track: TrackKnobs)' do
    reese = ->(c) { MB::Sound.preset(:dnb_reese, midi: c) }
    clip = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n4.loop
    s, bound, kn = nil
    expect {
      s, bound, kn = play(->(_) { MB::Sound.bind(:bass, :cutoff) }, track: :bass, patch: reese, clip: clip)
    }.to output(/already knob :"bass\/cutoff"/).to_stdout
    _, ref, = play(nil, track: :bass, patch: reese, clip: clip) # (nothing to rebuild)
    expect(kn).to eq(:"bass/cutoff")
    expect(s.knobs[:"bass/cutoff"].value).to eq(2400.0)
    expect(code_of(s, :bass)).to include('lp4(knob(:"bass/cutoff") * lfo')
    expect((bound - ref).abs.max).to eq(0.0)

    # A preset's literals are fixed in its text: the reason names the
    # preset and its params, never a node class (the inspector shows it)
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.bind(:bass, filter: :quality) }.to raise_error(described_class::Error, 'quality is fixed in the dnb_reese preset; bind its params instead: cutoff, resonance, drive, glide')
    end
    roots = Array(s.arrangement.instance_variable_get(:@built)[:bass])
    wrapper = roots.flat_map { |r| MB::Sound::GraphNode.graph(r) }.grep(MB::Sound::Filter::SampleWrapper).first
    expect { described_class.target(roots, wrapper, :quality) }.to raise_error(described_class::Error, 'quality is fixed in the dnb_reese preset; bind its params instead: cutoff, resonance, drive, glide')
  end

  it 'is one undo step: the old patch and graph come back' do
    s, = play(->(_) { MB::Sound.bind(:lead, lp4: :resonance) })
    expect(code_of(s)).to include('knob(:"lead/resonance")')
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
    expect(code_of(s)).to include('knob(:"lead/resonance")', 'knob(:"lead/release")')

    # A set document saves the patch reading the knobs (the user's block,
    # built with the bindings)
    text = MB::Sound::GraphIO.dump(s.arrangement, name: 'bound')
    expect(text).to include('knob :"lead/resonance"', 'track(:lead) { |c|', 'lp4(1200.hz, resonance: knob(:"lead/resonance"))', 'knob(:"lead/release")')
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

  # A sweep (fixes-1030; settings from research-snapshot-mutability's
  # probe_live.rb): every effect setting either binds (the rebuilt patch
  # reads the knob; effects returning bundles, ping_pong, multitap, chorus,
  # are found through their outputs) or is refused with one line saying it
  # is fixed when the patch builds (never a raw NoMethodError).  A new
  # effect, or a setting that becomes live, goes in this table.
  BIND_SWEEP = {
    'reverb(:hall, ...)' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.reverb(:hall, **o) } }, :reverb,
      { lowpass: 8000, highpass: 100, drive: 0.5, crush: 0.2, shimmer: 0.3, stretch: 1.2, mix: 0.3, wet: 0.5, dry: 1, level: 1, predelay: 0.02 },
      {}],
    'reverb(room_size:, decay:)' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.reverb(**{ room_size: 0.5, decay: 2.0, damping: 0.4 }.merge(o)) } }, :reverb,
      {}, { room_size: 0.5, decay: 2.0, damping: 0.4 }],
    'delay' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.delay(0.3, **o) } }, :delay,
      { feedback: 0.5, wet: 0.5, dry: 1 }, {}],
    'ping_pong' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.ping_pong(0.25, **o) } }, :ping_pong,
      { feedback: 0.5, spread: 1, mix: 0.5 }, {}],
    'ping_pong into a reverb' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.ping_pong(0.25, **o).reverb(:room, mix: 0.2) } }, :ping_pong,
      { feedback: 0.5 }, {}],
    'multitap with feedback' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.multitap(0.2, 0.3, **o) } }, :multitap,
      { feedback: 0.3 }, {}],
    'tape_echo(:dub, ...)' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.tape_echo(:dub, **o) } }, :tape_echo,
      { time: 0.3, feedback: 0.6, mix: 0.5, tone: 2000, low_cut: 100, drive: 0.5, wow: 0.3, flutter: 0.3 }, {}],
    'chorus(:juno2, ...)' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.chorus(:juno2, **o) } }, :chorus,
      { rate: 0.5, depth: 0.5, mix: 0.5 }, {}],
    'formant(:a, :o, ...)' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.formant(:a, :o, **o) } }, :formant,
      { morph: 0.5, shift: 2, width: 1 }, {}],
    'lp4' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw.lp4(1000, **o) * v.amp_env(0.01, 0.1, 0.5, 0.1) } } }, :lp4,
      { resonance: 0.3 }, { drive: 1.5 }],
    'compress' => [->(o) { ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.compress(**o) } }, :compress,
      { attack: 0.01, release: 0.1, threshold: -20.db, ratio: 4, mix: 0.8 }, {}],
  }.freeze

  it 'binds every live effect setting and refuses fixed ones with one line (sweep)' do
    BIND_SWEEP.each do |label, (patch, method, live, fixed)|
      live.merge(fixed).each do |setting, value|
        s, _, result = play(->(_) {
          begin
            MB::Sound.bind(:fx, method => setting)
          rescue described_class::Error => e
            e
          end
        }, track: :fx, patch: patch.({ setting => value }), buffers: 2)
        what = "#{label} #{setting}"
        if live.key?(setting)
          expect(result).not_to be_a(Exception), "#{what}: #{result.inspect}"
          expect(s.knobs.keys.grep(/\Afx\//)).not_to be_empty, what
        else
          expect(result).to be_a(described_class::Error), "#{what}: #{result.inspect}"
          expect(result.message).to match(/\Abind :fx, #{method}: :#{setting}: #{setting} of #{method} is fixed when the patch builds, so a knob can't move it; .* \(nothing was changed\)\z/), what
          expect(result.message.lines.count).to eq(1), what
        end
        s.close
        @sessions.delete(s)
      end
    end
  end

  # (delays-2, 2026-10-31: the maintainer's "Mix should just be a gain
  # control that can be adjusted with a knob, no rebuild needed")
  it 'binds a reverb\'s mix: the same samples at its starting value, then turning moves them without a rebuild' do
    patch = ->(c) { c.synth(voices: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.1) }.reverb(:hall, mix: 0.25) }
    s, bound, = play(->(_) { MB::Sound.bind(:pad, reverb: :mix) }, track: :pad, patch: patch, buffers: 120)
    _, ref, = play(REBUILD, track: :pad, patch: patch, buffers: 180)
    expect(s.knobs[:"pad/mix"].value).to eq(0.25)
    expect(code_of(s, :pad)).to include('reverb(:hall, mix: knob(:"pad/mix"))')
    expect((bound - ref[0...bound.length]).abs.max).to eq(0.0)

    graph = s.ui_graphs[:pad]
    MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"pad/mix", 0.9) }
    60.times { s.process_buffer }
    expect(s.ui_graphs[:pad]).to equal(graph) # (no rebuild)
    turned = Numo::DFloat.cast(s.output.captured[0])
    expect((turned[0...bound.length] - ref[0...bound.length]).abs.max).to eq(0.0)
    expect((turned[bound.length..] - ref[bound.length..]).abs.max).to be > 0.01
  end

  it 'replays from a take bit for bit' do
    lines = {
      0 => ['track(:lead) { |c| c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }', 'bg :lead, seq(E3, G3).n4.loop'],
      30 => ['bind :lead, lp4: :resonance'],
      200 => ['turn :"lead/resonance", 0.8, over: 1'],
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

  # sound-design-nav-1 (found by research-sound-design-nav): a unison's
  # call is recorded on the bundle it returns, and calls run per channel
  # on a stereo bundle on the bundle they return, so the mixer and the
  # per-channel lp4s had no call to bind (ChannelMixer::Unison#recipe_bundle,
  # ChannelGroup#bundle)
  STEREO = ->(c) { c.synth(voices: 2) { |v| v.hz.unison(4, detune: 0.3, spread: 0.5) { |p, _| p.saw }.lp4(1200.hz, resonance: 0.25) * v.amp_env(0.05, 0.2, 0.5, 0.3) } }

  it 'binds a unison\'s detune and a stereo lp4\'s resonance, the same samples at their starting values' do
    _, plain, = play(REBUILD, patch: STEREO)
    s, reso, = play(->(_) { MB::Sound.bind(:lead, lp4: :resonance) }, patch: STEREO)
    expect(code_of(s)).to include('knob(:"lead/resonance")')
    expect((reso - plain).abs.max).to eq(0)
    s, detune, = play(->(_) { MB::Sound.bind(:lead, unison: :detune) }, patch: STEREO)
    expect(code_of(s)).to include('knob(:"lead/detune")')
    # (a knob's detune runs the unison's moving-detune path, pitches
    # computed per sample: within -70 dB of the fixed offsets over 200
    # buffers from fresh oscillators; carried ones that ran 2 s already,
    # since sound-design-2, within -60 dB: -55 here, not bit for bit)
    expect((detune - plain).abs.max).to be < 10 ** (-55 / 20.0)
    expect((detune - plain).abs.max).to be > 0
  end

  it 'lets the inspector bind a picked literal param with Enter, naming what it rebuilds first' do
    ui = MB::Sound::UI
    s, = play(nil, buffers: 2)
    g = ui::Inspect::Gatherer.new
    info = g.call(s, { track: :lead, node: nil })
    i = info.nodes.index { |n| n.label == 'lp4' }
    info = g.call(s, { track: :lead, node: i })
    lp4 = info.selected
    expect(lp4.binds[:resonance]).to have_attributes(line: 'bind :lead, lp4: :resonance', knob: :"lead/resonance", reason: nil)
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
    grid = MB::Term::Cells.new(80, 16)
    pane.draw(ui::Canvas.new(grid, 0, 0, 80, 16), snap, st)
    expect(grid.to_text(:none)).to include('Enter: knob :"lead/resonance"')
    expect(pane.enter_hint(st)).to eq('make resonance knob :"lead/resonance": rebuilds lead at its launch point (notes play on; delays and reverbs start fresh; Left/Right bind it now and turn)')
    ask = pane.key_action(:ask, st).last
    expect(ask).to eq(ui::PaneKeys::Ask['', 'bind :lead, lp4: :resonance', :bind])
    run = pane.key_action(:bind, st, ask.text)
    expect(run.code).to eq('bind :lead, lp4: :resonance')
    ui.run_line(run.code, s)
    300.times { s.process_buffer }
    expect(code_of(s)).to include('knob(:"lead/resonance")')

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

  # sound-design-2, the envelope editor: literals inside a segment list
  # (`env([[level, time, curve], ...])`: :t2, :t2_level, :t1_curve) and a
  # chained setter's (`.curve(release: 30)`: :release_curve) bind like
  # any literal, carried across the rebuild (Session::Carry), and the
  # inspector's arrows on one bind it now and turn it
  POINTS = ->(c) { c.synth(voices: 2) { |v| v.hz.saw.lp4(1200.hz) * v.env([[1.0, 0.01, 20], [0.6, 0.3], [0.0, 0.25]], release_at: 2).curve(release: 30) } }

  it 'binds an envelope\'s list points and chained setters, the same samples at their starting values' do
    _, plain, = play(REBUILD, patch: POINTS)
    [
      [{ env: :t2 }, :"lead/t2", 0.3, '[knob(:"lead/t2_level"), 0.3]'],
      [{ env: :t2_level }, :"lead/t2_level", 0.6, '[knob(:"lead/t2_level"), 0.3]'],
      [{ env: :t1_curve }, :"lead/t1_curve", 20.0, '[1.0, 0.01, knob(:"lead/t1_curve")]'],
      [{ curve: :release }, :"lead/release_curve", 30.0, '.curve(release: knob(:"lead/release_curve"))'],
    ].each do |what, kname, value, code|
      s, bound, = play(->(_) { MB::Sound.bind(:lead, what) }, patch: POINTS)
      expect(s.knobs[kname].value).to be_within(1e-12).of(value), what.inspect
      expect(code_of(s)).to include(code.sub('knob(:"lead/t2_level")', what[:env] == :t2_level ? 'knob(:"lead/t2_level")' : '0.6').sub(', 0.3]', what[:env] == :t2 ? ', knob(:"lead/t2")]' : ', 0.3]')), what.inspect
      expect((bound - plain).abs.max).to be < 1e-6, "#{what}: #{(bound - plain).abs.max}"
      expect(s.last_carry.matched).to eq(s.last_carry.stateful)
    end
    s, = play(->(_) { MB::Sound.bind(:lead, env: :t2) }, patch: POINTS)
    expect(s.knobs[:"lead/t2"].spec.range).to eq(0.0001..10.0) # (an attack's range)
    s, = play(->(_) { MB::Sound.bind(:lead, curve: :release) }, patch: POINTS)
    expect(s.knobs[:"lead/release_curve"].spec.range).to eq(-60.0..60.0)
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.bind(:lead, env: :t9) }.to raise_error(described_class::Error, /t9 isn't an argument of env/)
    end
  end

  it 'turns an envelope point with the inspector\'s arrows: the first press binds it now, and the preview marks it' do
    ui = MB::Sound::UI
    s, = play(nil, patch: POINTS, buffers: 2)
    g = ui::Inspect::Gatherer.new
    info = g.call(s, { track: :lead, node: nil })
    i = info.nodes.index { |n| n.what == 'amp env' } || info.nodes.index { |n| n.label == 'env' }
    info = g.call(s, { track: :lead, node: i })
    env = info.selected
    expect(env.params.values.keys).to include(:t2, :t2_level, :t1_curve, :release_curve)
    expect(env.binds[:t2].line).to eq('bind :lead, env: :t2')
    expect(env.binds[:release_curve].line).to eq('bind :lead, curve: :release')

    snap = ui_fake_snapshot
    snap = snap.with(slow: snap.slow.with(inspector: info), knobs: [].freeze)
    pane = ui.panes.fetch(:inspector)
    st = { title_in_rule: true, mode: true, snap: snap, view: :sections }
    st[:pick] = pane.send(:pick_list, st, info).index { |e| e[0] == :param && e[1] == :t2 }
    run = pane.key_action(:turn, st, ui::KnobTurns::STEP)
    expect(run.code).to match(/\Abind :lead, env: :t2, on: :now; turn :"lead\/t2", 0\.3\d+\z/)
    again = pane.key_action(:turn, st, ui::KnobTurns::STEP)
    expect(again.code).to match(/\Aturn :"lead\/t2", 0\.4\d+\z/) # (the knob it made, a step on, until the inspector shows it)
    ui.run_line(run.code, s)
    4.times { s.process_buffer }
    expect(code_of(s)).to include('knob(:"lead/t2")')
    expect(s.last_carry.matched).to eq(s.last_carry.stateful) # (bound now, mid-note: notes play on)

    # The preview marks the picked point
    pane.key_action(:pick, st, 0)
    expect(ui::Inspect.target[:param]).to eq(:t2)
    chart = MB::Sound::Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
    MB::Sound::Plot::Panels.preview(env.params.node_class, env.params, chart, live: { focus: :t2 })
    built = chart.build
    expect(built.title).to start_with('▸t2 ')
  ensure
    ui::Inspect.target = nil
  end
end
