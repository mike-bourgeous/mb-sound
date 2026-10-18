RSpec.describe(MB::Sound::Session::Master) do
  # 120 BPM at 48kHz: a bar is 96000 frames.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:raise_errors) { true }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: raise_errors) }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns both channels.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
  end

  def chains
    session.instance_variable_get(:@master_chains)
  end

  it 'passes the mix through unchanged with no master chain' do
    session.add([1.constant, 2.constant])
    expect(run(800).map { |c| c[0] }).to eq([1, 2])
    expect(session.master_info).to eq('bypass')
    expect(session.master_active?).to eq(false)
  end

  describe 'master gain placement' do
    let(:gained) { MB::Sound::Session.new(master_gain: 2.db, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

    after { gained.close }

    def run_gained(frames)
      Array.new(frames / 800) { gained.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
    end

    it 'applies the gain before the chain by default, so a clipper keeps its ceiling' do
      expect(gained.master_gain_post?).to eq(false)
      gained.add([0.9.constant, -0.9.constant])
      gained.master { |mix| mix.aclip(-0.95, 0.95) }
      out = run_gained(800)
      expect(out[0][0]).to be_within(1e-6).of(0.95)
      expect(out[1][0]).to be_within(1e-6).of(-0.95)
    end

    it 'applies the gain after the chain with master_gain_post' do
      gained.master_gain_post = true
      gained.add([0.9.constant, -0.9.constant])
      gained.master { |mix| mix.aclip(-0.95, 0.95) }
      out = run_gained(800)
      expect(out[0][0]).to be_within(1e-6).of(0.9 * 2.db)
      expect(out[1][0]).to be_within(1e-6).of(-0.9 * 2.db)
    end

    it 'gives the same samples either way without a master chain' do
      a = MB::Sound::Session.new(master_gain: -7.db, master_gain_post: true, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), buffer_size: 800, realtime: false, raise_errors: true)
      b = MB::Sound::Session.new(master_gain: -7.db, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120), buffer_size: 800, realtime: false, raise_errors: true)
      [a, b].each { |s| s.add([MB::Sound.with_seed(3) { 220.hz.saw.rnd }, 330.hz.triangle * 0.7]) }
      5.times { expect(a.process_buffer.map(&:to_a)).to eq(b.process_buffer.map(&:to_a)) }
    ensure
      a&.close
      b&.close
    end

    it 'rejects anything but true or false' do
      expect { gained.master_gain_post = 1 }.to raise_error(ArgumentError)
    end

    it 'sets the placement with master_gain(post:) and keeps it until changed' do
      MB::Sound.master_gain(2.db, post: true)
      expect(MB::Sound::Session.current.master_gain_post?).to eq(true)
      MB::Sound.master_gain(1.db)
      expect(MB::Sound::Session.current.master_gain_post?).to eq(true)
      MB::Sound.master_gain(post: false)
      expect(MB::Sound::Session.current.master_gain_post?).to eq(false)
      expect(MB::Sound.master_gain).to be_within(1e-9).of(1.db)
    end
  end

  describe 'blocks' do
    before { session.add([1.constant, 2.constant]) }

    it 'gives a one-parameter block the whole mix as a bundle' do
      given = []
      session.master { |mix| given << mix; mix * 10 }
      expect(given.length).to eq(1)
      expect(given[0]).to be_a(MB::Sound::GraphNode::Channels)
      expect(given[0].channel_count).to eq(2)
      expect(run(800).map { |c| c[0] }).to eq([10, 20])
      expect(session.master_active?).to eq(true)
    end

    it 'gives every channel to a block with one parameter per channel' do
      session.master { |l, r| [r, l] }
      expect(run(800).map { |c| c[0] }).to eq([2, 1])
    end

    it 'gives every channel to a splat block' do
      session.master { |*ch| ch.map { |c| c * 3 } }
      expect(run(800).map { |c| c[0] }).to eq([3, 6])
    end

    it 'plays a single node from a multichannel block on every channel, sampling it once' do
      node = 0.constant
      session.master { |l, r| node = (l + r).named('sum') }
      expect(node).to receive(:sample).once.and_call_original
      expect(run(800).map { |c| c[0] }).to eq([3, 3])
    end

    it 'accepts MultiOutput nodes' do
      session.master { |l, r| l.reverb(room_size: 0.2, output_channels: 2, dry: 1, wet: 0) }
      expect(run(800).map { |c| c[0].round(5) }).to eq([1, 1])
    end

    it 'rejects blocks with the wrong number of parameters' do
      expect { session.master { |a, b, c| a } }.to raise_error(ArgumentError, /one parameter.*or 2/)
    end

    it 'rejects blocks that return the wrong number of channels' do
      expect { session.master { |m| [m[0], m[1], m[0]] } }.to raise_error(ArgumentError, /3 channels for a 2-channel/)
    end

    it 'runs a stereo reverb on the whole mix' do
      session.master { |mix| mix.reverb(:room) }
      expect(run(800).map { |c| c[0] }).to all(be_a(Float))
      expect(session.master_info).to include('Reverb')
    end

    it 'rejects the wrong number of channels and things that are not nodes' do
      expect { session.master { |l, r| [l, r, l] } }.to raise_error(ArgumentError, /3 channels for a 2-channel/)
      expect { session.master { |m| 5 } }.to raise_error(ArgumentError, /must return a GraphNode/)
    end
  end

  describe 'switching chains' do
    before do
      session.add(1.constant)
      run(1600)
    end

    it 'starts the first chain on the next bar while something is playing' do
      session.master { |m| m * 2 }
      expect(session.master_info).to match(/starts at bar 2/)
      data = run(96000)[0]
      expect(data[94399]).to eq(1)
      expect(data[94400]).to eq(2)
    end

    it 'supports launch points and scheduled start times' do
      session.master(at: :now) { |m| m * 2 }
      expect(run(800)[0][0]).to eq(2)

      session.master(start_time: transport.position + 1000r / 96000) { |m| m * 3 }
      data = run(1600)[0]
      expect(data[999]).to eq(2)
      expect(data[1000]).to eq(3)
    end

    it 'keeps the latest of several chains starting at the same time' do
      session.master { |m| m * 2 }
      session.master { |m| m * 3 }
      expect(session.queued(:master).length).to eq(2) # both wait in the change queue
      expect(run(96000)[0][-1]).to eq(3)
    end

    it 'starts chains queued for different times at each time' do
      # Played 1600 frames already; 1/4r is frame 24000
      session.master(start_time: 1/2r) { |m| m * 3 }
      session.master(start_time: 1/4r) { |m| m * 2 }
      data = run(96000)[0]
      expect(data[24000 - 1600 - 1]).to eq(1)
      expect(data[24000 - 1600]).to eq(2)
      expect(data[48000 - 1600 - 1]).to eq(2)
      expect(data[48000 - 1600]).to eq(3)
    end

    it 'lets the old chain spill over its tail by default' do
      session.master(at: :now) { |m| m.delay(4000.samples) }
      run(8000)

      session.master(in: 2400.samples, on: :now) { |m| m * 1 }
      data = run(56000)[0]

      # The delay's tail of the old input plays on top of the new chain
      expect(data[0...2400].to_a.uniq).to eq([1])
      expect(data[2400...6400].to_a.uniq).to eq([2])
      expect(data[6400..].to_a.uniq).to eq([1])

      # The old chain is dropped once it has been quiet for a second
      expect(chains.length).to eq(1)
    end

    it 'crossfades chains with a fade length' do
      session.master(at: :now) { |m| m * 2 }
      run(800)
      session.master(at: :now, fade: 1/4r) { |m| m * 4 }
      data = run(24800)[0]
      expect(data[0]).to be_within(0.001).of(2)
      expect(data[12000]).to be_within(0.001).of(3)
      expect(data[24000..].to_a.uniq).to eq([4])
      expect(chains.length).to eq(1)
    end

    it 'cuts over without a tail given a zero fade' do
      session.master(at: :now) { |m| m.delay(4000.samples) }
      run(8000)
      session.master(at: :now, fade: 0) { |m| m * 1 }
      expect(run(8000)[0].to_a.uniq).to eq([1])
      expect(chains.length).to eq(1)
    end

    it 'switches back to bypass and forgets finished chains' do
      session.master(at: :now) { |m| m * 2 }
      run(800)
      session.master(at: :now)
      expect(run(800)[0][0]).to eq(1)

      # The old chain is kept until its (silent) tail has been quiet for a second
      run(47200)
      expect(chains.length).to eq(2)
      run(800)
      expect(chains).to be_empty
      expect(session.master_active?).to eq(false)
    end

    it 'cuts over when processing is overloaded' do
      session.instance_variable_set(:@realtime, true)
      allow(session).to receive(:start_thread) # render here, not in a thread
      allow(session).to receive(:process_master).and_wrap_original do |m, *args, **kw|
        session.instance_variable_set(:@load, 0.9)
        m.call(*args, **kw)
      end
      # Both switches warn: the first (from no chain) and the one checked
      expect(session).to receive(:warn).with(/busy \(90%\).*without spillover/).twice
      session.master(at: :now) { |m| m.delay(4000.samples) }
      run(8000)

      session.master(at: :now) { |m| m * 1 }
      expect(run(800)[0].to_a.uniq).to eq([1])
    end
  end

  describe 'tails' do
    it 'keeps processing while idle so tails ring out' do
      session.add(1.constant.until(800 / 48000.0))
      session.master(at: :now) { |m| m.delay(1600.samples) }
      data = run(4000)[0]
      expect(data[1600...2400].to_a.uniq).to eq([1])
      expect(transport.position).to eq(1600r / 96000)
    end

    it 'caps a spillover tail that never goes quiet' do
      session.add(1.constant)
      session.master(at: :now) { |m| m.delay(800.samples, feedback: 0.9999, wet: 0.001) }
      run(1600)
      session.master(at: :now) { |m| m * 1 }
      run(48000 * 10)
      expect(chains.length).to eq(2)
      run(48000 * 0.1 + 800)
      expect(chains.length).to eq(1)
    end
  end

  describe 'errors' do
    let(:raise_errors) { false }

    it 'bypasses a chain that raises an error' do
      session.add(1.constant)
      calls = 0
      session.master { |m| m.proc { |d| (calls += 1) > 2 ? raise('broken') : d * 2 } } # 2 channels
      expect(session).to receive(:warn).with(/stopped with an error.*broken/m)
      expect(run(1600)[0].to_a.values_at(0, 800)).to eq([2, 1])
      expect(session.master_active?).to eq(false)
    end

    it 'bypasses a chain that ends' do
      session.add(1.constant)
      session.master { |m| m * 2.constant.until(800 / 48000.0) }
      expect(session).to receive(:warn).with(/master chain ended/)
      expect(run(1600)[0].to_a.values_at(0, 800)).to eq([2, 1])
    end
  end

  describe '#reset_master' do
    it 'rebuilds the chain, clearing tails' do
      session.add(1.constant.until(800 / 48000.0))
      session.master(at: :now) { |m| m.delay(1600.samples) * 2 }
      run(800)
      session.reset_master
      expect(run(4000)[0].to_a.uniq).to eq([0])
      expect(session.master_info).to start_with('master:')
      expect(chains.length).to eq(1)
    end

    it 'does nothing without a master chain' do
      session.reset_master
      expect(chains).to be_empty
    end
  end

  it 'gives taps the mix after the master chain' do
    seen = nil
    session.add_tap { |mix| seen = mix }
    session.add(1.constant)
    session.master { |m| m * 5 }
    session.process_buffer
    expect(seen.map { |c| c[0] }).to eq([5, 5])
  end

  it 'keeps clips in master chains on the timeline' do
    session.add(1.constant)
    gate = MB::Sound.grid(4, 'x...').loop.gate
    session.master { |m| m * gate }
    data = run(96000)[0]
    expect(data[0]).to eq(1)
    expect(data[24000]).to eq(0)

    # Clips follow seeks
    transport.seek(1 - 800r / 96000)
    expect(run(1600)[0].to_a.values_at(0, 800)).to eq([0, 1])
  end

  describe 'clips counted from the chain launch' do
    before do
      session.add(1.constant)
      run(800)
    end

    it 'keeps the anchor of launch-aligned loops through seeks and rewinds' do
      gate = MB::Sound.grid(4, 'x..').loop(align: :launch).gate # 3 beats, gate on in the first
      session.master(start_time: 1r, fade: 0) { |m| m * gate }
      data = run(96000 * 2)[0] # from frame 800
      frames = [96000 - 1, 96000, 96000 + 23999, 96000 + 24000, 96000 + 71999, 96000 + 72000]
      expect(data.to_a.values_at(*frames.map { |f| f - 800 })).to eq([1, 1, 1, 0, 0, 1]) # the mix passes before the chain

      # Rewound to beat 2 (1/4): three beats before the anchor, so on.
      # Seeked to bar 3 (2): a beat past a cycle start, so off (a restart
      # would turn it on).
      transport.seek(1/4r)
      expect(run(800)[0][0]).to eq(1)
      transport.seek(2r)
      expect(run(800)[0][0]).to eq(0)
      transport.seek(7/4r)
      expect(run(800)[0][0]).to eq(1)
    end

    it 'counts non-looping clips from the chain start through seeks, like players' do
      # One quarter note in a long non-looping clip (so the chain doesn't end)
      gate = MB::Sound::Sequence::Clip.new(MB::Sound::C4.n4.events, length: 8).gate
      session.master(start_time: 1r, fade: 0) { |m| m * gate }
      data = run(96000 + 48000)[0] # from frame 800
      expect(data.to_a.values_at(*[96000 - 1, 96000 + 23999, 96000 + 24000].map { |f| f - 800 })).to eq([1, 1, 0])

      # Seeking past the note stays silent, and rewinding an eighth before
      # the chain start plays the note an eighth (12000 frames) later; a
      # restart would play it right away both times
      transport.seek(1 + 3/8r)
      expect(run(800)[0][0]).to eq(0)
      transport.seek(7/8r)
      data = run(12800)[0]
      expect(data.to_a.values_at(0, 11999, 12000)).to eq([0, 0, 1])
    end
  end

  # fixes-12: a master chain waiting to start (queued for a later launch
  # point, or by an undo) wasn't read while it waited, so it played a node
  # it shares with a playing graph late by its wait, and after more than a
  # second its first read raised BranchBufferOverflow; a muted player
  # sharing a node only with a master chain did the same on unmuting.
  describe 'nodes shared with players' do
    def mono_session
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

    # The LFO's first +frames+ samples.
    def lfo_values(frames)
      3.hz.lfo.sample(frames).dup
    end

    # Buffer sizes to render in (mixed, the usual, tiny)
    def buffer_sizes
      [[128, 801, 7], [800], [7]]
    end

    [[0.3, 25_933], [1.5, 800]].each do |wait, added|
      it "starts a chain queued for #{wait} s in step with a node a player plays, at any buffer size" do
        start = added + (wait * 48000).round # not on a buffer edge
        buffer_sizes.each do |sizes|
          lfo = 3.hz.lfo
          s = mono_session
          s.add(lfo * 0.5, name: :a)
          data = run_in(s, added, sizes)
          s.master(start_time: Rational(start, 96000)) { |mix| mix * (lfo * 0.5 + 1) }
          expect(s.queued.map(&:kind)).to eq([:master])
          data = data.concatenate(run_in(s, start + 24000 - added, sizes))

          l = lfo_values(data.length)
          expected = l * 0.5
          expected[start..] = l[start..] * 0.5 * (l[start..] * 0.5 + 1)
          expect(data.abs.max).to be > 0.7
          expect((data - expected).abs.max).to be < 1e-6
          expect(s.instance_variable_get(:@waiting_graphs)).to be_empty
        ensure
          s&.close
        end
      end
    end

    it 'starts a replacement chain in step with a node the spilling chain reads' do
      buffer_sizes.each do |sizes|
        lfo = 3.hz.lfo
        s = mono_session
        s.add(0.5.constant, name: :a)
        s.master(on: :now) { |mix| mix * (lfo * 0.5 + 1) }
        data = run_in(s, 800, sizes)
        start = 800 + 72_001
        s.master(start_time: Rational(start, 96000)) { |mix| mix * (lfo * 0.25 + 1) }
        data = data.concatenate(run_in(s, start + 24000 - 800, sizes))

        l = lfo_values(data.length)
        expected = (l * 0.5 + 1) * 0.5
        expected[start..] = (l[start..] * 0.25 + 1) * 0.5
        expect((data - expected).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it 'keeps a muted player in step with a node only a master chain also reads' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = mono_session
        s.add(lfo * 0.5, name: :a)
        s.add(0.5.constant, name: :b)
        s.master(on: :now) { |mix| mix * (lfo * 0.5 + 1) }
        data = run_in(s, 800, sizes)
        s.mute(:a)
        data = data.concatenate(run_in(s, 72_000, sizes))
        s.unmute(:a)
        data = data.concatenate(run_in(s, 24_000, sizes))

        l = lfo_values(data.length)
        expected = (l * 0.5 + 0.5) * (l * 0.5 + 1)
        expect((data[-20_000..] - expected[-20_000..]).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end

    it 'restores an undone chain in step with a node a player plays' do
      [[128, 801, 7], [800]].each do |sizes|
        lfo = 3.hz.lfo
        s = mono_session
        within = ->(&block) { MB::Sound::Session.with_context(session: s, &block) }
        within.() { MB::Sound.bg(:a, lfo * 0.5) }
        within.() { MB::Sound.master(at: :now) { |mix| mix * (lfo * 0.5 + 1) } }
        data = run_in(s, 800, sizes)
        within.() { MB::Sound.master(at: :now) { |mix| mix * 0.5 } }
        data = data.concatenate(run_in(s, 800, sizes))
        within.() { MB::Sound.undo } # lands on the next bar
        expect(s.queued.map(&:kind)).to eq([:restore])
        data = data.concatenate(run_in(s, 96_000 + 24_000 - 1600, sizes))

        l = lfo_values(data.length)
        expected = l * 0.5 * (l * 0.5 + 1)
        expect((data[96_000..] - expected[96_000..]).abs.max).to be < 1e-6
        expect((data[1600...96_000] - l[1600...96_000] * 0.25).abs.max).to be < 1e-6
      ensure
        s&.close
      end
    end
  end
end
