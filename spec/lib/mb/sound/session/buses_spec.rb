RSpec.describe(MB::Sound::Session::Buses) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # A session with its own timeline (+transport+ for the default one).
  def new_session(channels: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    out = MB::Sound::NullOutput.new(channels: channels, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: channels, buffer_size: 800, realtime: false, raise_errors: true)
  end

  let(:session) { new_session(transport: transport) }

  after { session.close }

  # Renders +frames+ frames in buffers of +sizes+ (cycled) and returns the
  # mix's first channel (or every channel with +all+).
  def run(frames, sizes = [800], s: session, all: false)
    out = []
    left = frames
    sizes = sizes.cycle
    while left > 0
      n = [sizes.next, left].min
      out << s.process_buffer(n).map(&:dup)
      left -= n
    end
    chans = out.transpose.map { |c| SpecBuffers.join(c) }
    all ? chans : chans[0]
  end

  def bus_struct(name, s: session)
    s.instance_variable_get(:@buses)[name]
  end

  describe 'sends' do
    it 'adds a player times its send level into the bus, and the bus output into the mix' do
      session.bus(:half) { |sig| sig * 0.5 }
      session.add(1.constant, name: :x, send: { half: 0.5 })
      data = run(1600)
      expect(data.to_a.uniq).to eq([1.25])
    end

    it 'routes a main out into a bus instead of the master with to:' do
      session.bus(:half) { |sig| sig * 0.5 }
      session.add(1.constant, name: :x, to: :half)
      expect(run(800).to_a.uniq).to eq([0.5])
    end

    it 'feeds buses into buses in routing order, whatever order they were defined in' do
      session.bus(:last) { |sig| sig * 3 }
      session.bus(:first, to: :last) { |sig| sig * 2 }
      session.add(1.constant, name: :x, to: :first)
      expect(run(800).to_a.uniq).to eq([6])
    end

    it 'keeps routing when a graph replaces the player' do
      session.bus(:b) { |sig| sig * 0.25 }
      session.add(1.constant, name: :x, send: { b: 1 })
      run(800)
      session.add(2.constant, name: :x, on: :now, fade: 0)
      expect(run(800).to_a.uniq).to eq([2.5])
    end

    it 'refuses loops of buses' do
      session.bus(:a) { |sig| sig }
      session.bus(:b, to: :a) { |sig| sig }
      expect { session.bus(:a, to: :b) { |sig| sig } }.to raise_error(ArgumentError, /loop/)
      expect(bus_struct(:a).to).to be_nil
    end

    it 'refuses unknown buses with suggestions' do
      session.bus(:verb) { |sig| sig }
      expect { session.add(1.constant, name: :x, send: { verbb: 0.5 }) }.to raise_error(ArgumentError, /no bus :verbb.*verb/m)
    end

    it 'refuses negative send levels (write -6.db)' do
      session.bus(:b) { |sig| sig }
      expect { session.route(:x, send: { b: -6 }) }.to raise_error(ArgumentError, /-6\.db/)
    end

    it 'shares the namespace with tracks and knobs' do
      session.knob(:space, 0.5)
      expect { session.bus(:space) { |sig| sig } }.to raise_error(ArgumentError, /already a knob/)
    end
  end

  describe '#feed' do
    def feed_run(sizes)
      s = new_session
      s.bus(:b) { |sig| sig }
      s.add(1.constant, name: :x, to: :b, send: { b: 0 })
      run(1000, sizes, s: s)
      s.feed(:x, :b, 1.0, over: 1.n4, on: :now)
      data = run(30000, sizes, s: s)
      s.close
      data
    end

    it 'ramps a send on exact frames at any buffer size' do
      a = feed_run([800])
      expect(feed_run([367, 368])).to eq(a)
      expect(feed_run([64])).to eq(a)
      expect(a[0]).to be_within(1e-4).of(1) # the ramp's first frame
      expect(a[-1]).to be_within(1e-6).of(2)
      expect(a[12000]).to be_within(1e-3).of(1.5)
    end

    it 'is journaled and undoable' do
      session.bus(:b) { |sig| sig }
      session.add(1.constant, name: :x, send: { b: 0.5 })
      run(800)
      _, changes = session.command('feed') { session.feed(:x, :b, 0.25) }
      expect(changes.map(&:kind)).to eq([:send])
      expect(changes[0].entry.to_s).to match(/send :x/)
      run(4800)
      expect(run(800)[-1]).to be_within(1e-6).of(1.25)

      session.undo(on: :now)
      run(4800)
      expect(run(800)[-1]).to be_within(1e-6).of(1.5)
    end

    it 'follows a knob' do
      session.knob(:amount, 0.5)
      session.bus(:b) { |sig| sig }
      session.add(1.constant, name: :x, send: { b: :amount })
      run(800)
      expect(run(800)[-1]).to be_within(1e-6).of(1.5)
      session.turn(:amount, 1, smooth: 0)
      run(800)
      expect(run(800)[-1]).to be_within(1e-6).of(2)
    end
  end

  describe 'pre-fader sends' do
    # A session where :x (a constant 1) sends to :half (a bus halving its
    # input) with +send+, its dry sound turned off by its level.
    def pre_session(send: { half: [1, :pre] }, level: 0, fade: false)
      s = new_session
      s.bus(:half) { |sig| sig * 0.5 }
      s.add(1.constant, name: :x, send: send, fade: fade)
      s.level(:x, level) if level
      s
    end

    it 'keeps sending with the track level at 0, where a post-fader send stops' do
      s = pre_session
      expect(run(1600, s: s).to_a.uniq).to eq([0.5])
      s.close

      s = pre_session(send: { half: 1 })
      expect(run(1600, s: s).to_a.uniq).to eq([0])
      s.close
    end

    it 'hears what a post-fader send at unity hears, fades included, bit for bit at any buffer size' do
      # (pre: level 0, so only the bus is heard; post: level 1, the dry
      # sound into a bus that silences it)
      results = [[800], *slow_tier([[367, 368], [7, 128, 333]])].flat_map { |sizes|
        [[{ half: [1, :pre] }, 0, :keep], [{ half: 1 }, nil, :sink]].map { |send, level, to|
          s = new_session
          s.bus(:sink) { |sig| sig * 0 }
          s.bus(:half) { |sig| sig * 0.5 }
          s.add(1.constant, name: :x, send: send, fade: 1/8r, to: to)
          s.level(:x, level) if level
          s.remove(:x, fade: 1/8r, time: 1/4r)
          d = run(48000, sizes, s: s)
          s.close
          d
        }
      }
      results.each { |d| expect(d).to eq(results[0]) }
      d = results[0]
      expect(d[6000]).to be_within(1e-6).of(0.25) # halfway through the fade in
      expect(d[12000 + 6000]).to be_within(1e-6).of(0.5)
      expect(d[24000 + 6000]).to be_within(1e-6).of(0.25) # halfway through the fade out
      expect(d[36000..].abs.max).to eq(0)
    end

    it 'sends nothing from a muted or soloed-away track (pre-fader, post-mute)' do
      s = pre_session
      s.add(0.25.constant, name: :y)
      run(800, s: s)
      s.mute(:x)
      run(4800, s: s)
      expect(run(800, s: s).to_a.uniq).to eq([0.25]) # only :y
      s.unmute(:x)
      run(4800, s: s)
      expect(run(800, s: s).to_a.uniq).to eq([0.75])
      s.solo(:y)
      run(4800, s: s)
      expect(run(800, s: s).to_a.uniq).to eq([0.25])
      s.close
    end

    it 'switches to pre-fader and back with feed on the exact landing frame at any buffer size' do
      results = [[800], *slow_tier([[367, 368], [7, 128, 333]])].map { |sizes|
        s = pre_session(send: { half: 1 })
        s.feed(:x, :half, nil, pre: true, start_time: 1/16r) # frame 6000
        s.feed(:x, :half, 0.5, pre: false, start_time: 3/16r) # frame 18000: post-fader again, where the level 0 silences it
        d = run(30000, sizes, s: s)
        s.close
        d
      }
      results.each { |d| expect(d).to eq(results[0]) }
      d = results[0]
      expect(d[0...6000].abs.max).to eq(0) # (the switch glides from its landing frame, over 5 ms)
      expect(d[6000]).to be > 0
      expect(d[6000 + 120]).to be_between(0.1, 0.4)
      expect(d[7000...18000].to_a.uniq).to eq([0.5])
      expect(d[18000 + 120]).to be_between(0.05, 0.4)
      expect(d[18000 + 480..].abs.max).to eq(0)
    end

    it 'sends nothing from a cue player (CUE is dry: MAIN 0 zeroes pre-fader sends too)' do
      session.bus(:half) { |sig| sig * 0.5 }
      session.route(:b, send: { half: [1, :pre] })
      session.route(:"b/cue", send: { half: [1, :pre] })
      session.level(:b, 0)
      session.cue_player(:b, 1.constant, start_time: 0)
      expect(run(1600).to_a.uniq).to eq([0])
    end

    it 'ramps a pre-fader send with over: like a post-fader one' do
      s = pre_session(send: { half: [0, :pre] })
      run(800, s: s)
      s.feed(:x, :half, 1.0, over: 1.n4, on: :now)
      d = run(24000, s: s)
      s.close
      expect(d[12000]).to be_within(1e-3).of(0.25)
      expect(d[-1]).to be_within(1e-4).of(0.5)
    end

    it 'is journaled with its mode, undoable, and redoable' do
      session.bus(:half) { |sig| sig * 0.5 }
      session.add(1.constant, name: :x, send: { half: 1 })
      session.level(:x, 0)
      run(4800)
      _, changes = session.command('feed') { MB::Sound::Session.with_context(session: session) { MB::Sound.feed(:x, :half, pre: true) } }
      expect(changes.map(&:kind)).to eq([:send])
      expect(changes[0].entry.data).to include(bus: :half, pre: true)
      run(4800)
      expect(run(800).to_a.uniq).to eq([0.5])
      expect(session.routes[:x][:send]).to eq(half: [1.0, :pre])

      session.undo(on: :now)
      run(4800)
      expect(run(800).to_a.uniq).to eq([0])
      expect(session.routes[:x][:send]).to eq(half: 1.0)

      session.redo(on: :now)
      run(4800)
      expect(run(800).to_a.uniq).to eq([0.5])
    end

    it 'takes [level, :pre] in feed and refuses other modes with a suggestion' do
      s = pre_session(send: { half: 1 })
      s.feed(:x, :half, [0.5, :pre], on: :now)
      run(4800, s: s)
      expect(run(800, s: s).to_a.uniq).to eq([0.25])
      expect { s.feed(:x, :half, [0.5, :pree]) }.to raise_error(ArgumentError, /\[level, :pre\].*:pre/m)
      expect { s.feed(:x, :half, [0.5, :post], pre: true) }.to raise_error(ArgumentError, /disagree/)
      expect { s.feed(:x, :half, nil) }.to raise_error(ArgumentError, /needs a level/)
      expect { s.route(:x, send: { half: [0.5, :pre, 1] }) }.to raise_error(ArgumentError, /\[level, :pre\]/)
      expect { s.route(:x, send: { half: [-0.5, :pre] }) }.to raise_error(ArgumentError, /-6\.db/)
      s.close
    end

    it 'follows a knob pre-fader and lists it' do
      session.knob(:amount, 0.5)
      session.bus(:half) { |sig| sig * 0.5 }
      session.add(1.constant, name: :x, send: { half: [:amount, :pre] })
      session.level(:x, 0)
      run(800)
      expect(run(800).to_a.uniq).to eq([0.25])
      expect(session.routes[:x][:send]).to eq(half: ['knob(:amount)', :pre])
      expect(session.route_definitions[:x][:send]).to eq(half: [:amount, :pre])
    end

    it 'goes into stems at level 0 (the track as heard: its bus share alone)' do
      Dir.mktmpdir do |dir|
        MB::Sound.render(File.join(dir, 'mix.flac'), channels: 1, gain: 1, seconds: 0.5, stems: dir) do
          MB::Sound.bus(:half) { |sig| sig * 0.5 }
          MB::Sound.bg(:x, 0.25.constant, send: { half: [1, :pre] }, fade: 0)
          MB::Sound.level(:x, 0)
        end
        x = MB::Sound.read(File.join(dir, 'x.flac'))[0]
        mix = MB::Sound.read(File.join(dir, 'mix.flac'))[0]
        expect(x[2000]).to be_within(1e-4).of(0.125)
        expect((x - mix).abs.max).to be < 1e-4
      end
    end

    it 'saves to set documents, which load it back' do
      text = nil
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.bus(:half) { |sig| sig * 0.5 }
        MB::Sound.track(:pad, 1.constant, send: { half: [-6.db, :pre] })
        MB::Sound.scene(:a, pad: :on)
        MB::Sound.level(:pad, 0)
      end
      run(800) # (knobs save where they are: the level lands first)
      MB::Sound::Session.with_context(session: session) { text = MB::Sound::GraphIO::SetWriter.new(session.arrangement).to_s }
      expect(text).to match(/^graph #{MB::Sound::GraphIO::FORMAT},/)
      expect(text).to include('send: { half: [-6.db, :pre] }')
      s2 = new_session
      MB::Sound::Session.with_context(session: s2) { MB::Sound::GraphIO.load(text, session: s2); MB::Sound.go(:a, on: :now) }
      run(4800, s: s2)
      expect(s2.routes[:pad]).to eq(session.routes[:pad])
      expect(run(800, s: s2)[-1]).to be_within(1e-6).of(0.5 * -6.db)
      s2.close
    end

    it 'shows in the buses pane as a pre-fader send' do
      session.bus(:half) { |sig| sig * 0.5 }
      session.route(:x, send: { half: [0.25, :pre] })
      session.route(:y, send: { half: 0.25 })
      run(800) # (send levels list where they were last read)
      feeds = MB::Sound::UI::Panes::Buses.allocate.feeds_of(session)
      expect(feeds[:half]).to contain_exactly([:x, :pre, 0.25], [:y, :send, 0.25])
    end
  end

  describe 'tails and sleep' do
    # A 0.25 s blip sent to a bus with a 0.5 s delay, at buffer sizes
    # +sizes+; returns the mix and the frame the bus fell asleep on.
    def tail_run(sizes)
      s = new_session
      s.bus(:echo) { |sig| sig.delay(0.5, feedback: 0) }
      s.add(1.constant.until(0.25), name: :x, to: :echo)
      asleep = nil
      total = 0
      out = []
      sizes = sizes.cycle
      while total < 48000 * 4
        n = sizes.next
        out << s.process_buffer(n)[0].dup
        total += n
        asleep ||= total if s.instance_variable_get(:@buses)[:echo].asleep
      end
      s.close
      [SpecBuffers.join(out), asleep]
    end

    it 'rings out after the sender stops, then sleeps on the grid at any buffer size' do
      a, asleep = tail_run([800])
      expect(a[0...24000].to_a.uniq).to eq([0])
      expect(a[24000...36000].to_a.uniq).to eq([1])
      expect(a[36000..].to_a.uniq).to eq([0])
      # quiet from frame 36000 (input from 12000): asleep on the first grid frame 1 s later
      expect(asleep).to be_between(84000, 84000 + 800)

      b, asleep2 = tail_run([367, 368])
      n = [a.length, b.length].min
      expect(b[0...n]).to eq(a[0...n])
      expect(asleep2).to be_between(84000, 84000 + 368)
    end

    it "doesn't sample a sleeping bus's chain, and wakes on the exact frame its input arrives" do
      node = MB::Sound::GraphNode::Constant.new(0, sample_rate: 48000)
      session.bus(:b) { |sig| sig + node }
      run(48000 * 2)
      expect(bus_struct(:b).asleep).to eq(true)

      expect(node).not_to receive(:sample)
      run(4000)
      RSpec::Mocks.space.proxy_for(node).reset

      session.add(1.constant, name: :x, to: :b, on: :now)
      run(300)
      expect(bus_struct(:b).asleep).to eq(false)
      expect(run(800).to_a.uniq).to eq([1])
    end

    it 'keeps rendering a render after the last player until the buses are quiet' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'tail.flac')
        MB::Sound.render(path, channels: 1, gain: 1) do
          MB::Sound.bus(:echo) { |sig| sig.delay(1, feedback: 0) }
          MB::Sound.bg(:x, 0.5.constant.until(0.1), to: :echo)
        end
        data = MB::Sound.read(path)[0]
        expect(data.length).to be > 48000 * 2
        expect(data[48000...52800].abs.max).to be_within(1e-3).of(0.5)
      end
    end
  end

  describe 'mute and solo' do
    it 'mutes a bus (it sleeps) without muting what its senders play directly' do
      session.bus(:b) { |sig| sig * 0.5 }
      session.add(1.constant, name: :x, send: { b: 1 })
      run(800)
      session.mute(:b)
      run(1600)
      expect(bus_struct(:b).asleep).to eq(true)
      expect(run(800).to_a.uniq).to eq([1])
      session.unmute(:b)
      run(800)
      expect(run(800).to_a.uniq).to eq([1.5])
    end

    it 'solos in place through the routing' do
      session.bus(:verb) { |sig| sig * 0.5 }
      session.add(1.constant, name: :keys, send: { verb: 1 })
      session.add(10.constant, name: :pad, send: { verb: 1 })
      run(800)
      expect(run(800).to_a.uniq).to eq([16.5])

      session.solo(:keys)
      run(800)
      expect(run(800).to_a.uniq).to eq([1.5]) # keys and its reverb, not the pad

      session.unsolo
      session.solo(:verb)
      run(800)
      expect(run(800).to_a.uniq).to eq([16.5]) # the bus and everything feeding it
    end
  end

  describe 'readers' do
    it 'reads a player in the same buffer (exactly, at any buffer size)' do
      run_it = ->(sizes) {
        s = new_session
        src = 0.3.hz.lfo.sine
        reader = s.bus_tap(:src)
        s.add(src, name: :src)
        s.add(reader * -1, name: :inv, on: :now)
        data = run(9000, sizes, s: s)
        s.close
        data
      }
      a = run_it.([800])
      expect(a.abs.max).to be < 1e-6
      expect(run_it.([367, 368])).to eq(a)
    end

    it 'renders a reader after its source whatever order they were added in' do
      reader = session.bus_tap(:src)
      session.add(reader * -1, name: :inv)
      session.add(0.5.constant, name: :src)
      expect(run(800).to_a.uniq).to eq([0])
    end

    it 'reads a named node inside a track with only:' do
      a = MB::Sound::GraphNode::Constant.new(0.25, sample_rate: 48000).named(:inner)
      session.add(a + 1, name: :src)
      session.add(session.bus_tap(:src, only: :inner) * -4, name: :rd)
      expect(run(800).to_a.uniq).to eq([0.25])
    end

    it 'reads a drum voice with only:, the kick of a kit' do
      MB::Sound.seed(1)
      kit = MB::Sound.tr808(MB::Sound.grid(4, kick: 'x...', clap: '..x.').loop)
      session.add(kit, name: :drums)
      spy = []
      session.add(session.bus_tap(:drums, only: :kick).spy { |d| spy << d.dup if d } * 0, name: :rd)
      run(48000)
      kick = SpecBuffers.join(spy)

      MB::Sound.seed(1)
      alone = MB::Sound.tr808(MB::Sound.grid(4, kick: 'x...', clap: '..x.').loop, outputs: :separate)[:kick]
      expected = SpecBuffers.join(Array.new(60) { alone.sample(800).dup })
      expect(kick.length).to eq(48000)
      expect(kick).to eq(expected[0...48000])
      expect(kick.abs.max).to be > 0.1
    end

    # Kez's K10 (panel 2): a bus chain running its input through a Synth
    # failed ("A master effects chain asked for 799 samples, but the mix
    # buffer has 800"): a lane waking inside a buffer (the send turned up
    # after the bus slept) is read in a window, and the bus input (a
    # MixSource) took only whole buffers.  Fused plans hid it from
    # fuse-more-1 (3ee3c039) on; plans off it failed until omnibus17.
    it 'runs a bus chain through a Synth whose lanes read the bus input in windows, plans on and off' do
      results = [true, false].map do |plans|
        old = MB::Sound::Plan.enabled
        MB::Sound::Plan.enabled = plans
        s = new_session(transport: MB::Sound::Sequence::Transport.new(bpm: 172))
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.knob(:tint, 0, range: 0..1)
          n = MB::Sound
          chords = n.seq([n::E2, n::G2, n::B2], [n::C2, n::E2, n::G2], [n::A1, n::C2, n::E2], [n::B1, n::D2, n::F2]).n1.loop
          MB::Sound.bus(:colour) { |sig| chords.synth(voices: 5) { |v, _| (sig * 0.004).resonate([[1, 1, 1], [2, 0.45, 0.7]], v.freq, decay: 0.3) * v.gate.smooth(4.ms) } }
          MB::Sound.track(:growl, send: { colour: :tint }) { |clip| clip.notes.hz.saw * clip.notes.gate * 0.5 }
          MB::Sound.scene(:a, growl: n.seq(n::E2, n::G2, n::B2, n::D3).n8.loop)
          MB::Sound.go(:a, on: :now)
          MB::Sound.at_bar(2) { MB::Sound.turn(:tint, 1) }
          MB::Sound.at_bar(3) { MB::Sound.turn(:tint, 0) }
          MB::Sound.at_bar(4) { MB::Sound.turn(:tint, 1) }
          run(5 * 48000 * 60 * 4 / 172, s: s)
        end
      ensure
        s&.close
        MB::Sound::Plan.enabled = old
      end
      expect(results[0].abs.max).to be > 0.1
      expect((results[0] - results[1]).abs.max).to be < 1e-4 # (the windows read the bus input's next samples)
    end

    # Munro's M3 (panel 2): a scene swapping the drums' kit (new rows: the
    # patch rebuilds) as it starts the ducked bass queued both graphs on the
    # bar, and the reader bound before the new kit played attached its spy
    # only to the old kit: the bass wasn't ducked after the swap.
    it 'reads only: a node of a graph queued under the name when the reader is bound (a kit swapped as the ducked part starts)' do
      MB::Sound::Session.with_context(session: session) do
        four = MB::Sound.grid(16, kick: 'X...X...X...X...').loop(align: :launch)
        hats = MB::Sound.grid(16, kick: 'X...X...X...X...', closed_hat: '5.5.5.5.5.5.5.5.').loop(align: :launch)
        bass = MB::Sound.seq(MB::Sound::A1).n4.loop(align: :launch)
        MB::Sound.track(:drums) { |kit| MB::Sound.tr808(kit) * 0 }
        MB::Sound.track(:bass) { |c| (c.notes.gate * 0.5).duck(:drums, only: :kick, amount: -24.db, release: 1.n16) }
        MB::Sound.scene(:a, drums: four)
        MB::Sound.scene(:b, drums: hats, bass: bass)
        MB::Sound.go(:a, on: :now)
        MB::Sound.go(:b, at: MB::Sound.bar(2)) # (queued: both graphs wait for the bar)
        data = run(3 * 96000)
        expect(data[96000 + 1200]).to be_within(1e-6).of(0.5 * -24.db) # (ducked right after the swap's first kick)
        expect(data[96000 + 23999]).to be > 2 * data[96000 + 1200] # (rising again before the next kick)
      end
    end

    it 'ducks by a bus or a track by name, as a duck by the node itself would' do
      kick_graph = -> { MB::Sound.grid(4, 'x...').loop.trigger.ping(50, decay: 0.3) }
      ref = new_session
      k = kick_graph.()
      ref.add(k + 0.5.constant.duck(k), name: :ref)
      expected = run(48000, s: ref)
      ref.close
      expect((expected - 0.5).min).to be < -0.3

      [[:kick, :to_bus], [:k, :track]].each do |source, _|
        s = new_session
        s.bus(:kick) { |sig| sig }
        s.add(kick_graph.(), name: :k, to: :kick)
        s.add(0.5.constant.duck(source), name: :pad)
        data = run(48000, s: s)
        s.close
        expect((data - expected).abs.max).to be < 1e-6
      end
    end

    # (fix-bufsize-1107, SessionFuzz seed 611891: a reader bound by a
    # block run ahead of its time woke the held kit on the buffer after the
    # bind, so the kit chased its grid from a frame that depended on the
    # buffer size and on when the block ran)
    it 'wakes a held source for a reader on the frame the reader starts, not when it was added', render_budget: { seconds: 70, reason: 'thirteen 2.5 s renders' } do
      # held from 1/4 to 7/8 of bar 1 (off sample positions); the reader
      # lands at 3/5 + 1/9600 (57600.01) while held, or at 9/8 + 1/9600 after
      sides = { kit: 'x...x...x...x...', low_tom: '..x...x...x...x.', cowbell: '.x...x...x...x..' }
      play = lambda do |sizes, reader_at, add_at, stop_at = nil|
        MB::Sound.seed(1) # (the kit draws its seeds as it builds)
        s = new_session
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.track(:drums) { |kit| MB::Sound.tr808(kit) * 0.5 }
          MB::Sound.bg(:drums, MB::Sound.grid(16, kick: sides[:kit], low_tom: sides[:low_tom], cowbell: sides[:cowbell]).loop, on: :now)
          s.hold(:drums, start_time: 1/4r + 1/960_000r)
          s.unhold(:drums, start_time: 7/8r + 1/960_000r)
        end
        out = []
        done = 0
        sizes.cycle do |n|
          break if done >= 240_000
          if reader_at && add_at && done >= add_at
            MB::Sound::Session.with_context(session: s) { s.add(0.2.constant.duck(:drums, only: :kick, amount: -12.db), name: :ducked, start_time: reader_at) }
            s.remove(:ducked, time: stop_at) if stop_at
            add_at = nil
          end
          n = [n, 240_000 - done].min
          out << s.process_buffer(n)[0].dup
          done += n
        end
        s.close
        SpecBuffers.join(out)
      end

      while_held = 3/5r + 1/9600r
      after_unhold = 9/8r + 1/9600r
      a = play.([800], while_held, 30_000)
      expect(a[90_000...110_000].abs.max).to be > 0.1
      expect(play.([800], while_held, 50_000)).to eq(a)
      [[367, 368], [64], [799]].each do |sizes|
        expect(play.(sizes, while_held, 30_000)).to eq(a), "#{sizes.join('/')}-frame buffers"
      end

      # Landing after the unhold: nothing before the landing differs from
      # the song without the reader, wherever the add ran
      plain = play.([800], nil, nil)
      [[[800], 30_000], [[367, 368], 30_000], [[800], 50_000], [[64], 70_000]].each do |sizes, add_at|
        b = play.(sizes, after_unhold, add_at)
        expect((b[0...108_000] - plain[0...108_000]).abs.max).to be < 1e-6, "#{sizes.join('/')}-frame buffers, added at #{add_at}"
      end

      # A reader that played before the hold and stopped while held: the
      # source renders on while muted (readers stay bound), at any size
      c = play.([800], 1/8r, 0, 1/2r + 1/9600r)
      expect(play.([367, 368], 1/8r, 0, 1/2r + 1/9600r)).to eq(c)
    end

    it 'keeps ducking while the pad is soloed (a source a reader reads renders while muted)' do
      kick_graph = -> { MB::Sound.grid(4, 'x...').loop.trigger.ping(50, decay: 0.3) }
      ref = new_session
      ref.add(0.5.constant.duck(kick_graph.()), name: :ref)
      expected = run(48000, s: ref)
      ref.close

      session.add(kick_graph.(), name: :k)
      session.add(0.5.constant.duck(:k), name: :pad)
      session.solo(:pad)
      data = run(48000)
      expect(session.instance_variable_get(:@players).values.find { |p| p.name == :k }.asleep).to eq(false)
      expect((data[480..] - expected[480..]).abs.max).to be < 1e-6 # (after the 5 ms solo declick)
    end

    it 'refuses a reader that reads what it feeds' do
      session.bus(:b) { |sig| sig }
      expect { session.add(session.bus_tap(:b), name: :x, to: :b) }.to raise_error(ArgumentError, /loop/)
    end

    it 'lets a master chain read a player' do
      session.master { |mix| mix * MB::Sound.bus(:ctl).mono }
      session.bus(:sink) { |sig| sig * 0 }
      session.add(0.5.constant, name: :ctl, to: :sink)
      session.add(1.constant, name: :x)
      run(1600)
      expect(run(800).to_a.uniq).to eq([0.5])
    end
  end

  describe 'stems' do
    it "gives each track its own share of the buses it feeds, so stems sum to the mix (bus stems on request)" do
      Dir.mktmpdir do |dir|
        MB::Sound.render(File.join(dir, 'mix.flac'), channels: 1, gain: 1, seconds: 2, stems: dir, bus_stems: true) do
          # (a knob in the block: the stem copies are built on the render thread)
          MB::Sound.knob(:stem_level, 0.5)
          MB::Sound.bus(:half) { |sig| sig.delay(0.01) * MB::Sound.knob(:stem_level) }
          MB::Sound.bus(:grp, to: :half) { |sig| sig * 0.5 }
          MB::Sound.bg(:x, 0.25.constant.until(1), send: { half: 1 })
          MB::Sound.bg(:y, 0.125.constant.until(1), to: :grp)
        end
        read = ->(n) { MB::Sound.read(File.join(dir, "#{n}.flac"))[0] }
        x, y, mix, half, grp = %w[x y mix half grp].map { |n| read.(n) }
        expect(x[2000]).to be_within(1e-4).of(0.25 + 0.125)         # dry plus its echo
        expect(y[2000]).to be_within(1e-4).of(0.03125)              # through grp, then half (grp feeds only half)
        expect(y[200]).to be_within(1e-6).of(0)                     # (before half's 10 ms delay)
        expect(mix[2000]).to be_within(1e-4).of(x[2000] + y[2000])
        expect((x + y - mix).abs.max).to be < 1e-4
        # Ringing out after the tracks end (the delay tail is in the stems)
        expect(x[48000 + 200]).to be_within(1e-4).of(0.125)
        expect(half[2000]).to be_within(1e-4).of(0.125 + 0.03125)
        expect(grp[2000]).to be_within(1e-4).of(0.0625)
      end
    end
  end

  describe 'bus chains' do
    it 'swaps a chain at a launch point with the old tail spilling over, and undoes it' do
      session.bus(:b) { |sig| sig * 2 }
      session.add(1.constant, name: :x, to: :b)
      run(800)
      _, = session.command('bus') { session.bus(:b, on: :now) { |sig| sig * 3 } }
      run(800)
      expect(run(800).to_a.uniq).to eq([3])
      session.undo(on: :now)
      run(800)
      expect(run(800).to_a.uniq).to eq([2])
    end

    it 'lists buses' do
      session.bus(:verb) { |sig| sig.reverb(:room) }
      session.bus(:pre, to: :verb) { |sig| sig }
      expect(session.bus_info[:pre]).to match(/to verb/)
      expect(session.bus_info[:verb]).to match(/to master/)
    end

    # fix-bus-tween-1 (found by the .acd converter's bus envelopes): a
    # one-shot tween in a chain whose bus first got signal after bar 1
    # jumped to its end there (0.00 until bar 2, then 1.00), since the
    # wake's chase into its first step had no previous keyframe; the same
    # tween on a track was right.  Input in bar 2, then (after a gap the
    # bus sleeps through) from bar 4.
    [800, 367].each do |bs|
      it "plays a tween that doesn't loop on the timeline in a chain fed late and woken after a gap (#{bs}-frame buffers)" do
        tween = -> { MB::Sound.tween([0.0, 1.0], [4.n1], loop: false, curve: :linear) }
        lane = -> {
          smp = MB::Sound::Sample.new([Numo::SFloat.new(48000 * 8).fill(0.5)])
          MB::Sound.regions([smp, 1r, 1r], [smp, 3r, 2r])
        }
        bused = new_session
        bused.bus(:b) { |sig| sig * tween.call }
        bused.add(lane.call, name: :t, to: :b)
        a = run(96000 * 5, [bs], s: bused)
        asleep = bus_struct(:b, s: bused).asleep
        bused.close

        tracked = new_session
        tracked.add(lane.call * tween.call, name: :t)
        b = run(96000 * 5, [bs], s: tracked)
        tracked.close

        expect(a[96000]).to be_within(1e-5).of(0.5 * 0.25) # bar 2: a quarter of the way
        expect(a[192000...288000].abs.max).to eq(0) # the gap
        expect(a[288000]).to be_within(1e-5).of(0.5 * 0.75) # bar 4, woken
        expect(a[383999]).to be_within(1e-5).of(0.5)
        expect(asleep).to eq(false)
        expect((a - b).abs.max).to be < 1e-7
      end
    end
  end

  # fixes-13: bus chains run in segments of a span and sleep, so a chain
  # sharing a node with a player (`bus(:fx) { |sig| sig * lfo }`) read it
  # late after waiting to start, sleeping, or being muted, and raised
  # BranchBufferOverflow after a second; a muted player sharing a node
  # only with a bus chain did the same on unmuting (fixes-12 fixed this
  # for master chains; see master_spec).
  describe 'nodes shared with players' do
    # Buffer sizes to render in (mixed, the usual, tiny)
    let(:buffer_sizes) { [[128, 801, 7], [800], [7]] }

    # The LFO's first +frames+ samples.
    def lfo_values(frames)
      3.hz.lfo.sample(frames).dup
    end

    # Runs the block for each buffer size pattern with a new session (closed
    # afterwards).
    def each_size(sizes = buffer_sizes)
      sizes.each do |sz|
        s = new_session
        yield s, sz
      ensure
        s&.close
      end
    end

    [[0.3, 25_933], [1.5, 800]].each do |wait, added|
      it "starts a bus chain queued for #{wait} s in step with a node a player plays, at any buffer size" do
        start = added + (wait * 48000).round # not on a buffer edge
        each_size do |s, sizes|
          lfo = 3.hz.lfo
          s.bus(:fx) { |sig| sig }
          s.add(lfo * 0.5, name: :a)
          s.add(0.25.constant, name: :b, to: :fx)
          data = run(added, sizes, s: s)
          s.bus(:fx, start_time: Rational(start, 96000)) { |sig| sig * (lfo * 0.5 + 1) }
          expect(s.queued.map(&:kind)).to eq([:bus])
          data = data.concatenate(run(start + 24000 - added, sizes, s: s))

          l = lfo_values(data.length)
          expected = l * 0.5 + 0.25
          expected[start..] = l[start..] * 0.5 + (l[start..] * 0.5 + 1) * 0.25
          expect((data - expected).abs.max).to be < 1e-6
          expect(s.instance_variable_get(:@waiting_graphs)).to be_empty
        end
      end
    end

    it 'starts a new bus defined while playing in step with a node a player plays' do
      each_size([[128, 801, 7], [800]]) do |s, sizes|
        lfo = 3.hz.lfo
        s.add(lfo * 0.5, name: :a)
        data = run(800, sizes, s: s)
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) } # lands on the next bar
        s.add(0.25.constant, name: :b, to: :fx)
        data = data.concatenate(run(96_000 + 24_000 - 800, sizes, s: s))

        l = lfo_values(data.length)
        expected = l * 0.5 + (l * 0.5 + 1) * 0.25
        expected[0...96_000] = l[0...96_000] * 0.5
        expect((data - expected).abs.max).to be < 1e-6
      end
    end

    it 'keeps a sleeping bus chain in step, waking on its first input off a buffer edge' do
      each_size do |s, sizes|
        lfo = 3.hz.lfo
        s.add(lfo * 0.5, name: :a)
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
        data = run(96_000, sizes, s: s)
        expect(bus_struct(:fx, s: s).asleep).to eq(true)
        start = 96_000 + 50_001
        s.add(0.25.constant, name: :b, to: :fx, start_time: Rational(start, 96000))
        data = data.concatenate(run(start + 24_000 - 96_000, sizes, s: s))

        l = lfo_values(data.length)
        expected = l * 0.5
        expected[start..] = l[start..] * 0.5 + (l[start..] * 0.5 + 1) * 0.25
        expect((data - expected).abs.max).to be < 1e-6
      end
    end

    it 'keeps a muted bus chain in step until it is unmuted' do
      each_size([[128, 801, 7], [800]]) do |s, sizes|
        lfo = 3.hz.lfo
        s.add(lfo * 0.5, name: :a)
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
        s.add(0.25.constant, name: :b, to: :fx)
        data = run(800, sizes, s: s)
        s.mute(:fx)
        data = data.concatenate(run(72_000, sizes, s: s))
        expect(data[-1]).to be_within(1e-6).of(lfo_values(data.length)[-1] * 0.5)
        s.unmute(:fx)
        data = data.concatenate(run(24_000, sizes, s: s))

        l = lfo_values(data.length)
        expected = l * 0.5 + (l * 0.5 + 1) * 0.25
        expect((data[-20_000..] - expected[-20_000..]).abs.max).to be < 1e-6
      end
    end

    it 'keeps a muted player in step with a node only a bus chain also reads' do
      each_size([[128, 801, 7], [800]]) do |s, sizes|
        lfo = 3.hz.lfo
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
        s.add(lfo * 0.5, name: :a)
        s.add(0.25.constant, name: :b, to: :fx)
        data = run(800, sizes, s: s)
        s.mute(:a)
        data = data.concatenate(run(72_000, sizes, s: s))
        s.unmute(:a)
        data = data.concatenate(run(24_000, sizes, s: s))

        l = lfo_values(data.length)
        expected = l * 0.5 + (l * 0.5 + 1) * 0.25
        expect((data[-20_000..] - expected[-20_000..]).abs.max).to be < 1e-6
      end
    end

    it 'starts a replacement bus chain in step with a node the spilling chain reads' do
      each_size do |s, sizes|
        lfo = 3.hz.lfo
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
        s.add(0.5.constant, name: :b, to: :fx)
        data = run(800, sizes, s: s)
        start = 800 + 72_001
        s.bus(:fx, start_time: Rational(start, 96000)) { |sig| sig * (lfo * 0.25 + 1) }
        data = data.concatenate(run(start + 24_000 - 800, sizes, s: s))

        l = lfo_values(data.length)
        expected = (l * 0.5 + 1) * 0.5
        expected[start..] = (l[start..] * 0.25 + 1) * 0.5
        expect((data - expected).abs.max).to be < 1e-6
      end
    end

    it 'restores an undone bus chain in step with a node a player plays' do
      each_size([[128, 801, 7], [800]]) do |s, sizes|
        lfo = 3.hz.lfo
        within = ->(&block) { MB::Sound::Session.with_context(session: s, &block) }
        s.add(lfo * 0.5, name: :a)
        s.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
        s.add(0.25.constant, name: :b, to: :fx)
        data = run(800, sizes, s: s)
        within.() { MB::Sound.bus(:fx, on: :now) { |sig| sig * 0.5 } }
        data = data.concatenate(run(800, sizes, s: s))
        within.() { MB::Sound.undo } # lands on the next bar
        expect(s.queued.map(&:kind)).to eq([:bus])
        data = data.concatenate(run(96_000 + 24_000 - 1600, sizes, s: s))

        l = lfo_values(data.length)
        expected = l * 0.5 + (l * 0.5 + 1) * 0.25
        expect((data[96_000..] - expected[96_000..]).abs.max).to be < 1e-6
        expect((data[1600...96_000] - (l[1600...96_000] * 0.5 + 0.125)).abs.max).to be < 1e-6
      end
    end

    it "keeps a track's stem copy of a bus in step with a node a player plays" do
      dir = File.dirname(tmp_path('mix.flac'))
      begin
        lfo = 3.hz.lfo
        MB::Sound.render(File.join(dir, 'mix.flac'), channels: 1, gain: 1, seconds: 1, stems: dir) do
          MB::Sound.bus(:fx) { |sig| sig * (lfo * 0.5 + 1) }
          MB::Sound.bg(:a, lfo * 0.25)
          MB::Sound.bg(:b, 0.25.constant, to: :fx)
        end
        read = ->(n) { MB::Sound.read(File.join(dir, "#{n}.flac"))[0] }
        a, b, mix = %w[a b mix].map { |n| read.(n) }
        l = lfo_values(mix.length)
        expect((b - (l * 0.5 + 1) * 0.25).abs.max).to be < 1e-4
        expect((a + b - mix).abs.max).to be < 1e-4
      end
    end
  end
end
