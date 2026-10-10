RSpec.describe(MB::Sound::LaunchPoint) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames, a beat 24000
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  # The first sample where a 1.constant added with +opts+ after 4000
  # frames of a silent bed starts.
  def landing(**opts)
    session.add(0.constant, name: :bed)
    run(4000)
    session.add(1.constant, name: :x, fade: 0, **opts)
    data = run(400000)
    idx = data.to_a.index { |v| v != 0 }
    idx && idx + 4000
  end

  def resolve(now: 0r, default: nil, **opts)
    point = MB::Sound::LaunchPoint.build(at: opts[:at], on: opts[:on], offset: opts[:in])
    point.resolve(now: now, transport: transport, default: default)
  end

  describe 'on: (alignment)' do
    {
      { on: :now } => 4000,
      { on: 0 } => 4000,
      { on: :beat } => 24000,
      { on: :bar } => 96000,
      { on: 2 } => 192000,
      { on: 1/2r } => 48000,
      { on: 1.n16 } => 6000,
      { on: 2.beats } => 48000,
      { at: :bar } => 96000,
      { at: :beat } => 24000,
    }.each do |opts, expected|
      it "lands #{opts} on sample #{expected}" do
        expect(landing(**opts)).to eq(expected)
      end
    end

    it 'lands a note grid exactly where the old note-division at: did' do
      # Old `bg ..., at: 4` (a quarter note grid) is now `on: 1.n4`
      expect(landing(on: 1.n4)).to eq(24000)
    end
  end

  describe 'in: (relative placement)' do
    {
      { in: 1, on: :now } => 4000 + 96000,
      { in: 1/4r, on: :now } => 4000 + 24000,
      { in: 2.beats, on: :now } => 4000 + 48000,
      { in: 2400.samples, on: :now } => 4000 + 2400,
      { in: 0, on: :now } => 4000,
      { in: 1.beat, on: :beat } => 48000,
      { in: 1, on: 2 } => 192000,
      { in: 2.bars, on: :beat } => 4000 + 192000 + 20000,
      # Without on:, the alignment it would have anyway (:bar while
      # something plays)
      { in: 0 } => 96000,
      { in: 1/4r } => 96000,
      { in: 1 } => 192000,
    }.each do |opts, expected|
      it "lands #{opts} on sample #{expected}" do
        expect(landing(**opts)).to eq(expected)
      end
    end

    it 'lands exactly when nothing plays (the default alignment is :now)' do
      session.add(1.constant, name: :x, fade: 0, in: 1/4r)
      data = run(48000)
      expect(data.to_a.index { |v| v != 0 }).to eq(24000)
    end
  end

  describe 'at: (absolute placement)' do
    {
      { at: MB::Sound.bar(2) } => 96000,
      { at: MB::Sound.bar(2, beat: 3), on: :now } => 96000 + 48000,
      { at: MB::Sound.bar(2, beat: 3) } => 192000, # :bar, as without at:
      { at: MB::Sound.bar(1, beat: 4), on: :now } => 72000,
      { at: MB::Sound.bar(2), on: 1.n16 } => 96000,
      { at: MB::Sound.bar(1, beat: 4), on: 1.n16 } => 72000,
    }.each do |opts, expected|
      it "lands #{opts} on sample #{expected}" do
        expect(landing(**opts)).to eq(expected)
      end
    end

    it 'rejects a position that has already passed, or lands it now in live mode' do
      session.add(0.constant, name: :bed)
      run(96000 * 2 + 800)
      expect {
        session.add(1.constant, name: :x, fade: 0, at: MB::Sound.bar(2))
      }.to raise_error(ArgumentError, /bar\(2\) has already passed \(the timeline is at 3:1\.0/)

      MB::Sound.live = true
      expect {
        session.add(1.constant, name: :x, fade: 0, at: MB::Sound.bar(2), on: :now)
      }.to output(/already passed.*landing now/).to_stderr
      data = run(8000)
      expect(data[0]).to eq(1)
    ensure
      MB::Sound.live = false
    end

    it 'rejects Durations and Lengths, pointing to bar(n)' do
      expect { session.add(1.constant, at: 32.bars) }.to raise_error(ArgumentError, /not lengths.*bar\(n\)/)
      expect { session.add(1.constant, at: 3.beats) }.to raise_error(ArgumentError, /bar\(n, beat: b\)/)
      expect { session.add(1.constant, at: 2.seconds) }.to raise_error(ArgumentError, /not lengths/)
    end
  end

  describe 'errors' do
    it 'rejects a plain number in at:, suggesting the new forms' do
      expect { session.add(1.constant, at: 4) }.to raise_error(ArgumentError, /on: 1\.n4.*on: 4.*in: 4.*at: bar\(4\)/)
      expect { session.add(1.constant, at: 2r) }.to raise_error(ArgumentError, /ambiguous/)
      expect { session.add(1.constant, at: 0.5) }.to raise_error(ArgumentError, /ambiguous/)
      expect { session.mute(:x, at: 2) }.to raise_error(ArgumentError, /ambiguous/)
      expect { session.undo(at: 1) }.to raise_error(ArgumentError, /ambiguous/)
      session.arrangement.track(:t, 1.constant)
      session.arrangement.scene(:s, t: :on)
      expect { session.arrangement.go(:s, at: 4) }.to raise_error(ArgumentError, /ambiguous/)
      expect(session.queued(:t)).to be_empty
    end

    it 'skips the command with a warning in live mode' do
      MB::Sound.live = true
      expect {
        expect(session.add(1.constant, name: :x, at: 4)).to be_nil
        expect(MB::Sound::Session.with_context(session: session) { MB::Sound.bg(:y, 1.constant, at: 4) }).to be_nil
      }.to output(/ambiguous.*live mode: ignored/).to_stderr
      expect(session.players).to be_empty
    ensure
      MB::Sound.live = false
    end

    it 'rejects at: with in:' do
      expect { session.add(1.constant, at: MB::Sound.bar(3), in: 1) }.to raise_error(ArgumentError, /not both/)
    end

    it 'rejects an alignment Symbol in at: with on:' do
      expect { session.add(1.constant, at: :bar, on: :beat) }.to raise_error(ArgumentError, /not both/)
    end

    it 'rejects bad values' do
      expect { session.add(1.constant, on: :later) }.to raise_error(ArgumentError, /Unknown launch point/)
      expect { session.add(1.constant, at: :later) }.to raise_error(ArgumentError, /Unknown launch point/)
      expect { session.add(1.constant, in: MB::Sound.bar(3)) }.to raise_error(ArgumentError, /position; use at:/)
      expect { session.add(1.constant, in: -1) }.to raise_error(ArgumentError, /in: must be/)
      expect { session.add(1.constant, on: -1) }.to raise_error(ArgumentError, /on: must be/)
      expect { session.add(1.constant, at: 'bar 3') }.to raise_error(ArgumentError, /at: must be/)
    end
  end

  describe '#resolve' do
    it 'counts plain numbers as bars of the transport' do
      transport.bar_length = 3/4r
      expect(resolve(now: 1/8r, on: 2)).to eq(3/2r)
      expect(resolve(now: 1/8r, in: 2)).to eq(1/8r + 3/2r)
      expect(resolve(now: 0r, at: MB::Sound.bar(3, beat: 2))).to eq(3/2r + 1/4r)
    end

    it 'returns nil without a launch point or default, and uses the default otherwise' do
      expect(resolve(now: 1/8r)).to be_nil
      expect(resolve(now: 1/8r, default: :bar)).to eq(1r)
      expect(resolve(now: 1/8r, in: 1/4r, default: :bar)).to eq(1r) # in:, then the default alignment
      expect(resolve(now: 1/8r, in: 1/4r)).to eq(1/8r + 1/4r)       # no default alignment: exact
    end

    it 'keeps a time already on the grid' do
      expect(resolve(now: 2r, on: :bar)).to eq(2r)
      expect(resolve(now: 1r, in: 1, on: 2)).to eq(2r)
    end
  end

  describe 'bar()' do
    it 'makes absolute bar positions counting from 1, like at_bar' do
      expect(MB::Sound.bar(1).whole_notes(1r)).to eq(0)
      expect(MB::Sound.bar(33).whole_notes(1r)).to eq(32)
      expect(MB::Sound.bar(33, beat: 3).whole_notes(3/4r)).to eq(24 + 1/2r)
      expect(MB::Sound.bar(33)).to be_a(MB::Sound::LaunchPoint::Bar)
      expect(MB::Sound.bar(33).inspect).to eq('bar(33)')
      expect(MB::Sound.bar(2, beat: 3).inspect).to eq('bar(2, beat: 3)')
    end

    it 'rejects bars and beats before 1' do
      expect { MB::Sound.bar(0) }.to raise_error(ArgumentError, /at least 1/)
      expect { MB::Sound.bar(2, beat: 0) }.to raise_error(ArgumentError, /at least 1/)
    end
  end

  describe 'console commands' do
    def within(&block)
      MB::Sound::Session.with_context(session: session, &block)
    end

    def first_change(data, from = 0)
      data.to_a.each_with_index.find { |v, i| i >= from && v != data[from] }&.last
    end

    it 'count in: from a scheduled block time' do
      within do
        MB::Sound.bg(:bed, 0.constant)
        MB::Sound.at_bar(2) { MB::Sound.bg(:x, 1.constant, in: 1.beat, on: :now, fade: 0) }
        MB::Sound.at_bar(2) { MB::Sound.bg(:y, 2.constant, in: 1.beat, fade: 0) } # then the next bar
      end
      data = run(96000 * 3)
      expect(first_change(data)).to eq(96000 + 24000)
      expect(first_change(data, 96000 + 24000)).to eq(192000)
    end

    it 'land swap, resume, and master at each form' do
      c3 = MB::Sound::C3.number
      d3 = MB::Sound::D3.number
      clip_a = MB::Sound.seq(MB::Sound::C3).n1.loop
      clip_b = MB::Sound.seq(MB::Sound::D3).n1.loop
      within do
        MB::Sound.bg(:bed, 0.constant, fade: 0) # keeps the timeline moving after :x stops
        MB::Sound.bg(:x, clip_a.number, fade: 0, on: :now)
        MB::Sound.swap(:x, clip_b, at: MB::Sound.bar(3))
        MB::Sound.master(in: 1/2r, on: :now) { |m| m * 2 }
      end
      data = run(96000 * 4)
      expect(data[0]).to eq(c3)
      expect(data[48000 - 1]).to eq(c3)
      expect(data[48000]).to eq(c3 * 2)
      expect(data[192000 - 1]).to eq(c3 * 2)
      expect(data[192000]).to eq(d3 * 2)

      within { MB::Sound.stop(:x, fade: 0) }
      run(800)
      within { MB::Sound.resume(:x, on: 2, fade: 0) }
      # 4 bars + 800 frames now, so the next 2-bar line is bar 7 (6 bars)
      data = run(96000 * 2)
      expect(first_change(data)).to eq(96000 * 6 - (96000 * 4 + 800))
    end

    it 'land mutes, scenes, and undo at each form' do
      set = session.arrangement
      clip = MB::Sound.seq(MB::Sound::C3).n1.loop
      within do
        set.track(:a, q: 2) { |c| c.number }
        set.scene(:one, a: clip)
        expect(MB::Sound.go(:one, at: MB::Sound.bar(2)).lands.pos).to eq(1r)
      end
      run(96000 * 2)

      within { MB::Sound.mute(:a, in: 1/4r) }
      data = run(96000)
      # The 5 ms declick ramp starts on sample 24000 (at full level)
      expect(first_change(data)).to eq(24001)
      expect(data[24000 + 240]).to eq(0)

      within { MB::Sound.undo(on: 1.n8) }
      # 3 bars now: on the grid already, so it lands right away
      data = run(800)
      expect(data[0]).to eq(0)
      expect(data[799]).to eq(MB::Sound::C3.number)
    end

    it 'keeps track q: as an alignment in bars' do
      set = session.arrangement
      clip = MB::Sound.seq(MB::Sound::C3).n1.loop
      within do
        MB::Sound.bg(:bed, 0.constant)
        set.track(:a, q: 4) { |c| c.number }
        set.scene(:one, a: clip)
      end
      run(4000)
      within { MB::Sound.go(:one) }
      expect(first_change(run(96000 * 5))).to eq(96000 * 4 - 4000)
      expect(within { MB::Sound.quant(2.beats) }).to eq(2.beats)
    end

    it 'aligns Set tracks to their q: after in: or at: unless on: is given' do
      set = session.arrangement
      clip = MB::Sound.seq(MB::Sound::C3).n1.loop
      clip2 = MB::Sound.seq(MB::Sound::D3).n1.loop
      within do
        MB::Sound.bg(:bed, 0.constant)
        set.track(:a, q: 4) { |c| c.number }
        set.track(:b, q: :beat) { |c| c.number }
        set.scene(:one, a: clip, b: clip2)
      end
      run(4000)
      # a: 1 bar + 4000 frames, then the next 4-bar line; b: the next beat
      within { MB::Sound.go(:one, in: 1) }
      expect(session.queued(:a).map { |e| e.lands.pos }).to eq([4r])
      expect(session.queued(:b).map { |e| e.lands.pos }).to eq([5/4r])
      session.cancel_changes(*session.queued.map(&:seq))

      within { MB::Sound.go(:one, in: 1, on: :now) }
      expect(session.queued(:a).map { |e| e.lands.pos }).to eq([1 + 4000/96000r])
      session.cancel_changes(*session.queued.map(&:seq))

      within { MB::Sound.go(:one, at: MB::Sound.bar(2, beat: 2)) }
      expect(session.queued(:a).map { |e| e.lands.pos }).to eq([4r])
      expect(session.queued(:b).map { |e| e.lands.pos }).to eq([5/4r])
    end
  end
end
