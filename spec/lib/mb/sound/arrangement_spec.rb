RSpec.describe(MB::Sound::Arrangement) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:set) { session.arrangement }

  # One note per bar, so a track's output is its note number
  let(:a1) { MB::Sound.seq(MB::Sound::C3).n1.loop }
  let(:a2) { MB::Sound.seq(MB::Sound::D3).n1.loop }
  let(:b1) { MB::Sound.seq(MB::Sound::C4).n1.loop }

  after { session.close }

  # Runs the block with +session+ as the current session.
  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  # Returns [sample index, value] for each change in +data+.
  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v.round(3)] }
  end

  # The knob +name+ of the current session (a sandbox's copy while a
  # warm-up builds).
  def within_knob(name)
    MB::Sound::Session.current.knob(name)
  end

  def player(name)
    session.instance_variable_get(:@players).values.select { |p| p.name == name && p.current? }.last
  end

  before do
    set.track(:a) { |c| c.number }
    set.track(:b) { |c| c.number * 100 }
    set.scene(:one, a: a1)
    set.scene(:two, a: a2, b: b1)
  end

  it 'launches scenes on the next bar, changing only what differs' do
    set.go(:one, at: :now)
    run(1600)
    graph = player(:a).input

    entry = set.go(:two)
    expect(entry.to_s).to eq('scene :two lands 2:1 (queued)')

    data = run(96000)
    expect(changes(data)).to eq([[0, 48], [96000 - 1600, 50 + 6000]])
    expect(player(:a).input).to equal(graph) # swapped, not rebuilt

    # Launching the same scene again changes nothing
    set.go(:two)
    expect(session.queued.map(&:kind)).to eq([:scene])
    expect(set.current_scene).to eq(:two)
  end

  it 'silences kit rows the next scene\'s kit leaves out, swapping the rest' do
    full = MB::Sound.grid(4, kick: 'X...', hat: '..x.').loop
    hats = MB::Sound.grid(4, hat: '..x.').loop
    set.track(:k) { |kit| MB::Sound.tr808(kit, kick: { decay: 0.1 }) }
    set.scene(:full, k: full, others: :keep)
    set.scene(:hats, k: hats, others: :keep)
    within { set.go(:full, at: :now) }
    bar1 = run(96000)
    graph = player(:k).input
    within { set.go(:hats) }
    bar2 = run(96000)
    expect(player(:k).input).to equal(graph) # swapped, not rebuilt
    # (before patches-5 the kick row, missing from the new kit, played on)
    expect(bar1[0...12000].abs.max).to be > 0.3
    expect(bar2[1600...12000].abs.max).to be < 0.01
    expect(bar2[48000...60000].abs.max).to be > 0.01 # the hat
  end

  it 'stops tracks the scene leaves out, with a declick for others: :cut, unless others: :keep' do
    set.scene(:keep_a, b: b1, others: :keep)
    set.scene(:one_cut, a: a1, others: :cut)
    set.go(:two, at: :now)
    run(800)
    set.go(:one_cut)
    data = run(96000)
    bar = 96000 - 800
    expect(data[bar - 1]).to eq(50 + 6000)
    expect(data[bar + 240..].to_a.uniq).to eq([48]) # b faded out over 5 ms
    expect(session.stopped.keys).to eq([:b])

    set.go(:keep_a)
    run(96000)
    expect(run(800)[-1]).to eq(48 + 6000)
  end

  it 'uses each track\'s launch quantization, then the scene\'s, then the set\'s' do
    set.track(:b, q: 2) { |c| c.number * 100 }
    set.go(:one, at: :now)
    run(800)
    set.go(:two)
    data = run(96000 * 2)
    expect(changes(data)).to eq([[0, 48], [96000 - 800, 50], [192000 - 800, 50 + 6000]])
  end

  it 'lands launches inside scheduled blocks at the block time' do
    set.go(:one, at: :now)
    within { MB::Sound.at_bar(3) { MB::Sound.go(:two) } }
    data = run(96000 * 3)
    expect(changes(data)).to eq([[0, 48], [192000, 50 + 6000]])
  end

  it 'runs a scene block at the launch time' do
    set.scene(:three, a: a1) { |t| MB::Sound.bg(:x, 0.5.constant, fade: 0) }
    set.go(:one, at: :now)
    run(800)
    set.go(:three)
    data = run(96000)
    expect(changes(data)).to eq([[0, 48], [96000 - 800, 48.5]])
  end

  it 'plays a clip on a track with bg' do
    within do
      MB::Sound.bg(:b, b1)
    end
    expect(set.tracks[:b].clip).to equal(b1)
    expect(run(800)[0]).to eq(6000)
  end

  it 'keeps tracks and mute groups in one namespace, raising for collisions in scripts' do
    expect { session.mute_group(:a, :b) }.to raise_error(ArgumentError, /:a is already a track/)
    session.mute_group(:both, :a, :b)
    expect { set.track(:both) { |c| c.number } }.to raise_error(ArgumentError, /:both is already a group/)
    expect { set.scene(:bad, both: a1) }.to raise_error(ArgumentError, /:both is a group, not a track/)
    expect { set.track(:master) { |c| c.number } }.to raise_error(ArgumentError, /reserved/)
  end

  it 'warns instead of raising in live mode' do
    MB::Sound.live = true
    expect { expect(set.track(:a, 1.constant)).to eq(:a) }.not_to output.to_stderr # same kind again is fine
    session.mute_group(:grp, :a)
    expect { expect(set.track(:grp) { |c| c.number }).to be_nil }.to output(/already a group/).to_stderr
    expect { expect(set.go(:nope)).to be_nil }.to output(/No scene :nope/).to_stderr
  ensure
    MB::Sound.live = false
  end

  it 'raises for scenes naming unknown tracks when launched' do
    set.scene(:typo, c: a1)
    expect { set.go(:typo) }.to raise_error(ArgumentError, /:c, which is not a track/)
  end

  it 'lists tracks and scenes' do
    a1.named(:a1)
    a2.named('a2')
    set.go(:one, at: :now)
    expect(set.track_info).to eq(a: 'q:1 a1 (playing)', b: 'q:1 no clip (stopped)')
    expect(set.scene_info).to eq(one: '▶ a:a1', two: 'a:a2 b:seq')
  end

  it 'lists Symbol values with a space after the colon' do
    # 2026-10-12: `pad: :on` was listed as "pad::on"
    set.scene(:three, a: :on, b: :off, q: :beat)
    set.quant = :beat
    expect(set.scene_info[:three]).to eq('a: :on b: :off q: :beat')
    expect(set.track_info[:a]).to start_with('q: :beat ')
  end

  it 'counts plain numbers as bars and accepts Durations for launch points' do
    transport.bar_length = 3/4r
    set.go(:one, at: :now)
    run(800)
    expect(set.resolve(2)).to eq(3/2r)
    expect(set.resolve(MB::Sound::Sequence::Duration.new(1/4r))).to eq(1/4r)
    expect(set.resolve(:bar)).to eq(3/4r)
  end

  describe 'fills on launch-aligned loops' do
    # 126 BPM: bar lines fall between samples (91428.57 frames per bar), so a
    # launch lands on the sample before its exact time
    let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 126) }

    it 'plays a fill-marked note in the fill\'s bar after an off-sample launch (was a bar early)' do
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::C3, MB::Sound::C3, MB::Sound::D3.fill(:f)).n4.loop(align: :launch)
      set.track(:p) { |c| c.gate * c.number }
      set.scene(:pa, p: clip)
      session.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
      transport.fills.add(3r, 4r, :f) # bar 4
      set.go(:pa, in: 1)
      d = run(800 * 500) # 4.4 bars
      bar = 48000 * 240 / 126r
      fill_frames = (0...d.length).select { |i| d[i] == 50 }
      expect(fill_frames).not_to be_empty
      expect(fill_frames.first).to be >= (bar * 3.75).floor
      expect(fill_frames.last).to be < (bar * 4).ceil
    end
  end

  describe 'lead: and nudge:' do
    # Note edges (gate * note number) of track :p over two scenes
    def edges_with(size: 800, **options)
      set.track(:p, **options) { |c| c.gate * c.number }
      quarter = ->(n) { MB::Sound.seq(n, MB::Sound::Rest).n8.loop }
      set.scene(:pa, p: quarter.(MB::Sound::C3))
      set.scene(:pb, p: quarter.(MB::Sound::D3))
      session.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
      set.go(:pa, in: 1)
      d = []
      d << session.process_buffer(size)[0].dup while d.sum(&:length) < 96000 * 1.5
      set.go(:pb)
      d << session.process_buffer(size)[0].dup while d.sum(&:length) < 96000 * 3
      changes(d.reduce(:concatenate)).first(6)
    end

    it 'plays a track early, launching and swapping early, the same at any buffer size' do
      expected = [[0, 0], [72000, 48], [84000, 0], [96000, 48], [108000, 0], [120000, 48]]
      expect(edges_with(lead: 1.beat)).to eq(expected)
      expect(set.ahead(:p)).to eq(1/4r)
    end

    it 'is the same at other buffer sizes' do
      expect(edges_with(lead: 1.beat, size: 367)).to eq([[0, 0], [72000, 48], [84000, 0], [96000, 48], [108000, 0], [120000, 48]])
    end

    it 'leads by the attack of the patch\'s amplitude envelope with lead: :attack' do
      set.track(:p, lead: :attack) { |c| c.number * c.amp_env(0.25, 0.1, 1, 0.1) }
      set.scene(:pa, p: a1)
      session.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
      set.go(:pa, in: 1)
      d = run(96000 * 2)
      expect(set.ahead(:p)).to eq(1/8r) # 0.25 s at 120 BPM
      start = 96000 - 12000
      expect(d[start - 1]).to eq(0)
      expect(d[start + 1]).to be > 0
      peak = d[start...(start + 20000)].max_index + start
      expect(peak).to be_within(2).of(96000) # peaks on the downbeat
    end

    it 'leads by a fraction of the attack with lead: 0.5.attack, the same at any buffer size' do
      firsts = [800, 367].map do |size|
        s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: size, realtime: false, raise_errors: true)
        a = s.arrangement
        a.track(:p, lead: 0.5.attack) { |c| c.number * c.amp_env(0.25, 0.1, 1, 0.1) }
        a.scene(:pa, p: a1)
        s.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
        a.go(:pa, in: 1)
        d = []
        d << s.process_buffer(size)[0].dup while d.sum(&:length) < 96000 * 2
        d = d.reduce(:concatenate)
        expect(a.ahead(:p)).to eq(1/16r) # half of 0.25 s at 120 BPM
        expect(a.track_info[:p]).to include('ahead 125 ms')
        [(1...d.length).find { |i| d[i] != 0 }, d[0...96000 * 2].dup]
      ensure
        s&.close
      end
      expect(firsts[0][0]).to be_within(1).of(96000 - 6000)
      expect(firsts[1][0]).to eq(firsts[0][0])
      expect(firsts[1][1].to_a).to eq(firsts[0][1].to_a)

      expect { set.track(:q, lead: 0.attack) { |c| c.number } }.to raise_error(ArgumentError, /above 0/)
      expect { set.track(:q, lead: { attack: 0.5 }) { |c| c.number } }.to raise_error(ArgumentError, /0.5.attack/)
      expect { set.track(:q, lead: 0.5.attack, lead_max: 2) { |c| c.number } }.not_to raise_error
      expect(set.tracks[:q].lead).to eq(0.5.attack)
      set.track(:r, lead: :attack) { |c| c.number }
      expect(set.tracks[:r].lead).to eq(1.attack)
    end

    it 'measures a synth voice\'s GM2-scaled amp_env by its attack as given' do
      set.track(:v, lead: :attack) { |c| c.synth(voices: 1) { |v| v.hz.sine * v.amp_env(0.5, 0.1, 1, 0.1) } }
      set.track(:w, lead: 0.5.attack) { |c| c.synth(voices: 1) { |v| v.hz.sine * v.amp_env(0.5, 0.1, 1, 0.1) } }
      set.scene(:all, v: a1, w: a1)
      session.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
      set.go(:all, in: 1)
      run(800)
      expect(set.ahead(:v)).to eq(1/4r) # 0.5 s at 120 BPM (was 0: the attack is a node, time x CC 73)
      expect(set.ahead(:w)).to eq(1/8r)
    end

    it 'caps an attack lead at 1 bar unless lead_max: says otherwise' do
      set.track(:slow, lead: :attack) { |c| c.number * c.amp_env(4, 0.1, 1, 0.1) }
      set.track(:slower, lead: :attack, lead_max: 2) { |c| c.number * c.amp_env(5, 0.1, 1, 0.1) }
      set.track(:short, lead: :attack, lead_max: 1.beat) { |c| c.number * c.amp_env(0.25, 0.1, 1, 0.1) }
      set.scene(:all, slow: a1, slower: a1, short: a1)
      session.add(MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000), name: :clock, on: :now)
      set.go(:all, in: 1)
      run(800)
      expect(set.ahead(:slow)).to eq(1r) # 4 s = 2 bars at 120 BPM, capped at 1
      expect(set.ahead(:slower)).to eq(2r) # 5 s capped at 2 bars
      expect(set.ahead(:short)).to eq(1/8r) # under its cap
      expect(set.track_info[:slow]).to include('ahead 2000 ms (attack capped)')
      expect(set.track_info[:short]).not_to include('capped')
      expect { set.track(:q, lead: 1, lead_max: 2) { |c| c.number } }.to raise_error(ArgumentError, /caps an attack lead/)
      expect { set.track(:q, lead: :attack, lead_max: 0) { |c| c.number } }.to raise_error(ArgumentError, /more than 0/)
    end

    it 'nudges notes late (or early) by a fixed time' do
      expect(edges_with(nudge: 10.ms)).to eq([[0, 0], [96480, 48], [108480, 0], [120480, 48], [132480, 0], [144480, 48]])
      expect { set.track(:q, nudge: 3) { |c| c.number } }.to raise_error(ArgumentError, /Length or Duration/)
      expect { set.track(:q, lead: :soon) { |c| c.number } }.to raise_error(ArgumentError, /:attack/)
    end
  end

  describe '#warm_up' do
    it "builds and plays each patch per scene clip in a sandbox, and keeps the root generator's draws" do
      built = []
      set.track(:c) { |c| built << c; MB::Sound.synth(c, voices: 1) { |v| v.hz.saw.rnd * v.amp_env } }
      set.scene(:three, c: a1)
      set.scene(:four, c: b1, a: a1)

      MB::Sound.seed(42)
      expected = MB::Sound.with_seed(42) { MB::Sound.next_seed }
      result = set.warm_up
      expect(result.keys).to contain_exactly(:a, :b, :c)
      expect(result.values.map(&:last)).to all(eq(:played))
      expect(built).to eq([a1, a1, b1, b1]) # twice each, to look for shared nodes
      expect(MB::Sound.next_seed).to eq(expected)
      expect(session.players).to be_empty
      expect(session.journal.changes).to be_empty
      expect(transport.position).to eq(0)

      # Already warmed: skipped, unless again
      expect(set.warm_up).to eq({})
      expect(set.warm_up(:c, again: true, play: false).keys).to eq([:c])
      expect(built.length).to eq(6) # a1 and b1 once each

      # A redefined patch is warmed again
      set.track(:c) { |c| built << c; c.tone.ramp }
      expect(set.warm_up.keys).to eq([:c])
    end

    it 'only builds patches that reach nodes made outside them, and reads copies of knobs' do
      lfo = 2.hz.lfo
      before_lfo = lfo.sample(10).dup
      cut = within { session.knob(:cut, 500, range: 100..5000, curve: :exp) }
      set.track(:shared) { |c| c.tone.ramp * lfo }
      set.track(:knobbed) { |c| c.tone.ramp.filter(:lowpass, cutoff: within_knob(:cut)) }
      set.scene(:five, shared: a1, knobbed: b1)

      result = set.warm_up(:shared, :knobbed)
      expect(result[:shared].last).to eq(:built)
      expect(result[:knobbed].last).to eq(:played)
      # Neither the captured node nor the live knob moved
      lfo2 = 2.hz.lfo
      lfo2.sample(10)
      expect(lfo.sample(10)).to eq(lfo2.sample(10))
      expect(cut.next_frame).to eq(0)
      expect(before_lfo.length).to eq(10)
    end

    it 'refuses while something plays' do
      within { set.go(:one) }
      run(800)
      expect { set.warm_up }.to raise_error(RuntimeError, /before anything plays/)
    end

    it 'renders the same with and without it' do
      render = ->(warm) {
        s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
        a = s.arrangement
        MB::Sound.seed(7)
        a.track(:n) { |c| MB::Sound.synth(c, voices: 2) { |v| (v.hz.ramp.rnd + MB::Sound.noise * 0.1) * v.amp_env(0.01, 0.1, 0.5, 0.1) } }
        a.scene(:x, n: MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop)
        a.scene(:y, n: MB::Sound.seq(MB::Sound::G3).n8.loop)
        a.warm_up if warm
        MB::Sound::Session.with_context(session: s) { a.play_form(MB::Sound::Form.build { x 1; y 1 }, warm_up: false) }
        data = Array.new(240) { s.process_buffer[0].dup }.reduce(:concatenate)
        s.close
        data
      }
      plain = render.(false)
      expect(plain.abs.max).to be > 0.1
      expect(render.(true)).to eq(plain)
    end

    it 'runs when a form starts only in an idle realtime session with YJIT' do
      expect(set).not_to receive(:warm_up)
      within { set.play_form(MB::Sound::Form.build { one 1 }) }
    end

    it 'runs when a form starts with warm_up: true, printing one line' do
      expect { within { set.play_form(MB::Sound::Form.build { one 1; two 1 }, warm_up: true) } }.to output(
        /Warmed up 2 tracks in \d+\.\d s \(skip with warm_up: false\)/
      ).to_stdout
    end

    it 'says how many tracks were only built' do
      lfo = 2.hz.lfo
      set.track(:shared) { |c| c.tone.ramp * lfo }
      set.scene(:three, shared: a1)
      expect { within { set.play_form(MB::Sound::Form.build { three 1 }, warm_up: true) } }.to output(
        /Warmed up 3 tracks in \d+\.\d s \(1 only built, reaching nodes made outside their patch; skip with warm_up: false\)/
      ).to_stdout
    end

    it 'is skipped with warm_up: false from the console flow' do
      allow(session).to receive(:realtime?).and_return(true)
      expect(set).not_to receive(:warm_up)
      within { MB::Sound.flow(warm_up: false) { one 1 } }
      expect { within { MB::Sound.flow(warm_up: :maybe) { one 1 } } }.to raise_error(ArgumentError, /warm_up: must be/)
    end
  end
end
