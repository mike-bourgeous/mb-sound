RSpec.describe(MB::Sound::GraphNode::Knob) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  def new_session(buffer_size = 800, transport: self.transport)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: buffer_size)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true)
  end

  # Renders +frames+ from +session+ in buffers of +size+ (or cycling
  # through an Array of sizes).
  def render(session, frames, size = 800)
    sizes = Array(size).cycle
    out = []
    done = 0
    while done < frames
      n = [sizes.next, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  def within(session, &block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  # Reads +frames+ of +node+ in blocks of +size+ (cycling an Array).
  def read(node, frames, size)
    sizes = Array(size).cycle
    out = []
    done = 0
    while done < frames
      n = [sizes.next, frames - done].min
      out << node.sample(n).dup
      done += n
    end
    SpecBuffers.join(out)
  end

  describe 'Spec' do
    it 'checks and normalizes its options' do
      s = described_class::Spec.new(name: :cut, default: 800, range: 100..8000, curve: :exponential, unit: 'Hz', cc: 74)
      expect(s.range).to eq(100.0..8000.0)
      expect(s.curve).to eq(:exp)
      expect(s.default).to eq(800.0)
      expect(s.position(8000)).to be_within(1e-12).of(1)
      expect(s.value(s.position(800))).to be_within(1e-9).of(800)
      expect(s.to_ruby).to eq("knob :cut, 800, range: 100..8000, curve: :exp, unit: \"Hz\", cc: 74")

      expect { described_class::Spec.new(name: 'cut') }.to raise_error(ArgumentError, /Symbols/)
      expect { described_class::Spec.new(name: :x, range: 0..1, curve: :exp) }.to raise_error(ArgumentError, /include 0/)
      expect { described_class::Spec.new(name: :x, curve: :wobbly) }.to raise_error(ArgumentError, /curve/)
      expect { described_class::Spec.new(name: :x, takeover: :grab) }.to raise_error(ArgumentError, /Takeover/)
      expect { described_class::Spec.new(name: :x, default: 5) }.to raise_error(ArgumentError, /outside the default range 0\.\.1.*range: 0\.\.10/) # (ux-1 item 30)
      expect(described_class::Spec.new(name: :x, default: 5, range: 0..1).default).to eq(1.0) # limited to a range given
      expect(described_class::Spec.new(name: :x, smooth: 10.ms).smooth).to be_within(1e-12).of(0.01)
    end

    it 'makes a MIDI::ControlSpec for its controller' do
      k = described_class.new(:cut, 800, range: 100..8000, curve: :exp, cc: 74)
      cs = k.control_specs.first
      expect(cs).to be_a(MB::Sound::MIDI::ControlSpec)
      expect(cs.number).to eq(74)
      expect(cs.curve).to eq(:exponential)
      expect(cs.value(cs.default)).to be_within(30).of(800)

      map = MB::Sound::MIDI::ControlMap.new(110.hz.ramp.lp4(k))
      expect(map.numbers).to eq([74])
      expect(map.to_acid_xml(name: 'knobs')).to include('cut')
    end
  end

  describe 'standalone' do
    it 'holds its default as a param (a Float) and as a frozen buffer' do
      k = described_class.new(:x, 0.25)
      r = k.get_sampler
      expect(r).to be_a(described_class::Reader)
      expect(r.plan_param(4)).to eq(0.25)
      buf = r.sample(4)
      expect(buf.to_a).to eq([0.25] * 4)
      expect(buf).to be_frozen
    end

    it 'gives every consumer its own reader (no Tee), reading the same frames' do
      k = described_class.new(:x, 0)
      k.ramp_to(1, frames: 100, frame: 10)
      a = k.get_sampler
      b = k.get_sampler
      expect(a).not_to equal(b)
      ra = []
      rb = []
      [7, 50, 13, 130].each do |n|
        ra << a.sample(n).dup
        rb << b.sample(n).dup
      end
      expect(SpecBuffers.join(ra)).to eq(SpecBuffers.join(rb))
      expect(SpecBuffers.join(ra)[0...110]).to eq(Numo::SFloat.zeros(10).concatenate(Numo::SFloat.new(100).seq(1) / 100))

      # A reader made later starts with the block being read
      a.sample(10)
      c = k.get_sampler
      expect(c.sample(10)).to eq(b.sample(10))
    end

    it 'has the same ramps at any block size' do
      results = [1, 7, 128, 800, [367, 368]].map { |size|
        k = described_class.new(:x, 0.5)
        k.ramp_to(1, frames: 1000, frame: 333, curve: :smooth)
        k.ramp_to(0.2, frames: 777, frame: 900) # interrupts, from where it was
        k.set(0.7, frame: 2000, smooth: 0)
        read(k.get_sampler, 3000, size)
      }
      results.each { |r| expect(r).to eq(results[0]) }

      r = results[0]
      expect(r[332]).to eq(0.5)
      expect(r[333]).to be > 0.5
      expect(r[1676]).to eq(Numo::SFloat[0.2][0]) # the last ramp frame is the target
      expect(r[1999]).to eq(Numo::SFloat[0.2][0])
      expect(r[2000]).to eq(Numo::SFloat[0.7][0])
    end

    it 'ramps exponential knobs in octaves' do
      k = described_class.new(:cut, 100, range: 100..6400, curve: :exp)
      k.ramp_to(6400, frames: 6, frame: 0)
      expect(read(k.get_sampler, 6, 6).to_a).to eq([200, 400, 800, 1600, 3200, 6400].map { |v| Numo::SFloat[v][0] })
    end

    it 'follows a node, limited to the range, holding its last value when it ends' do
      k = described_class.new(:x, 0, range: 0..10)
      k.follow(MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 30, -4]]), frame: 2)
      expect(read(k.get_sampler, 8, 3).to_a).to eq([0, 0, 1, 2, 10, 0, 0, 0])
    end
  end

  describe 'in a Session' do
    let(:session) { new_session }

    after { session.close }

    it 'prints knob readers back as knob(:name) in to_ruby' do
      # 2026-10-12: they printed as a free input (`lp4(input)`)
      within(session) do
        MB::Sound.knob(:cut, 800, range: 100..8000, curve: :exp)
        MB::Sound.knob(:res, 0.5)
        g = 220.hz.saw.lp4(MB::Sound.knob(:cut), resonance: MB::Sound.knob(:res)) * MB::Sound.knob(:cut).get_sampler
        text = g.to_ruby
        expect(text).not_to include('input')
        expect(text).to eq('220.hz.saw.lp4(knob(:cut), resonance: knob(:res)) * knob(:cut)')
      end
    end

    it 'gives players starting or waking partway through a buffer the values of their own frames' do
      # fixes-7: readers read from the buffer's first frame, so a player
      # launched (or unmuted) partway through a buffer read the knob up to
      # a buffer early, differing with the buffer size (a persona take's
      # harp, -18 dB at 367/368 vs 800)
      results = [800, [367, 368], 64, 1031].map { |size|
        s = new_session(transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        k = s.knob(:x, 0, smooth: 0)
        s.turn(:x, 1, over: 4.beats)                    # frames 0...96000
        s.add(k * 1, name: :a, start_time: 1/3r)        # frame 32000
        s.mute(:a, start_time: 1/2r)                    # frame 48000, then asleep
        s.unmute(:a, start_time: 5/7r, fade: 0)         # frame 68571 (a fraction)
        data = render(s, 96_000, size)
        s.close
        data
      }
      results.each { |r| expect(r).to eq(results[0]) }

      d = results[0]
      expect(d[31_999]).to eq(0)
      expect(d[32_000]).to be_within(1e-4).of(32_000 / 96_000.0)
      expect(d[60_000]).to eq(0)
      first = d[60_000..].ne(0).where[0] + 60_000
      expect(d[first + 1000]).to be_within(1e-4).of((first + 1000) / 96_000.0) # (after the declick)
    end

    it 'keeps readers in step through Synth lanes skipped while idle' do
      # A skipped lane's graph is read in pieces around its idle stretches;
      # its knob readers read past them (fixes-7)
      clip = -> { MB::Sound.seq(MB::Sound::C4.n16, MB::Sound::Rest.n4, MB::Sound::E4.n16, MB::Sound::Rest.n2).loop }
      old = MB::Sound::Plan.lanes
      MB::Sound::Plan.lanes = false # (lanes in lane groups are never skipped)
      results = [800, [367, 368], 64, 1031].map { |size|
        s = new_session(transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        s.knob(:x, 0, smooth: 0)
        s.turn(:x, 1, over: 8.beats)
        syn = within(s) { clip.().synth(voices: 2) { |v| (v.hz.aramp * 0.001 + MB::Sound.knob(:x)) * v.env(0.001, 0.05, 0, 0.05) } }
        s.add(syn, name: :a, start_time: 1/5r)
        data = render(s, 192_000, size)
        expect(syn.skippable_lanes).not_to be_empty
        s.close
        data
      }
      expect(results[0].abs.max).to be > 0.1
      results.each { |r| expect(r).to eq(results[0]) }
    ensure
      MB::Sound::Plan.lanes = old
    end

    it 'lands turns on their exact frame at any buffer size' do
      results = [800, 367, 64, [1001, 13]].map { |size|
        s = new_session(transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        k = s.knob(:cut, 800, range: 100..8000, curve: :exp, smooth: 0)
        s.add(k * 1, name: :x, on: :now)
        s.turn(:cut, 3000, start_time: 1r)                             # bar 2, frame 96000
        s.turn(:cut, 200, start_time: 3/2r, over: 1.beat, curve: :smooth) # frame 144000, 24000 frames
        s.turn(:cut, 5000, start_time: 7/4r, smooth: 10.ms)             # frame 168000
        data = render(s, 200_000, size)
        s.close
        data
      }
      results.each { |r| expect(r).to eq(results[0]) }

      d = results[0]
      expect(d[95999]).to eq(800)
      expect(d[96000]).to eq(3000)
      expect(d[144100]).to be < 3000 # (smoothstep starts slowly)
      expect(d[143999]).to eq(3000)
      expect(d[144000 + 23999]).to eq(200)
      expect(d[168000]).to be > 200
      expect(d[168000 + 479]).to eq(5000)
    end

    it 'ramps from a given value with from:' do
      k = session.knob(:cut, 800, range: 100..8000, smooth: 0)
      session.add(k * 1, name: :x, on: :now)
      session.turn(:cut, 2000, from: 1000, over: 1.beat)
      d = render(session, 24800)
      expect(d[0]).to be_within(0.1).of(1000)
      expect(d[11999]).to be_within(0.1).of(1500)
      expect(d[-1]).to eq(2000)
      expect { session.turn(:cut, 1, from: 2) }.to raise_error(ArgumentError, /needs over/)
    end

    it 'journals turns, which return entries and print where they land' do
      k = session.knob(:cut, 800, range: 100..8000)
      session.add(k * 1, name: :x, on: :now)
      render(session, 1600)
      c = within(session) { MB::Sound.turn(:cut, 2000, on: :bar) }
      expect(c.to_s).to eq('turn :cut lands 2:1 (queued)')
      expect(session.journal[c.seq].data).to eq({ value: 2000 })
      expect(within(session) { MB::Sound.move(:cut, 900) }.status).to eq(:landed)
    end

    it 'drives graphs that sleep (muted) without falling behind' do
      k = session.knob(:g, 0.5)
      session.add(MB::Sound::GraphNode::Constant.new(1, sample_rate: 48000) * k, name: :a, on: :now)
      session.add(k * 2, name: :b, on: :now)
      render(session, 800)
      session.mute(:a)
      render(session, 96000 * 2)
      session.turn(:g, 0.25, smooth: 0)
      session.unmute(:a)
      d = render(session, 4800)
      expect(d[-1]).to be_within(1e-6).of(0.25 + 0.5)
    end

    it 'undoes turns at the next bar' do
      k = session.knob(:cut, 800, range: 100..8000, smooth: 0)
      session.add(k * 1, name: :x, on: :now)
      render(session, 800)
      within(session) { MB::Sound.turn(:cut, 3000, over: 1.beat) }
      render(session, 48000)
      steps = session.undo
      expect(steps.first.to_s).to eq('undo turn :cut lands 2:1')
      d = render(session, 96000)
      expect(d[96000 - 48800 - 1]).to eq(3000)
      expect(d[96000 - 48800 + 239]).to eq(800) # back over the 5 ms declick

      session.redo
      d = render(session, 96000)
      expect(d[-1]).to eq(3000)
    end

    it 'follows nodes and other knobs' do
      a = session.knob(:a, 0)
      b = session.knob(:b, 0)
      session.add(a + b * 10, name: :x, on: :now)
      session.turn(:a, 0.5, smooth: 0)
      session.turn(:b, follow: :a)
      d = render(session, 1600)
      expect(d[-1]).to eq(5.5)
      expect(b.mode).to eq(:follow)
      session.turn(:a, 1, smooth: 0)
      expect(render(session, 800)[-1]).to eq(11)
      session.turn(:b, 0.1, smooth: 0)
      expect(render(session, 800)[-1]).to eq(2)
    end

    it 'follows tweens from their start where the turn lands' do
      k = session.knob(:cut, 100, range: 100..1000)
      session.add(k * 1, name: :x, on: :now)
      render(session, 800)
      tw = within(session) { MB::Sound.tween([200, 1000], 1.bar) }
      session.turn(:cut, tw, start_time: 1r)
      d = render(session, 96000 * 2)
      expect(d[96000 - 801]).to eq(100)
      expect(d[96000 - 800]).to be_within(1).of(200)
      expect(d[96000 - 800 + 24000]).to be_within(1).of(325) # smoothstep a quarter of the way
      expect(d[96000 - 800 + 96000 - 1]).to be_within(1).of(1000)
    end

    it 'keeps fused plans fused, with the same samples in check mode' do
      old = MB::Sound::Plan.check
      MB::Sound::Plan.check = :raise
      begin
        k = session.knob(:cut, 800, range: 100..8000, curve: :exp)
        g = 110.hz.ramp.filter(:lowpass, cutoff: k, quality: 2) * 0.5
        expect(MB::Sound::Plan.explain(g)).to match(/1 planned region.*param 0: GraphNode::Knob::Reader.*\(800\)/m)
        session.add(g, name: :x, on: :now)
        session.turn(:cut, 4000, over: 1.beat)
        d = render(session, 48000, [800, 367])
        expect(d.abs.max).to be > 0.1
      ensure
        MB::Sound::Plan.check = old
      end
    end

    it 'fuses as a param into a planned compressor (a knob release time, in check mode)' do
      old = MB::Sound::Plan.check
      MB::Sound::Plan.check = :raise
      begin
        k = session.knob(:rel, 0.05, range: 0.001..0.5)
        g = (110.hz.ramp * 0.9).compress(threshold: -20.db, release: k) * 0.5
        expect(MB::Sound::Plan.explain(g)).to match(/1 planned region.*param 0: GraphNode::Knob::Reader.*dynamics\(/m)
        session.add(g, name: :x, on: :now)
        session.turn(:rel, 0.2, over: 1.beat)
        d = render(session, 48000, [800, 367])
        expect(d.abs.max).to be > 0.05
      ensure
        MB::Sound::Plan.check = old
      end
    end

    it 'shares the namespace with tracks and mute groups' do
      session.arrangement.track(:bass) { |c| c.number }
      expect { session.knob(:bass, 1) }.to raise_error(ArgumentError, /already a track/)
      session.knob(:cut, 1)
      expect { session.arrangement.track(:cut) { |c| c.number } }.to raise_error(ArgumentError, /already a knob/)
      expect { session.mute_group(:cut, :bass) }.to raise_error(ArgumentError, /already a knob/)
      expect { session.knob(:master, 1) }.to raise_error(ArgumentError, /reserved/)
      expect { session.turn(:cutt, 1) }.to raise_error(ArgumentError, /No knob :cutt.*Did you mean/m)
    end

    it 'keeps its value and readers when defined again' do
      k = session.knob(:cut, 800, range: 100..8000)
      session.turn(:cut, 1000, smooth: 0)
      render(session, 800)
      expect(session.knob(:cut, 500, range: 100..9000)).to equal(k)
      expect(k.value).to eq(1000)
      expect(k.range).to eq(100.0..9000.0)
      expect(session.knob(:cut)).to equal(k)
      expect { session.knob(:nope) }.to raise_error(ArgumentError, /No knob :nope/)
    end
  end

  describe 'graph documents in a Session' do
    let(:session) { new_session }
    let(:io) { MB::Sound::GraphIO }
    let(:doc) {
      <<~RUBY
        graph 1, name: "dc"
        knob :cut, 800.0, range: 100.0..8000.0, curve: :exp, smooth: 0
        cut * 1
      RUBY
    }

    after { session.close }

    it 'registers a loaded document\'s knob when the graph plays, keeping its value' do
      g = io.load(doc, params: { cut: 1200 })
      k = io.document_of(g).knob_nodes[:cut][0]
      expect(k.session).to eq(nil)
      g.sample(800) # read standalone first: the knob's frames restart at the session's
      render(session, 1600)
      session.add(g, name: :x, on: :now)
      expect(session.knobs[:cut]).to equal(k)
      expect(session.names.kind(:cut)).to eq(:knob)
      expect(render(session, 800)[-1]).to eq(1200)
      session.turn(:cut, 3000)
      expect(render(session, 800)[0]).to eq(3000)
    end

    it 'shares one knob between two loads of a document (the session\'s value wins)' do
      a = io.load(doc)
      b = io.load(doc, params: { cut: 2000 })
      session.add(a, name: :a, on: :now)
      session.add(b * 2, name: :b, on: :now)
      expect(render(session, 800)[-1]).to eq(800 + 1600)
      session.turn(:cut, 400)
      expect(render(session, 800)[-1]).to eq(400 + 800)
      expect(io.document_of(b).knob_nodes[:cut][0]).to equal(session.knobs[:cut])
      io.document_of(b)[:cut] = 1000 # Document#set turns the shared knob
      expect(render(session, 1600)[-1]).to eq(1000 + 2000)
    end

    it 'joins a knob the console defined' do
      session.knob(:cut, 500, range: 100..8000, curve: :exp, smooth: 0)
      session.add(io.load(doc), name: :x, on: :now)
      expect(render(session, 800)[-1]).to eq(500)
    end

    it 'sends name collisions through live_error' do
      session.knob(:cut, 0.5)
      expect { session.add(io.load(doc), name: :x, on: :now) }.to raise_error(ArgumentError, /doesn't match the session's/)

      s2 = new_session
      s2.names.claim(:cut, :track)
      expect { s2.add(io.load(doc), name: :x, on: :now) }.to raise_error(ArgumentError, /already a track/)
      s2.close
    end

    it 'keeps the knob standalone in live mode when the name is taken' do
      session.names.claim(:cut, :group)
      g = io.load(doc)
      allow(MB::Sound).to receive(:live?).and_return(true)
      expect { session.add(g, name: :x, on: :now) }.to output(/already a group/).to_stderr
      expect(session.knobs).to be_empty
      expect(render(session, 800)[-1]).to eq(800)
    end

    it 'registers knobs right away in the console preset command' do
      path = tmp_path('dc.mbg.rb')
      File.write(path, doc)
      g = within(session) { MB::Sound.preset(path) }
      expect(session.knobs[:cut]).to equal(io.document_of(g).knob_nodes[:cut][0])
      within(session) { MB::Sound.turn(:cut, 2500) }
      session.add(g, name: :x, on: :now)
      expect(render(session, 800)[-1]).to eq(2500)

      # An override of a knob that joins turns the shared knob (journaled, undoable)
      within(session) { MB::Sound.preset(path, cut: 900) }
      expect(session.journal.changes.last.kind).to eq(:turn)
      expect(session.journal.changes.last.data).to eq({ value: 900 })
      expect(render(session, 800)[-1]).to eq(900)
      within(session) { MB::Sound.undo(on: :now) }
      expect(render(session, 800)[-1]).to eq(2500)
      expect(io.document_of(within(session) { MB::Sound.preset(path, session: false) }).knob_nodes[:cut][0].session).to eq(nil)
    end
  end

  describe 'graph document knobs with a controller' do
    let(:session) { new_session }
    after { session.close }

    it 'listen to the session MIDI input when they join through Session#add or bg' do
      ev = MB::Sound::MIDI::Event
      doc = "graph 1\nknob :cut, 800.0, range: 100.0..6400.0, curve: :exp, cc: 74, takeover: :jump, smooth: 0\ncut * 1\n"
      session.knob_midi = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.cc(74, 1.0, time: 0.01r), ev.cc(74, 0.5, time: 0.05r)))
      g = MB::Sound::GraphIO.load(doc)
      session.add(g, name: :x, on: :now)
      expect(session.knobs[:cut].listening).not_to be_nil
      d = render(session, 4800)
      expect(d[480]).to be_within(1e-3).of(6400)
      expect(d[-1]).to be_within(1e-3).of(800) # halfway in octaves from 100 to 6400

      # The console's bg attaches it too (the input has a stream, so no live port opens)
      s2 = new_session
      s2.knob_midi = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.cc(74, 1.0, time: 0.01r)))
      within(s2) { MB::Sound.bg(:y, MB::Sound::GraphIO.load(doc)) }
      expect(s2.knobs[:cut].listening).not_to be_nil
      expect(render(s2, 4800)[-1]).to be_within(1e-3).of(6400)
      s2.close
    end
  end

  describe 'scenes and sections' do
    let(:session) { new_session }
    let(:set) { session.arrangement }

    after { session.close }

    before do
      @k = session.knob(:cut, 100, range: 100..8000, smooth: 0)
      set.track(:a, MB::Sound::GraphNode::Constant.new(1, sample_rate: 48000) * @k)
    end

    it 'turns knobs when scenes launch' do
      set.scene(:one, a: :on, cut: 400)
      set.scene(:two, a: :on, cut: [800, { over: 1.bar }])
      set.go(:one, on: :now)
      expect(render(session, 800)[-1]).to eq(400)
      set.go(:two)
      d = render(session, 96000 * 2)
      expect(d[96000 - 800 - 1]).to eq(400)
      expect(d[96000 - 800 + 48000]).to be_within(1).of(600)
      expect(d[-1]).to eq(800)
      expect(set.scene_info[:two]).to include('cut:800~')

      expect { set.scene(:bad, cut: 'loud') }.to raise_error(ArgumentError, /knob :cut takes/)
    end

    it 'turns knobs as form sections start' do
      set.scene(:intro, a: :on)
      set.scene(:drop, a: :on)
      within(session) {
        MB::Sound.flow(on: :now) do
          intro 1, cut: 300
          drop 1, cut: [600, { over: 2.beats }]
        end
      }
      d = render(session, 96000 * 2)
      expect(d[100]).to eq(300)
      expect(d[96000 - 1]).to eq(300)
      expect(d[96000 + 47999]).to eq(600)
      expect(session.arrangement.playback.form.to_ruby).to include('intro 1, cut: 300')

      expect {
        within(session) { MB::Sound.flow(play: false) { intro 1, cutt: 3 } }
      }.to raise_error(ArgumentError, /unknown options :cutt.*cut/m)
    end
  end

  describe 'snapshots' do
    let(:session) { new_session }

    after { session.close }

    before do
      @cut = session.knob(:cut, 100, range: 100..6400, curve: :exp, smooth: 0)
      @mix = session.knob(:mix, 0, smooth: 0)
      session.add(@cut * 1 + @mix * 10000, name: :x, on: :now)
    end

    it 'remembers and recalls every knob' do
      session.snap(:dark)
      session.turn(:cut, 6400)
      session.turn(:mix, 0.5)
      session.snap(:bright)
      render(session, 800)
      expect(session.snapshots).to eq({ dark: { cut: 100.0, mix: 0.0 }, bright: { cut: 6400.0, mix: 0.5 } })

      session.recall(:dark, over: 1.beat)
      d = render(session, 48000)
      expect(d[-1]).to eq(100)

      session.xfade(:dark, :bright, 0.5)
      expect(render(session, 800)[-1]).to be_within(0.01).of(800 + 2500) # halfway in octaves and linearly
    end

    it 'crossfades by a knob' do
      session.snap(:dark)
      session.turn(:cut, 6400)
      session.turn(:mix, 1)
      session.snap(:bright)
      morph = session.knob(:morph, 0, smooth: 0)
      session.xfade(:dark, :bright, :morph)
      expect(render(session, 800)[-1]).to eq(100)
      session.turn(:morph, 0.5)
      expect(render(session, 800)[-1]).to be_within(0.01).of(800 + 5000)
      expect(@cut.mode).to eq(:follow)
      expect(morph.value).to eq(0.5)

      # A crossfader knob captured in the snapshots stays where it is
      session.snap(:with_morph)
      session.xfade(:with_morph, :bright, :morph)
      render(session, 800)
      expect(morph.mode).to eq(:hold)

      expect { session.recall(:nope) }.to raise_error(ArgumentError, /No snapshot :nope/)
    end
  end

  describe 'MIDI' do
    let(:session) { new_session }

    after { session.close }

    def cc_stream(*events)
      MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
    end

    it 'follows a controller, picking up when it passes the knob' do
      ev = MB::Sound::MIDI::Event
      stream = cc_stream(
        ev.cc(74, 0.1, time: 0.01r), ev.cc(74, 0.3, time: 0.02r), # below 0.5: ignored
        ev.cc(74, 0.6, time: 0.03r),                               # passes 0.5: picked up
        ev.cc(74, 0.8, time: 0.04r), ev.cc(1, 0.0, time: 0.05r)    # another CC: ignored
      )
      session.knob_midi = stream
      k = session.knob(:x, 0.5, smooth: 0)
      session.bind_cc(:x, 74)
      session.add(k * 1, name: :x, on: :now)
      d = render(session, 4800, 480)
      expect(d[1439]).to eq(0.5)
      expect(d[1440]).to be_within(1e-6).of(0.6)
      expect(d[1920]).to be_within(1e-6).of(0.8)
      expect(d[-1]).to be_within(1e-6).of(0.8)
      expect(k.picked_up?).to eq(true)
    end

    it 'jumps right away with takeover: :jump, and learns the next controller moved' do
      ev = MB::Sound::MIDI::Event
      session.knob_midi = cc_stream(ev.cc(20, 0.1, time: 0.01r), ev.cc(20, 0.2, time: 0.02r))
      k = session.knob(:x, 0.5, smooth: 0, takeover: :jump)
      session.learn(:x)
      expect(k.learning?).to eq(true)
      session.add(k * 1, name: :x, on: :now)
      d = render(session, 4800)
      expect(k.cc).to eq(20)
      expect(d[480]).to be_within(1e-6).of(0.1)
      expect(d[-1]).to be_within(1e-6).of(0.2)
    end
  end

  describe 'console names' do
    names = %i[knob knobs turn move snap snaps recall xfade crossfade learn]

    it 'are KnobMethods, not Kernel or Object methods, and not Pry commands' do
      require 'pry'
      pry_commands = Pry::Commands.keys.map(&:to_s)
      names.each do |n|
        expect(MB::Sound.method(n).owner).to eq(MB::Sound::KnobMethods), "#{n} is defined by #{MB::Sound.method(n).owner}"
        expect(Object.new.respond_to?(n, true)).to eq(false), "#{n} is an Object method"
        expect(pry_commands).not_to include(n.to_s)
        expect(MB::Sound::GraphNode.method_defined?(n)).to eq(false), "#{n} is a GraphNode method"
      end
    end
  end
end
