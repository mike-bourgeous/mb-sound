RSpec.describe(MB::Sound::ScheduleMethods) do
  # 120 BPM at 48kHz: one bar is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(output: output, transport: transport, buffer_size: 800, realtime: false) }

  # Runs the block with +session+ as the current session.
  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  # Renders +frames+ frames and returns channel 0.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  # Returns [sample index, value] for each change in +data+.
  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v] }
  end

  describe '#at_bar' do
    it 'runs the block ahead of time and applies its commands exactly on the bar' do
      ran_at = nil
      within do
        MB::Sound.bg(:a, 1.constant)
        MB::Sound.at_bar(2) do
          ran_at = transport.position
          MB::Sound.bg(:b, 2.constant)
          MB::Sound.stop(:a, fade: 0)
        end
      end

      data = run(96000 * 2)
      expect(ran_at).to be < 1
      expect(changes(data)).to eq([[0, 1], [96000, 2]])
      expect(session.stopped.keys).to eq([:a])
    end

    it 'accepts a beat within the bar' do
      within do
        MB::Sound.bg(:a, 0.constant)
        MB::Sound.at_bar(1, beat: 3) { MB::Sound.bg(:b, 1.constant) }
      end
      expect(changes(run(96000))).to eq([[0, 0], [48000, 1]])
    end

    it 'waits for something to be playing' do
      ran = false
      within { MB::Sound.at_bar(2) { ran = true } }
      run(96000 * 2)
      expect(ran).to eq(false)
      expect(transport.position).to eq(0)
    end

    it 'runs a block whose time has come even when nothing is playing' do
      within { MB::Sound.at_bar(1) { MB::Sound.bg(:a, 1.constant) } }
      expect(run(800)[0]).to eq(1)
    end

    it 'warns and returns nil for a bar that has passed' do
      within { MB::Sound.bg(0.constant) }
      run(96000 * 2)
      expect(MB::Sound).to receive(:warn).with(/already at bar 3/)
      expect(within { MB::Sound.at_bar(2) { } }).to be_nil
    end

    it 'is also called on_bar' do
      expect(MB::Sound.method(:on_bar)).to eq(MB::Sound.method(:at_bar))
    end
  end

  describe '#after' do
    it 'counts bars from the next bar line' do
      times = []
      within do
        MB::Sound.bg(0.constant)
        MB::Sound.after(1) { times << MB::Sound::Session.context[:time] }
        MB::Sound.after(2) { times << MB::Sound::Session.context[:time] }
      end
      run(4000)
      within { MB::Sound.after(1) { times << MB::Sound::Session.context[:time] } }
      run(96000 * 2)
      expect(times).to eq([0, 1, 1])
    end
  end

  describe '#every' do
    it 'repeats on bar offset + 1 of each group' do
      times = []
      within do
        MB::Sound.bg(0.constant)
        MB::Sound.every(4, offset: 3) { times << MB::Sound::Session.context[:time] }
      end
      run(96000 * 9)
      expect(times).to eq([3, 7])
      expect(session.scheduled.values).to eq(['every 4 bars from bar 4'])
    end

    it 'moves to the next matching bar when the timeline is seeked' do
      times = []
      within do
        MB::Sound.bg(0.constant)
        MB::Sound.every(2) { times << MB::Sound::Session.context[:time] }
      end
      run(96000 * 3)
      transport.seek(10.5)
      run(96000 * 2)
      expect(times).to eq([0, 2, 12])
    end
  end

  describe '#scheduled and #cancel' do
    it 'lists and cancels scheduled blocks' do
      within do
        a = MB::Sound.at_bar(5) { }
        b = MB::Sound.every(2) { }
        expect(MB::Sound.scheduled).to eq(a => 'bar 5', b => 'every 2 bars from bar 1')
        expect(MB::Sound.cancel(a)).to eq([a])
        expect(MB::Sound.cancel).to eq([b])
        expect(MB::Sound.scheduled).to be_empty
      end
    end
  end

  it 'changes the tempo at the scheduled time' do
    within do
      MB::Sound.bg(0.constant)
      MB::Sound.at_bar(2) { MB::Sound.bpm(240) }
    end
    run(96000 - 800)
    expect(transport.bpm).to eq(120)
    run(1600)
    expect(transport.bpm).to eq(240)
  end

  it 'skips the commands of a block that finishes after its time' do
    within do
      MB::Sound.bg(:a, 1.constant)
      MB::Sound.at_bar(2) do
        MB::Sound.bg(:b, 2.constant)
        transport.advance(1) # simulate the block taking longer than a bar
      end
    end
    expect_any_instance_of(MB::Sound::Session::Scheduler).to receive(:warn).with(/Skipped the commands scheduled for bar 2/)
    run(96000)
    expect(session.players.keys).to eq([:a])
  end

  it 'prints errors from scheduled blocks and keeps playing' do
    within do
      MB::Sound.bg(:a, 1.constant)
      MB::Sound.at_bar(1, beat: 2) { raise 'oops' }
    end
    expect_any_instance_of(MB::Sound::Session::Scheduler).to receive(:warn).with(/beat 2 raised RuntimeError: oops/)
    expect(run(96000).to_a.uniq).to eq([1])
  end

  it 'shows when scheduled stops will happen' do
    within do
      MB::Sound.bg(:a, 1.constant)
      MB::Sound.at_bar(3) { MB::Sound.stop(:a, fade: 0) }
    end
    run(168000) # past the block's early run, before bar 3
    expect(session.players[:a]).to end_with('(stops at bar 3)')
    run(96000)
    expect(session.players).to be_empty
  end

  describe 'with the default realtime session' do
    before { ENV['OUTPUT_TYPE'] = 'null' }
    after do
      MB::Sound::Session.default.close
      MB::Sound.bpm(120)
      MB::Sound.rewind
      ENV.delete('OUTPUT_TYPE')
    end

    it 'runs scheduled blocks on the scheduler thread' do
      MB::Sound.bpm(960) # one bar is 0.25 seconds
      MB::Sound.bg(:a, 1.constant)
      thread = nil
      MB::Sound.at_bar(2) { thread = Thread.current; MB::Sound.bg(:b, 2.constant) }

      deadline = MB::U.clock_now + 5
      sleep 0.02 until MB::Sound.players.include?(:b) || MB::U.clock_now > deadline
      expect(MB::Sound.players.keys).to include(:b)
      expect(thread.name).to eq('MB::Sound::Session scheduler')
    end
  end
end
