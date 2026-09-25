RSpec.describe(MB::Sound::Session) do
  # 120 BPM at 48kHz: a whole note (one bar) is 2 seconds = 96000 frames, a
  # quarter note is 24000 frames, a sixteenth is 6000 frames.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

  # Renders +frames+ frames (in 800-frame buffers) and returns channel 0.
  def run(frames)
    bufs = []
    (frames / 800).times { bufs << session.process_buffer[0].dup }
    bufs.reduce(:concatenate)
  end

  def nonzero(data)
    data.to_a.each_index.select { |i| data[i] != 0 }
  end

  describe '#add' do
    it 'starts the first graph right away' do
      session.add(1.constant)
      expect(run(800)[0]).to eq(1)
    end

    it 'starts later graphs on the next bar by default' do
      session.add(0.constant)
      run(4000)
      session.add(1.constant)
      data = run(96000)
      expect(nonzero(data).first).to eq(96000 - 4000)
    end

    it 'supports other launch points' do
      { now: 0, beat: 24000 - 4000, 16 => 6000 - 4000, 2r => 192000 - 4000 }.each do |at, expected|
        t = MB::Sound::Sequence::Transport.new(bpm: 120)
        s = MB::Sound::Session.new(output: output, transport: t, buffer_size: 800, realtime: false, raise_errors: true)
        s.add(0.constant)
        5.times { s.process_buffer }
        s.add(10.constant, at: at)
        data = Array.new(250) { s.process_buffer[0].dup }.reduce(:concatenate)
        expect(nonzero(data).first).to eq(expected), "launch point #{at.inspect}"
      end
    end

    it 'launches :clip graphs when all of their looping clips line up' do
      session.add(0.constant)
      run(4000)
      clip = MB::Sound.grid(16, 'x.x') # 3/16 whole notes
      session.add(clip.loop.trigger + clip.loop.transpose(2).trigger * 0, at: :clip)
      data = run(40000)
      expect(nonzero(data).first).to eq(18000 - 4000)
    end

    it 'rejects unknown launch points' do
      session.add(0.constant)
      expect { session.add(1.constant, at: :later) }.to raise_error(ArgumentError, /Unknown launch point/)
    end

    it 'keeps graphs that share a looping clip in sync whenever they start' do
      clip = MB::Sound.grid(16, 'x...x...x.x.x...').loop
      session.add(clip.trigger)
      run(40000)
      session.add(clip.trigger(range: 0..2))
      data = run(96000 * 2)

      hits = nonzero(data)
      joined = 96000 - 40000
      expect(hits.select { |i| i >= joined }.map { |i| data[i] }.uniq).to eq([2.25])
      expect(hits.select { |i| i < joined }.map { |i| data[i] }.uniq).to eq([0.75])
    end

    it 'plays one-shot clips from their start when launched' do
      session.add(0.constant)
      run(4000)
      session.add(MB::Sound.grid(16, '.x').trigger)
      expect(nonzero(run(100000))).to eq([96000 - 4000 + 6000])
    end

    it 'starts held note numbers at the note playing at the launch phase' do
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n2.loop
      session.add(0.constant)
      run(48000 + 800) # into the E3 half of the bar
      session.add(clip.number, at: :now)
      expect(run(800)[0]).to eq(52)
    end

    it 'reuses the lowest free number' do
      expect(session.add(0.constant)).to eq(1)
      expect(session.add(0.constant)).to eq(2)
      session.remove(1)
      expect(session.add(0.constant)).to eq(1)
    end

    it 'replaces a named graph exactly at the new start time' do
      session.add(1.constant, name: :pad)
      run(4000)
      expect(session.add(2.constant, name: :pad)).to eq(:pad)
      data = run(96000)
      switch = 96000 - 4000
      expect(data[switch - 1]).to eq(1)
      expect(data[switch]).to eq(2)
      expect(session.players.keys).to eq([:pad])
    end
  end

  describe 'fading' do
    it 'fades in' do
      session.add(1.constant, fade: 1/20r)
      data = run(9600)
      expect(data[0]).to eq(0)
      expect(data[2400]).to be_within(0.01).of(0.5)
      expect(data[4800..].to_a.uniq).to eq([1])
    end

    it 'fades out and then removes the player' do
      session.add(1.constant, name: :drone)
      run(800)
      session.remove(:drone, fade: 1/20r)
      data = run(9600)
      expect(data[0]).to be_within(0.001).of(1)
      expect(data[2400]).to be_within(0.01).of(0.5)
      expect(data[4800..].to_a.uniq).to eq([0])
      expect(session).to be_idle
    end

    it 'crossfades when replacing with a fade' do
      session.add(1.constant, name: :pad)
      run(4000)
      session.add(3.constant, name: :pad, fade: 1/20r)
      data = run(96000 + 9600)
      switch = 96000 - 4000
      expect(data[switch - 1]).to eq(1)
      expect(data[switch + 2400]).to be_within(0.2).of(2)
      expect(data[switch + 6000]).to eq(3)
      expect(session.players.keys).to eq([:pad])
    end

    it 'shows fading players' do
      session.add(1.constant, name: :drone)
      run(800)
      session.remove(fade: 1/2r)
      expect(session.players[:drone]).to end_with('(fading out)')
    end

    it 'treats 0 and false as no fade and rejects invalid fades' do
      session.add(1.constant, fade: 0)
      expect(session.process_buffer[0][0]).to eq(1)
      session.remove(fade: false)
      expect(session).to be_idle
      expect { session.add(1.constant, fade: -1) }.to raise_error(ArgumentError, /Fade/)
    end

    it 'follows the tempo' do
      transport.bpm = 240
      session.add(1.constant, fade: 1/20r) # 0.05 seconds at 240 BPM
      data = run(4800)
      expect(data[1200]).to be_within(0.01).of(0.5)
      expect(data[2400..].to_a.uniq).to eq([1])
    end

    context 'with default fades' do
      let(:session) { MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true, fade_in: 1/20r, fade_out: 1/10r) }

      it 'fades new graphs in and removed graphs out' do
        session.add(1.constant, name: :a)
        data = run(9600)
        expect(data[0]).to eq(0)
        expect(data[2400]).to be_within(0.01).of(0.5)

        session.remove(:a)
        expect(session.players[:a]).to end_with('(fading out)')
        data = run(9600)
        expect(data[4800]).to be_within(0.01).of(0.5)
        expect(session).to be_idle
      end

      it 'switches replacements without a fade unless one is given' do
        session.add(1.constant, name: :pad)
        run(4000)
        session.add(2.constant, name: :pad)
        data = run(96000)
        expect(data[96000 - 4000 - 1]).to eq(1)
        expect(data[96000 - 4000]).to eq(2)
      end

      it 'can be changed or turned off' do
        session.fade_in = 0
        session.fade_out = nil
        session.add(1.constant)
        expect(session.process_buffer[0][0]).to eq(1)
        session.remove
        expect(session).to be_idle
      end
    end

    it 'uses a half bar fade in and a four bar fade out for the default session' do
      expect(MB::Sound::Session::DEFAULT_FADE_IN).to eq(1/2r)
      expect(MB::Sound::Session::DEFAULT_FADE_OUT).to eq(4)
    end
  end

  describe '#remove and #remove_last' do
    it 'removes named, numbered, last, and all players' do
      session.add(0.constant)
      session.add(0.constant, name: :b)
      session.add(0.constant)

      expect(session.remove_last).to eq(2)
      expect(session.remove(:b)).to eq([:b])
      expect(session.remove(:nope)).to eq([])
      expect(session.remove).to eq([1])
      expect(session.remove_last).to be_nil
    end
  end

  describe 'timeline' do
    it 'advances only while something is playing' do
      run(800)
      expect(transport.position).to eq(0)
      session.add(1.constant)
      run(9600)
      expect(transport.position).to eq(9600r / 96000)
      session.remove
      run(9600)
      expect(transport.position).to eq(9600r / 96000)
    end

    it 'moves playing clips when the timeline is seeked' do
      clip = MB::Sound.grid(4, 'x...').loop  # one hit per bar
      session.add(clip.trigger)
      run(48000)
      transport.seek(1 - 800r / 96000) # 800 frames before the next bar
      data = run(1600)
      expect(nonzero(data)).to eq([800])
    end
  end

  it 'removes graphs that end' do
    session.add(MB::Sound.grid(16, 'x').trigger)
    run(9600)
    expect(session).to be_idle
  end

  it 'removes a graph that raises an error and keeps playing the rest' do
    quiet = MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false)
    bad = 1.constant.proc { |_v| raise 'broken graph' }
    quiet.add(1.constant)
    quiet.add(bad, at: :now)
    expect(quiet).to receive(:warn).with(/Player 2 .*broken graph/m)
    expect(quiet.process_buffer[0][0]).to eq(1)
    expect(quiet.players.keys).to eq([1])
  end

  it 'mixes mono graphs to every channel and arrays to separate channels' do
    session.add([1.constant, 2.constant])
    session.add(4.constant, at: :now)
    mix = session.process_buffer
    expect([mix[0][0], mix[1][0]]).to eq([5, 6])
  end
end
