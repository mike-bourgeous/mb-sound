RSpec.describe(MB::Sound::Session::Strip) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  # Renders +frames+ frames in buffers of +sizes+ (cycled) and returns the
  # mix.
  def run(frames, sizes = [800])
    out = []
    left = frames
    sizes = sizes.cycle
    while left > 0
      n = [sizes.next, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    SpecBuffers.join(out)
  end

  def player(name)
    session.instance_variable_get(:@players).values.find { |p| p.name == name }
  end

  it 'mutes now with a 5 ms declick ramp starting at the next buffer' do
    session.add(1.constant, name: :x)
    run(1600)
    session.mute(:x)
    expect(session.muted?(:x)).to eq(true)

    data = run(1600)
    expect(data[0]).to eq(1)
    expect(data[120]).to be_within(1e-6).of(0.5)
    expect(data[239]).to be_within(1e-6).of(1 / 240.0)
    expect(data[240..].to_a.uniq).to eq([0])
  end

  it 'stops rendering a muted player (it sleeps) and lists it as muted' do
    session.add(1.constant, name: :x)
    session.mute(:x)
    run(1600)
    expect(player(:x).asleep).to eq(true)
    expect(session.players[:x]).to match(/muted/)

    expect(player(:x).input).not_to receive(:read)
    expect(run(8000).to_a.uniq).to eq([0])
  end

  it 'wakes on the unmute sample with its clips back in phase with the timeline' do
    clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::D3, MB::Sound::E3, MB::Sound::F3).n4.loop
    session.add(clip.number, name: :x)
    run(800)
    session.mute(:x)
    run(96000 + 24000 - 1600) # sleeps through more than a bar

    session.unmute(:x, at: :bar)
    data = run(96000 * 2)
    idx = 192000 - 119200 # bar 3 starts at frame 192000; 119200 frames played
    expect(data[0...idx].to_a.uniq).to eq([0])
    # The 5 ms ramp from the bar line, on the clip's first note (C3 = 48)
    expect(data[idx]).to eq(0)
    expect(data[idx + 240]).to eq(MB::Sound::C3.number)
    expect(data[idx + 24000]).to eq(MB::Sound::D3.number)
  end

  describe 'nodes shared between players' do
    # The unused node changes the plan regions; exact plans keep that from
    # changing the LFO's samples (the default :fast sines differ by 3e-8)
    around do |ex|
      old = MB::Sound::Plan.precision
      MB::Sound::Plan.precision = :exact
      ex.run
    ensure
      MB::Sound::Plan.precision = old
    end

    def new_session
      MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false),
        transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
    end

    # Renders +frames+ frames of session +s+ in buffers of +sizes+.
    def run_in(s, frames, sizes)
      out = []
      sizes = sizes.cycle
      while frames > 0
        n = [sizes.next, frames].min
        out << s.process_buffer(n)[0].dup
        frames -= n
      end
      SpecBuffers.join(out)
    end

    # Plays +graphs+ (name => node) in a new Session, mutes :b after 800
    # frames for +muted+ frames, then unmutes it, in buffers of +sizes+;
    # returns the mix after the unmute.
    def mute_and_back(graphs, sizes, muted: 72000)
      s = new_session
      graphs.each { |name, g| s.add(g, name: name) }
      run_in(s, 800, sizes)
      s.mute(:b)
      run_in(s, muted, sizes)
      expect(s.instance_variable_get(:@players).values.find { |p| p.name == :b }.asleep).to eq(true)
      s.unmute(:b)
      run_in(s, 24000, sizes)
    ensure
      s&.close
    end

    # fixes-9: the sleeping player's branch of the shared LFO went unread,
    # so after more than a second (the Tee's CircularBuffer) unmuting raised
    # BranchBufferOverflow.  It now reads that branch while asleep.
    it 'keeps a muted player in step with a node another player plays, at any buffer size' do
      lfo = 3.hz.lfo
      data = mute_and_back({ a: lfo * 0.5, b: lfo * 0.25 }, [128, 801, 7])

      # After the 5 ms unmute ramp, both players play the LFO in phase
      ref = new_session
      ref.add(3.hz.lfo * 0.75)
      expected = run_in(ref, 800 + 72000 + 24000, [800])[-24000..]
      ref.close
      expect(data.abs.max).to be > 0.5
      expect((data[240..] - expected[240..]).abs.max).to be < 1e-6
    end

    # ux-fix-2: every new branch anywhere (the next scene's graphs, built
    # on the scheduler thread) rebuilt every sleeping graph's list by
    # walking every graph, each buffer while a scene was built
    it "keeps a muted player's reads while other graphs are built, and rebuilds them when a shared node gains a reader" do
      s = new_session
      lfo = 3.hz.lfo
      s.add(lfo * 0.5, name: :a)
      s.add(lfo * 0.25, name: :b)
      run_in(s, 800, [800])
      s.mute(:b)
      run_in(s, 1600, [800])
      b = s.instance_variable_get(:@players).values.find { |p| p.name == :b }
      expect(b.asleep).to eq(true)
      cache = b.asleep_reads
      expect(cache.last.length).to eq(1)

      # A graph nothing in the Session plays yet, built from new nodes
      changes = MB::Sound::GraphNode::Tee.branch_changes
      built = 3.times.map { x = 220.hz.saw; x.get_sampler; x.get_sampler; x * 0.5 }
      expect(MB::Sound::GraphNode::Tee.branch_changes).to be > changes
      run_in(s, 1600, [800])
      expect(b.asleep_reads).to equal(cache)

      # A new reader of the shared LFO changes what :b must read for
      reader = lfo.get_sampler
      run_in(s, 800, [800])
      expect(b.asleep_reads).not_to equal(cache)
      expect(b.asleep_reads.last).to eq(cache.last)
      expect(built.length).to eq(3)
      reader.destroy
    ensure
      s&.close
    end

    # omnibus10: the node-set caches above refresh only on
    # GraphNode.structure_changes (Plan.changed); the structure check (on
    # in specs) catches edits that bypass it
    it 'raises when a Session graph changes its nodes without Plan.changed, and not when it calls it' do
      expect(MB::Sound::Session::Strip.structure_check).to eq(true)
      s = new_session
      lfo = 3.hz.lfo
      b = lfo * 0.25
      s.add(lfo * 0.5, name: :a)
      s.add(b, name: :b)
      run_in(s, 800, [800])
      s.mute(:b)
      run_in(s, 1600, [800])

      b.add(2.constant) # (Plan.changed: the caches refresh)
      run_in(s, 1600, [800])

      sneaky = 3.constant
      b.instance_variable_get(:@multiplicands)[sneaky.get_sampler] = sneaky
      expect { run_in(s, 800, [800]) }.to raise_error(MB::Sound::Session::Strip::UnannouncedStructureChange, /without Plan.changed.*added: .*Constant/)
    ensure
      s&.close
    end

    # fixes-11: :b's own branch of the LFO wasn't read while it slept,
    # because the LFO's other branch (inside x) is in :b's graph too
    it 'keeps a muted player in step with a node it reads both directly and through a node another player plays' do
      lfo = 3.hz.lfo
      x = lfo * 2
      data = mute_and_back({ a: x * 0.5, b: x * 0.1 + lfo * 0.1 }, [128, 801, 7])

      ref = new_session
      ref.add(3.hz.lfo * 1.3)
      expected = run_in(ref, 800 + 72000 + 24000, [800])[-24000..]
      ref.close
      expect(data.abs.max).to be > 1
      expect((data[240..] - expected[240..]).abs.max).to be < 1e-6
    end

    it 'starts a queued graph in step with a node it reads both directly and through a node a playing graph plays' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        x = lfo * 2
        s = new_session
        s.add(x * 0.5, name: :a)
        run_in(s, 800, sizes)
        s.add(x * 0.1 + lfo * 0.1, name: :b, fade: 0, on: :bar) # frame 96000
        data = run_in(s, 96000 + 24000 - 800, sizes)[(96000 - 800)..]

        ref = new_session
        ref.add(3.hz.lfo * 1.3)
        expected = run_in(ref, 96000 + 24000, [800])[96000..]
        ref.close
        expect((data - expected).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it "pauses a muted player's node that only unused nodes share" do
      outs = [false, true].map { |extra|
        lfo = 3.hz.lfo
        _unused = lfo * 2 if extra
        mute_and_back({ b: lfo * 0.25 }, [800])
      }
      expect(outs[0].abs.max).to be > 0.2
      expect(outs[1]).to eq(outs[0])
    end

    # The LFO played by :a and :b for +frames+ frames from the start: what
    # the mix should be once a stopped or replaced :b plays again.
    def never_stopped(frames)
      ref = new_session
      ref.add(3.hz.lfo * 0.75)
      run_in(ref, frames, [800])
    ensure
      ref&.close
    end

    # fixes-10: a graph kept for resume wasn't read while stopped, so after
    # more than a second its branch of the shared LFO overflowed and
    # resuming raised BranchBufferOverflow.  It now reads that branch while
    # kept, for exactly the frames since its stop.
    it 'keeps a stopped graph in step with a node a playing graph plays, and resumes it in phase, at any buffer size' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = new_session
        s.add(lfo * 0.5, name: :a)
        s.add(lfo * 0.25, name: :b)
        run_in(s, 800, sizes)
        s.remove(:b, fade: 0, time: 1/4r) # frame 24000, inside a buffer for 801 and 7
        run_in(s, 72000, sizes)
        expect(s.stopped.keys).to eq([:b])
        expect(s.instance_variable_get(:@kept_graphs).length).to eq(1)

        s.resume(:b, fade: 0) # the next bar: frame 96000
        data = run_in(s, 48000, sizes)
        expect(s.instance_variable_get(:@kept_graphs)).to be_empty

        expected = never_stopped(72800 + 48000)[72800..]
        bar = 96000 - 72800
        expect(data.abs.max).to be > 0.7
        expect((data[bar..] - expected[bar..]).abs.max).to be < 1e-6
        expect((data[0...bar] - expected[0...bar] * (0.5 / 0.75)).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it 'keeps a replaced graph in step for undo' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = new_session
        s.add(lfo * 0.5, name: :a)
        s.add(lfo * 0.25, name: :b)
        run_in(s, 800, sizes)
        s.command('bg') { s.add(lfo * 0.1, name: :b, fade: 0, on: :now) }
        run_in(s, 72000, sizes)

        s.undo(on: :now)
        data = run_in(s, 48000, sizes)
        expected = never_stopped(72800 + 48000)[72800..]
        # The undo crossfades over a declick; after it :b is back in phase
        expect(data.abs.max).to be > 0.7
        expect((data[24000..] - expected[24000..]).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it 'keeps graphs that only share a node with each other in step while they are all stopped' do
      lfo = 3.hz.lfo
      s = new_session
      s.add(lfo * 0.5, name: :a)
      s.add(lfo * 0.25, name: :b)
      run_in(s, 800, [801, 7])
      s.remove(:b, fade: 0)
      run_in(s, 72000, [801, 7])
      s.remove(:a, fade: 0)
      run_in(s, 72000, [801, 7])
      s.resume(:a, fade: 0, on: :now)
      run_in(s, 72000, [801, 7])
      s.resume(:b, fade: 0, on: :now)
      data = run_in(s, 24000, [801, 7])

      expected = never_stopped(800 + 72000 * 3 + 24000)[-24000..]
      expect((data - expected).abs.max).to be < 1e-6
    ensure
      s&.close
    end

    it 'stops keeping a graph in step once it is forgotten' do
      lfo = 3.hz.lfo
      s = new_session
      s.add(lfo * 0.5, name: :a)
      s.add(lfo * 0.25, name: :b)
      run_in(s, 800, [800])
      s.remove(:b, fade: 0)
      run_in(s, 800, [800])
      expect(s.instance_variable_get(:@kept_graphs).length).to eq(1)

      s.forget(:b) # not a console command, so no undo step holds it
      run_in(s, 800, [800])
      expect(s.instance_variable_get(:@kept_graphs)).to be_empty
    ensure
      s&.close
    end

    # fixes-11: a graph queued to start later wasn't read while it waited,
    # so it played a node it shares with a playing graph late by its wait,
    # and after more than a second its first read raised
    # BranchBufferOverflow.  Its branches now skip to the playing graph's
    # at every span, and it starts reading the node on its first frame.
    [[0.3, 25_933], [1.5, 800]].each do |wait, added|
      it "starts a graph queued for #{wait} s in step with a node a playing graph plays, at any buffer size" do
        start = added + (wait * 48000).round # not on a buffer edge
        [[128, 801, 7], [800], [7]].each do |sizes|
          lfo = 3.hz.lfo
          s = new_session
          s.add(lfo * 0.5, name: :a)
          data = run_in(s, added, sizes)
          s.add(lfo * 0.25, name: :b, fade: 0, start_time: Rational(start, 96000))
          expect(s.queued.map(&:kind)).to eq([:bg])
          data = data.concatenate(run_in(s, start + 24000 - added, sizes))

          expected = never_stopped(start + 24000)
          expect(data.abs.max).to be > 0.7
          expect((data[start..] - expected[start..]).abs.max).to be < 1e-6
          expect((data[0...start] - expected[0...start] * (0.5 / 0.75)).abs.max).to be < 1e-6
          expect(s.instance_variable_get(:@waiting_graphs)).to be_empty
        ensure
          s&.close
        end
      end
    end

    it 'starts a queued replacement in step with a shared node' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = new_session
        s.add(lfo * 0.5, name: :a)
        s.add(lfo * 0.5, name: :b)
        run_in(s, 800, sizes)
        s.add(lfo * 0.25, name: :b, fade: 0, on: :bar) # frame 96000
        data = run_in(s, 96000 + 24000 - 800, sizes)

        expected = never_stopped(96000 + 24000)[800..]
        bar = 96000 - 800
        expect((data[bar..] - expected[bar..]).abs.max).to be < 1e-6
        expect((data[0...bar] - expected[0...bar] / 0.75).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it 'starts graphs a scene builds ahead in step with a shared node, with a clip swap in the same scene' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = new_session
        set = s.arrangement
        set.track(:a) { |c| lfo * 0.5 + c.number * 0.001 }
        set.track(:b) { |c| lfo * 0.25 + c.number * 0.0001 }
        set.scene(:one, a: MB::Sound.seq(MB::Sound::C3).n1.loop)
        set.scene(:two, a: MB::Sound.seq(MB::Sound::D3).n1.loop, b: MB::Sound.seq(MB::Sound::C4).n1.loop)
        set.go(:one, at: :now)
        run_in(s, 800, sizes)
        a_graph = s.instance_variable_get(:@players).values.find { |p| p.name == :a }.input
        set.go(:two) # frame 96000, built half a bar ahead
        data = run_in(s, 96000 + 24000 * 3 - 800, sizes)
        expect(s.instance_variable_get(:@players).values.find { |p| p.name == :a && p.current? }.input).to equal(a_graph)

        expected = never_stopped(96000 + 24000 * 3)[800..]
        bar = 96000 - 800
        notes = Numo::SFloat.zeros(data.length).fill(MB::Sound::C3.number * 0.001)
        notes[bar..] = MB::Sound::D3.number * 0.001 + MB::Sound::C4.number * 0.0001
        expect((data[bar..] - notes[bar..] - expected[bar..]).abs.max).to be < 1e-6
        expect((data[0...bar] - notes[0...bar] - expected[0...bar] * (0.5 / 0.75)).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end
  end

  it 'mutes at a launch point over a fade in bars (synced fade)' do
    session.add(1.constant, name: :x)
    run(800)
    session.mute(:x, at: :bar, fade: 1/2r)
    expect(session.strip_info[:queued].map(&:kind)).to eq([:mute])

    data = run(96000 * 2)
    start = 96000 - 800
    expect(data[start - 1]).to eq(1)
    expect(data[start]).to eq(1)
    expect(data[start + 24000]).to be_within(1e-6).of(0.5)
    expect(data[start + 48000..].to_a.uniq).to eq([0])
  end

  it 'solos players, silencing the others, and clears solos' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    session.add(4.constant, name: :c)
    run(800)

    session.solo(:b, :c)
    expect(run(1600)[-1]).to eq(6)
    expect(session.audible?(:a)).to eq(false)

    session.solo
    expect(run(1600)[-1]).to eq(7)
    expect(session.strip_info[:soloed]).to eq([])
  end

  it 'clears every solo that has landed when the clear lands, even one queued before it' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    run(800)
    session.solo(:a, start_time: 1/2r)
    session.command('solo') { session.solo(start_time: 3/4r) } # clears all: :a's solo hasn't landed yet
    expect(session.strip_info[:soloed]).to eq([])
    data = run(96000)
    expect(data[48000 - 800 + 300]).to eq(1)
    expect(data[72000 - 800 + 300]).to eq(3)
    expect(session.strip_info[:soloed]).to eq([])
    expect(session.journal.changes.last).to have_attributes(kind: :unsolo, subject: :strip, status: :landed)

    session.undo(at: :now)
    expect(run(1600)[-1]).to eq(1)
  end

  it 'mutes groups of players' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    session.add(4.constant, name: :c)
    session.mute_group(:breakdown, :a, :b)
    session.mute(:breakdown)
    expect(run(1600)[-1]).to eq(4)
    session.unmute(:breakdown)
    expect(run(1600)[-1]).to eq(7)
    expect(session.mute_groups).to eq(breakdown: [:a, :b])
  end

  it 'starts a graph replacing a muted one muted' do
    session.add(1.constant, name: :x)
    session.mute(:x)
    run(1600)
    session.add(2.constant, name: :x, at: :now)
    expect(run(1600).to_a.uniq).to eq([0])
    session.unmute(:x)
    expect(run(1600)[-1]).to eq(2)
  end

  it 'lands mutes, solos, and fades on the same samples at any buffer size' do
    renders = [[800], [367, 368], [64], [1001, 13]].map { |sizes|
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: t, channels: 1, buffer_size: 800, realtime: false, raise_errors: true, fade_in: 1/4r, fade_out: 1/2r)
      # Sources that don't depend on the buffer size themselves (Tone phases
      # accumulate per buffer, differing by ~1e-12 across buffer sizes)
      s.add(MB::Sound.seq(MB::Sound::C3, MB::Sound::G3).n8.loop.number, name: :a)
      s.add(0.25.constant, name: :b, start_time: 1/8r)
      s.mute(:a, start_time: 1/3r, fade: 1/16r)
      s.solo(:a, start_time: 1/2r)
      s.unmute(:a, start_time: 5/8r)
      s.remove(:a, time: 7/8r)
      out = []
      left = 96000 * 2
      cycle = sizes.cycle
      while left > 0
        n = [cycle.next, left].min
        out << s.process_buffer(n)[0].dup
        left -= n
      end
      s.close
      SpecBuffers.join(out)
    }

    expect(renders[0].abs.max).to be > 40
    renders[1..].each do |r|
      expect((r - renders[0]).abs.max).to eq(0)
    end
  end
end
