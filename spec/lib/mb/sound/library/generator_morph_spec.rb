require 'mb/sound/help'

# Morphs of generators (gen-morph-1): `L.gen.beat.dnb.morph(L.gen.beat.house)`
# crossfades two generators slot by slot (Generative::Morph), steered by a
# track knob :"drums/morph".  The ends render sample for sample like the
# sides alone, buffer sizes don't change the samples, every L.gen entry
# morphs with one of its kind or refuses with a message, and the chain
# prints, saves, loads, and replays from takes.  (The drum beats' pair
# sweep: drum_beats_spec.rb.)
RSpec.describe MB::Sound::Library::Generators, 'morph', :aggregate_failures do
  let(:gens) { MB::Sound::Library::Generators }
  let(:l) { MB::Sound::L }

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  # The kind of every shipped L.gen entry for morphs: :drums (a drum beat,
  # slots by drum and step) or :line (melodic lines, strikes, chords,
  # fixed loops: slots by beat).  A new generator entry must be added here
  # (the guard below), so its morphs are checked.
  KINDS = {
    rock: :drums, pop: :drums, halftime: :drums, funk: :drums, house: :drums, dnb: :drums, techno: :drums,
    acid_rhythm: :line, phrygian_motif: :line, koto_motif: :line, probability_melody: :line, dorian_melody: :line,
    rin_strikes: :line, bowl_strikes: :line, chord_pad: :line, blur_line: :line, blur_cloud: :line, pentatonic_bass: :line,
    tin_roof_motif: :line, tin_roof_harp: :line, ambient_roots: :line, ambient_motif: :line, ambient_figure: :line,
  }.freeze

  def gen_entry(name) = l.gen.entries.find { |e| e.name == name }

  # Renders +bars+ bars at 124 BPM after running +setup+ (with the
  # Session) in a non-realtime Session, at +sizes+ buffer sizes in turn;
  # returns [left channel, session].
  def render(bars, sizes: [800], bpm: 124, &setup)
    MB::Sound.rewind
    MB::Sound.seed(1)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: bpm),
      channels: 2, buffer_size: sizes.max, realtime: false, raise_errors: true)
    @sessions << s
    frames = (bars * 48000 * 240r / bpm).ceil
    MB::Sound::Session.with_context(session: s) { setup.call(s) }
    out = []
    n = 0
    i = 0
    while n < frames
      out << s.process_buffer(sizes[i % sizes.length])[0].dup
      n += out.last.length
      i += 1
    end
    [SpecBuffers.join(out)[0...frames], s]
  end

  # A drum track on the 909 with its energy knob at 0.6.
  def drums(s)
    MB::Sound.track(:drums, :tr909)
    s.knob(:"drums/energy", 0.6, range: 0.0..1.0)
  end

  # A melodic track on a triangle synth with its density knob at 0.6.
  def lead(s)
    MB::Sound.track(:lead) { |c| c.synth(voices: 6) { |v| v.hz.triangle * v.env(0.005, 0.1, 0.5, 0.1, gm: false) * 0.2 } }
    s.knob(:"lead/density", 0.6, range: 0.0..1.0)
  end

  it 'renders morph 0 like the first generator and morph 1 like the second, sample for sample, on a track with its knobs',
     render_budget: { seconds: 150, reason: 'four pairs, four 4-bar renders each (~77 s of audio at 200 BPM)' } do
    [[:drums, :rock, :funk], [:drums, :pop, :house], [:lead, :koto_motif, :phrygian_motif], [:lead, :probability_melody, :dorian_melody]].each do |track, an, bn|
      a = gen_entry(an)
      b = gen_entry(bn)
      setup = ->(s) { track == :drums ? drums(s) : lead(s) }
      ra, = render(4, bpm: 200) { |s| setup.(s); MB::Sound.bg(track, a, on: :now) }
      rb, = render(4, bpm: 200) { |s| setup.(s); MB::Sound.bg(track, b, on: :now) }
      m0, s0 = render(4, bpm: 200) { |s| setup.(s); MB::Sound.bg(track, a.morph(b), on: :now) }
      m1, = render(4, bpm: 200) { |s| setup.(s); MB::Sound.bg(track, a.morph(b, morph: 1), on: :now) }
      expect(ra.abs.max).to be > 0.01, "#{an} is silent"
      expect((m0 - ra).abs.max).to eq(0), "#{an} -> #{bn} at 0"
      expect((m1 - rb).abs.max).to eq(0), "#{an} -> #{bn} at 1"
      expect(s0.knobs.keys).to include(:"#{track}/morph")
      # (the middle is neither)
      mid = a.call.morph(b.call, morph: 0.5)
      ev = ->(c) { (0...4).map { |cy| c.events_for(cy).map { |e| [e.start, e.value] } } }
      expect(ev.(mid)).not_to eq(ev.(a.call))
      expect(ev.(mid)).not_to eq(ev.(b.call))
    end
  end

  it 'renders the same samples at 800 and at 367/368-frame buffers with an LFO on the knob, the same every time' do
    a = l.gen.beat.rock
    b = l.gen.beat.funk
    lfo = ->(s) {
      drums(s)
      MB::Sound.bg(:drums, a.morph(b), on: :now)
      MB::Sound.turn(:"drums/morph", 2.beats.lfo.square.at(0.0..1.0))
    }
    r1, = render(4, bpm: 200, &lfo)
    r2, = render(4, bpm: 200, sizes: [367, 368], &lfo)
    r3, = render(4, bpm: 200, &lfo)
    plain, = render(4, bpm: 200) { |s| drums(s); MB::Sound.bg(:drums, a, on: :now) }
    expect((r1 - r2).abs.max).to eq(0)
    expect(r3).to eq(r1)
    expect(r1).not_to eq(plain)
  end

  it 'plays each beat the side a square LFO on the knob gives it, from the first beat' do
    patch = ->(s) {
      MB::Sound.track(:drums) { |c| c.trigger + c.number * 0.001 }
      s.knob(:"drums/energy", 0.6, range: 0.0..1.0)
    }
    step = 48000 * 60r / 124 / 4
    onsets = ->(r) { (r.gt 0.2).where.to_a.map { |f| (f / step).round }.uniq }
    ra, = render(4) { |s| patch.(s); MB::Sound.bg(:drums, l.gen.beat.rock, on: :now) }
    rb, = render(4) { |s| patch.(s); MB::Sound.bg(:drums, l.gen.beat.funk, on: :now) }
    rl, = render(4) { |s|
      patch.(s)
      MB::Sound.bg(:drums, l.gen.beat.rock.morph(:funk), on: :now)
      MB::Sound.turn(:"drums/morph", 2.beats.lfo.square.at(0.0..1.0))
    }
    oa, ob, ol = [ra, rb, rl].map { |r| onsets.(r) }
    expect(oa).not_to eq(ob)
    # (a 2-beat square from 1: beats 1, 3, ... play funk, beats 2, 4, ... rock)
    16.times do |bt|
      steps = (bt * 4...bt * 4 + 4).to_a
      side = bt.even? ? ob : oa
      expect(ol & steps).to eq(side & steps), "beat #{bt + 1}"
    end
  end

  it 'makes the knob drums/morph at the starting level morph: gives, with the sides\' knobs (one knob for a shared name)' do
    s = MB::Sound::Session.new(realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.track(:drums, l.gen.beat.rock.morph(:funk, morph: 0.3))
      MB::Sound.track(:d2, l.gen.beat.rock.morph(:techno))
    }
    clip = s.arrangement.tracks[:drums].clip
    expect(s.knobs[:"drums/morph"].value).to eq(0.3)
    expect(s.knobs[:"drums/morph"].spec.range).to eq(0.0..1.0)
    expect(gens.knobs_of(clip).keys).to eq(%i[energy swing morph])
    expect(gens.knobs_of(clip).transform_values(&:name)).to eq({ energy: :"drums/energy", swing: :"drums/swing", morph: :"drums/morph" })
    # (rock's swing is a knob though techno has none: the knob only one side has still shows)
    expect(gens.knobs_of(s.arrangement.tracks[:d2].clip).keys).to eq(%i[energy swing morph])
    # (plays what the plain morph at 0.3 plays until turned)
    plain = l.gen.beat.rock.call.morph(l.gen.beat.funk.call, morph: 0.3)
    MB::Sound::Session.with_context(session: s) {
      8.times { |cy| expect(clip.events_for(cy)).to eq(plain.events_for(cy)), "bar #{cy + 1}" }
    }
    expect(clip.to_ruby).to eq('L.gen.beat.rock(seed: 11).morph(L.gen.beat.funk(seed: 14), morph: 0.3)')
  end

  it 'moves the second side of a shared knob from its own home (funk swings 0.54 while the knob sits at rock\'s 0.5)' do
    s = MB::Sound::Session.new(realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) { MB::Sound.track(:drums, l.gen.beat.rock.morph(:funk, morph: 1)) }
    gen = s.arrangement.tracks[:drums].clip.variations.first.block
    swing = ->(i) { MB::Sound::ValueSource.value_at(gen.steer.params[:"#{%w[a b][i]}.swing"], s.transport.position) }
    expect([swing.(0), swing.(1)]).to eq([0.5, 0.54])
    # (funk's swing is 0.54 + (knob - 0.5): exactly 0.54 untouched, as much
    # higher as the knob is turned up)
    expect(gen.steer.params[:"a.swing"].node).to equal(s.knobs[:"drums/swing"])
    expect(gen.steer.params[:"b.swing"].to_ruby).to eq('0.54 + (knob(:"drums/swing") - 0.5)')
  end

  it 'turns with a scene\'s track hash and over: like any track knob' do
    s = MB::Sound::Session.new(realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.track(:drums, :tr909)
      MB::Sound.scene(:a, drums: l.gen.beat.dnb.morph(l.gen.beat.house))
      MB::Sound.scene(:b, drums: { morph: 1 })
      MB::Sound.go(:a, on: :now)
    }
    4.times { s.process_buffer }
    expect(s.knobs[:"drums/morph"].value).to eq(0.0)
    MB::Sound::Session.with_context(session: s) { MB::Sound.go(:b, on: :now) }
    4.times { s.process_buffer }
    expect(s.knobs[:"drums/morph"].value).to eq(1.0)
  end

  # beat-halftime-1 fixes a generator that stopped after 8 bars when `bg`
  # named no track; on a track the morph plays on, and with no track it
  # plays on its first side's kit.
  it 'plays on at bars 33 and 65, on a track and with no track', render_budget: { seconds: 200, reason: 'two 66-bar morph renders at 400 BPM (~80 s of audio each)' } do
    bar_frames = (48000 * 240r / 400).floor
    level = ->(r, bar) { a = ((bar - 1) * 48000 * 240r / 400).floor; r[a...(a + bar_frames)].abs.max }
    on, = render(66, bpm: 400) { |s| drums(s); MB::Sound.bg(:drums, l.gen.beat.house.morph(:techno, morph: 0.5), on: :now) }
    bare, = render(66, bpm: 400) { |_s| MB::Sound.bg(:loose, l.gen.beat.house.morph(:techno, morph: 0.5), on: :now) }
    [1, 33, 65].each do |bar|
      expect(level.(on, bar)).to be > 0.01, "on a track, bar #{bar}"
      expect(level.(bare, bar)).to be > 0.01, "with no track, bar #{bar}"
    end
  end

  it 'saves a set holding a morph as the chain with its knob, loading back to the same samples' do
    io = MB::Sound::GraphIO
    text = nil
    live, = render(4) { |s|
      drums(s)
      MB::Sound.bg(:drums, l.gen.beat.rock.morph(:funk, morph: 0.25), on: :now)
      text = io.dump(s.arrangement, name: 'm')
    }
    expect(text).to include('L.gen.beat.rock(seed: 11).morph(L.gen.beat.funk(seed: 14), morph: 0.25)')
    expect(text).to include('knob :"drums/morph", (0.0..1.0).at(0.25)')
    again = nil
    loaded, = render(4) { |s|
      io.load(text)
      MB::Sound.bg(:drums, on: :now)
      again = io.dump(s.arrangement, name: 'm')
    }
    unsaved = ->(t) { t.sub(/ saved: "[^"]*",/, '') }
    expect(unsaved.(again)).to eq(unsaved.(text))
    expect((loaded - live).abs.max).to eq(0)
  end

  # No GraphIO::FORMATS entry (graph_io.md: documents without a morph load
  # as before, and a loader without Clip#morph refuses the word by name,
  # as for every new recorded method): checked by taking the word away.
  it 'needs no format number: a loader that doesn\'t know morph refuses the document by name' do
    io = MB::Sound::GraphIO
    doc = io.dump(MB::Sound.tr909(l.gen.beat.dnb.morph(:house)))
    allow(io::Registry).to receive(:names_for).and_wrap_original { |m, obj| n = m.call(obj); obj.is_a?(MB::Sound::Sequence::Clip) ? n - [:morph] : n }
    expect { io.load(doc) }.to raise_error(StandardError, /morph/)
  end

  it 'replays a take of a morph and a knob turn bit for bit' do
    MB::Sound.rewind
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 140),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
    @sessions << s
    lines = {
      0 => ['track :drums, :tr909', 'bg :drums, L.gen.beat.dnb.morph(L.gen.beat.house), on: :now'],
      90 => ['turn :"drums/morph", 1, over: 2.bars'],
    }
    bnd = MB::Sound::Take.console_binding
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: s)
    out = []
    300.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { t.line(code, bnd) } }
      out << s.process_buffer[0].dup
    end
    live = SpecBuffers.join(out)
    expect(live.abs.max).to be > 0.01
    path = tmp_path('take.rb')
    expect { t.save(path) }.to output(/Saved/).to_stdout
    load path
    r = MB::Sound::Take::Replay.last
    MB::Sound.seed(5)
    got = []
    r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [800], tail: 0) { |mix| got << mix[0].dup }
    data = SpecBuffers.join(got)
    expect((data[0...live.length] - live).abs.max).to eq(0)
  end

  it 'is the same as L.gen.morph(a, b), printed as the chain' do
    expect(l.gen.morph(:rock, :funk).to_ruby).to eq('L.gen.beat.rock(seed: 11).morph(L.gen.beat.funk(seed: 14))')
    expect(l.gen.morph(l.gen.beat.dnb, l.gen.beat.house, morph: 0.3).to_ruby).to eq('L.gen.beat.dnb(seed: 16).morph(L.gen.beat.house(seed: 15), morph: 0.3)')
    expect(l.gen.beat.dnb.morph(:house).to_ruby).to eq('L.gen.beat.dnb(seed: 16).morph(L.gen.beat.house(seed: 15))')
    expect(l.gen.beat.rock(seed: 3).morph(l.gen.beat.funk(swing: 0.6)).to_ruby).to eq('L.gen.beat.rock(seed: 3).morph(L.gen.beat.funk(seed: 14, swing: 0.6))')
    expect(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(MB::Sound.tr909(l.gen.beat.dnb.morph(:house)))).to_ruby).to include('L.gen.beat.dnb(seed: 16).morph(L.gen.beat.house(seed: 15))')
  end

  it 'refuses what can\'t morph, naming the form that works' do
    expect { l.gen.beat.dnb.morph }.to raise_error(ArgumentError, /L\.gen\.beat\.dnb\.morph needs the generator to morph into: L\.gen\.beat\.dnb\.morph\(:\w+\) or L\.gen\.beat\.dnb\.morph\(L\.gen\.beat\.\w+\)/)
    expect { l.gen.beat.rock.morph(:koto_motif) }.to raise_error(ArgumentError, /L\.gen\.beat\.rock plays drum roles and L\.gen\.koto_motif plays pitches: a morph needs two of one kind; layer them on two tracks/)
    expect { l.gen.koto_motif.morph(l.gen.beat.rock) }.to raise_error(ArgumentError, /L\.gen\.beat\.rock plays drum roles and L\.gen\.koto_motif plays pitches/)
    expect { l.gen.beat.rock.morph(l.kit.entries.first) }.to raise_error(ArgumentError, /is a kit: morph blends generators \(L\.gen\), and a track plays them on it \(track :drums, L\.kit/)
    expect { l.gen.beat.rock.morph(MB::Sound.grid(16, kick: 'x...')) }.to raise_error(ArgumentError, /a kit plays drums; morph blends two generators/)
    expect { l.flow.entries.first.morph(:x) }.to raise_error(ArgumentError, /L\.flow chains choose sections; morph blends note generators \(L\.gen\)/)
    expect { l.gen.beat.rock.morph(l.flow.entries.first) }.to raise_error(ArgumentError, /L\.flow chains choose sections/)
    expect { l.fx.entries.first.morph(:x) }.to raise_error(ArgumentError, /morph blends generators \(L\.gen\); effects mix with sig\.blend/)
    expect { l.gen.beat.rock.morph(:hous) }.to raise_error(ArgumentError, /nothing under L\.gen is :hous.*Did you mean\?  :house/m)
    expect { l.gen.beat.rock.morph(:funk).morph(:pop) }.to raise_error(ArgumentError, /L\.gen\.beat\.rock\.morph\(L\.gen\.beat\.funk\) is already a morph: a morph blends two generators/)
    expect { l.gen.beat.rock.morph(:funk, :house) }.to raise_error(ArgumentError, /takes one generator to morph into \(got 2; three or more sides are not built yet\)/)
    expect { l.gen.beat.rock.morph(:funk, energy: 0.8) }.to raise_error(ArgumentError, /unknown keyword energy: \(it takes morph:/)
    expect { l.gen.beat.rock.morph(:funk, morph: 2) }.to raise_error(ArgumentError, /morph: is from 0 \(L\.gen\.beat\.rock\) to 1 \(L\.gen\.beat\.funk\)/)
    expect { l.gen.beat.morph(:rock, :funk) }.to raise_error(ArgumentError, /morph is a chain method on a generator: L\.gen\.beat\.rock\.morph\(:funk\)/)
    slots = MB::Sound::Generative::Slots.new(by: :note, grid: 1r / 16, hold: 1, anchors: nil)
    three = MB::Sound::Sequence::Clip.generate(3r / 4, values: [36], slots: slots) { |_c, _d| [[0r, 1r / 16, 36, 0.9]] }
    expect { l.gen.beat.rock.call.morph(three) }.to raise_error(ArgumentError, /L\.gen\.beat\.rock cycles every .+, the clip every .+: a morph needs one cycle length to divide the other/)
  end

  it 'covers every L.gen entry: each morphs with one of its kind (ends exact) and refuses the other kind' do
    expect(l.gen.entries.map(&:name).sort).to eq(KINDS.keys.sort), 'a new generator entry: add it to KINDS (its kind for morphs)'
    rows = ->(c, n) { (0...n).flat_map { |cy| c.events_for(cy).map { |e| [cy, e.start, e.value, e.velocity, e.length] } } }
    KINDS.each do |name, kind|
      a = gen_entry(name).call
      partner = KINDS.find { |n, k| k == kind && n != name }.first
      other = KINDS.find { |_, k| k != kind }.first
      b = gen_entry(partner).call
      long = [a.length, b.length].max
      n = (2 * long).ceil.to_i
      # (ends: the morph cycle plays each side's cycles in turn)
      side_rows = ->(c) { k = (long / c.length).to_i; (0...n * k).flat_map { |cy| c.events_for(cy).map { |e| [cy / k, e.start + (cy % k) * c.length, e.value, e.velocity, e.length] } }.sort_by { |r| [r[0], r[1], r[2]] } }
      ends = [0, 1].map { |t| rows.(a.morph(b, morph: t), n).sort_by { |r| [r[0], r[1], r[2]] } }
      expect(ends[0]).to eq(side_rows.(a)), "#{name} -> #{partner} at 0"
      expect(ends[1]).to eq(side_rows.(b)), "#{name} -> #{partner} at 1"
      expect { rows.(a.morph(b, morph: 0.5), n) }.not_to raise_error
      expect { a.morph(gen_entry(other).call) }.to raise_error(MB::Sound::Generative::Morph::Refused, /plays drum roles and .* plays pitches/)
    end
  end

  it 'gains .morph in help and in the completions of a generator entry (and only there)' do
    text = ->(t) { MB::U.remove_ansi(MB::Sound::Help.topic_page(t).to_s).gsub(/\s+/, ' ') }
    expect(text.(:generative)).to include('L.gen.beat.dnb.morph(L.gen.beat.house)')
    expect(text.(:library)).to include('L.gen.beat.dnb.morph(L.gen.beat.house)')
    expect(MB::Sound::Library::Heads.completions('L.gen.beat.rock.mo')).to eq(['L.gen.beat.rock.morph'])
    expect(MB::Sound::Library::Heads.completions("#{l.fx.entries.first.head_path}.mo")).to eq([])
  end
end
