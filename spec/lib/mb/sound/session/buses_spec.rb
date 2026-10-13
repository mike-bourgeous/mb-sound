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
    chans = out.transpose.map { |c| c.reduce(:concatenate) }
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
      session.add(2.constant, name: :x, on: :now)
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
      [out.reduce(:concatenate), asleep]
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
      kick = spy.reduce(:concatenate)

      MB::Sound.seed(1)
      alone = MB::Sound.tr808(MB::Sound.grid(4, kick: 'x...', clap: '..x.').loop, outputs: :separate)[:kick]
      expected = Array.new(60) { alone.sample(800).dup }.reduce(:concatenate)
      expect(kick.length).to eq(48000)
      expect(kick).to eq(expected[0...48000])
      expect(kick.abs.max).to be > 0.1
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
          MB::Sound.bus(:half) { |sig| sig.delay(0.01) * 0.5 }
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
  end
end
