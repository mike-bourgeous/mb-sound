RSpec.describe(MB::Sound::ScheduleMethods) do
  # 120 BPM at 48kHz: one bar is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false) }

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

    # At 112 BPM a bar is 102857 1/7 samples, so bar lines fall between
    # samples.  Notes put an edge on the sample whose window holds it
    # (floor), so a graph launched on a bar must start on that sample too,
    # or a clip's first note lands before its first sample and is lost.
    context 'when the bar line falls between samples' do
      let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 112) }
      let(:bar2) { (transport.bar_length / transport.whole_notes_per_second * 48000).floor }

      before { expect(bar2).to eq(102857) }

      # Launches +node+ on bar 2 and returns the changes in its output.
      def launch(node = nil, &block)
        within do
          MB::Sound.bg(:a, 0.constant)
          MB::Sound.at_bar(2) { MB::Sound.bg(:b, node || block.call) }
        end
        changes(run(800 * 300))
      end

      it 'plays the first note of a looping clip' do
        clip = MB::Sound.seq(MB::Sound::A2).n1.legato(1/8r).loop
        expect(launch(clip.gate).first(2)).to eq([[0, 0], [bar2, 1]])
      end

      it 'plays the first note of a looping clip made inside the block' do
        result = launch { MB::Sound.seq(MB::Sound::A2, MB::Sound::C3).n4.loop.number }
        expect(result.first(3)).to eq([[0, 0], [bar2, MB::Sound::A2.number], [bar2 + 25714, MB::Sound::C3.number]])
      end

      it 'plays the first note of a looping clip.synth' do
        clip = MB::Sound.seq(MB::Sound::A2).n1.legato(1/8r).loop
        synth = clip.synth(voices: 2) { |v| v.gate }
        expect(launch(synth).first(2)).to eq([[0, 0], [bar2, 1]])
      end

      it 'plays the first hit of a looping grid kit row' do
        kit = MB::Sound.grid(16, kick: 'x...x...x...x...')
        expect(launch(kit[:kick].loop.trigger)[1]).to eq([bar2, 0.75])
      end

      it 'starts a non-looping clip on the bar line sample' do
        expect(launch(MB::Sound.seq(MB::Sound::A2).n4.gate)).to eq([[0, 0], [bar2, 1], [bar2 + 25714, 0]])
      end

      it 'starts a constant on the bar line sample' do
        expect(launch(1.constant)).to eq([[0, 0], [bar2, 1]])
      end

      it 'hands over from a replaced player on the bar line sample' do
        within do
          MB::Sound.bg(:a, 1.constant)
          MB::Sound.at_bar(2) { MB::Sound.bg(:a, 2.constant, fade: 0) }
        end
        expect(changes(run(800 * 300))).to eq([[0, 1], [bar2, 2]])
      end

      it 'lands a launch on the same sample as a swap' do
        c1 = MB::Sound.seq(MB::Sound::A2).n1.legato(1/8r).loop
        c2 = MB::Sound.seq(MB::Sound::C4).n1.legato(1/8r).loop
        within do
          MB::Sound.bg(:a, c1.number)
          MB::Sound.at_bar(2) { MB::Sound.swap(:a, c2) }
        end
        expect(changes(run(800 * 300))).to eq([[0, MB::Sound::A2.number], [bar2, MB::Sound::C4.number]])
      end
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

    it 'accepts Durations' do
      times = []
      within do
        MB::Sound.bg(0.constant)
        MB::Sound.after(2.bars) { times << MB::Sound::Session.context[:time] }
      end
      run(96000 * 2)
      expect(times).to eq([1])
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

    it 'accepts Durations' do
      times = []
      within do
        MB::Sound.bg(0.constant)
        MB::Sound.every(2.beats, offset: 1.beat) { times << MB::Sound::Session.context[:time] }
      end
      run(96000)
      expect(times.first(3)).to eq([1/4r, 3/4r, 5/4r]) # blocks run up to half a bar ahead
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

  it 'changes the tuning at the scheduled time' do
    within do
      MB::Sound.bg(MB::Sound::A4.freq)
      MB::Sound.at_bar(2) { MB::Sound.tuning a4: 432 }
    end
    data = run(96000 + 1600)
    expect(changes(data)).to eq([[0, 440], [96000, 432]])
    expect(session.tuning.frequency_of(69)).to eq(432)
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
