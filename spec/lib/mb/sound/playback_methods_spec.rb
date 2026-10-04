RSpec.describe(MB::Sound::PlaybackMethods) do
  before(:each) do
    ENV['OUTPUT_TYPE'] = 'null'
  end

  after(:each) do
    ENV.delete('OUTPUT_TYPE')
  end

  describe '#play' do
    it 'can play a sound file' do
      expect(Kernel).to receive(:sleep).at_least(10).times
      expect_any_instance_of(MB::Sound::NullOutput).to receive(:write).at_least(10).times.and_call_original
      expect($stderr).to receive(:puts).with(/Playing/)

      MB::Sound.play('sounds/synth0.flac', plot: false)
    end

    pending 'can play a Tone'
    pending 'can play a Numo::NArray'
    pending 'can play an array of graph nodes for separate channels'
    pending 'can play an array of other types of sounds for separate channels'

    it 'applies the master bus gain like the session does' do
      written = []
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      allow(out).to receive(:write) { |data| written << data.map(&:dup) }

      MB::Sound.play(1.constant.until(0.01), output: out, quiet: true)
      expect(written.flat_map { |d| d[0].to_a }.max).to be_within(1e-6).of(-10.db)

      written.clear
      MB::Sound.master_gain(1)
      MB::Sound.play(1.constant.until(0.01), output: out, quiet: true)
      expect(written.flat_map { |d| d[0].to_a }.max).to be_within(1e-6).of(1)
    end

    it 'tells how to stop node graphs, which may play forever' do
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      expect { MB::Sound.play(1.constant.until(0.01), output: out, plot: false, clear: false) }.to output(/Ctrl-C/).to_stderr
      expect { MB::Sound.play(Numo::SFloat.zeros(10), output: out, plot: false, clear: false) }.not_to output(/Ctrl-C/).to_stderr
    end

    it 'reuses the cached output by default' do
      outputs = []
      allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

      MB::Sound.play(440.hz.sine.until(0.05), quiet: true)
      MB::Sound.play(440.hz.sine.until(0.05), quiet: true)

      expect(outputs[0]).to equal(outputs[1])
      expect(outputs[0]).not_to be_closed
    end
  end

  describe 'background playback' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    describe '#latency' do
      around(:each) do |ex|
        saved = %w[AUDIO_BACKEND AUDIO_PROFILE].to_h { |k| [k, ENV.delete(k)] }
        ENV['AUDIO_BACKEND'] = 'null' # miniaudio's null sound card
        ex.run
      ensure
        saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
      end

      # After the file's before hook, which sets OUTPUT_TYPE=null
      before(:each) { ENV['OUTPUT_TYPE'] = 'device' }

      it 'plays background sounds through a sound card with a latency profile' do
        expect(MB::Sound.latency(:low)).to eq(:low)
        out = MB::Sound::Session.default.output
        expect(out).to be_a(MB::Sound::DeviceOutput)
        expect(out.profile).to eq(:low)
        expect(out.buffer_size).to eq(256)
        expect(MB::Sound.latency).to eq(:low)
      end

      it 'is also called lag' do
        expect(MB::Sound.lag(:safe)).to eq(:safe)
        expect(MB::Sound.lag).to eq(:safe)
      end

      it 'refuses to switch while players are running' do
        MB::Sound.latency(:default)
        MB::Sound.bg(220.hz.sine)
        expect { MB::Sound.latency(:low) }.to raise_error(ArgumentError, /Stop the background players/)
      end
    end

    describe '#use_output' do
      it 'plays background sounds through an output object' do
        out = MB::Sound::NullOutput.new(channels: 2)
        expect(MB::Sound.use_output(out)).to equal(out)
        expect(MB::Sound::Session.default.output).to equal(out)

        MB::Sound.bg(220.hz.sine)
        deadline = MB::U.clock_now + 2
        sleep 0.01 until out.frames_written > 0 || MB::U.clock_now > deadline
        expect(out.frames_written).to be > 0
      end

      it 'opens an output type given as a Symbol' do
        out = MB::Sound.use_output(:null)
        expect(out).to be_a(MB::Sound::NullOutput)
        expect(out.channels).to eq(2)
        expect(MB::Sound::Session.default.output).to equal(out)
      end

      it 'refuses to switch while players are running' do
        MB::Sound.bg(220.hz.sine)
        expect { MB::Sound.use_output(:null) }.to raise_error(ArgumentError, /Stop the background players/)
      end

      it 'goes back to the automatic output with nil, closing the old one' do
        out = MB::Sound::NullOutput.new(channels: 2)
        MB::Sound.use_output(out)
        expect(MB::Sound.use_output(nil)).to eq(nil)
        expect(out).to be_closed
        expect(MB::Sound::Session.default.output).not_to equal(out)
      end
    end

    describe '#bg' do
      it 'returns reused player numbers and lists players' do
        a = MB::Sound.bg(220.hz.sine)
        b = MB::Sound.bg(330.hz.sine)
        expect([a, b]).to eq([1, 2])
        expect(MB::Sound.players.keys).to eq([1, 2])

        MB::Sound.stop(1, fade: 0)
        expect(MB::Sound.bg(440.hz.sine)).to eq(1)
      end

      it 'accepts a name and replaces the player with the same name' do
        expect(MB::Sound.bg(:bass, 220.hz.sine)).to eq(:bass)
        expect(MB::Sound.bg(:bass, 110.hz.sine)).to eq(:bass)
        expect(MB::Sound.players.keys).to eq([:bass])
      end

      it 'returns right away' do
        t = MB::U.clock_now
        MB::Sound.bg(440.hz.sine)
        expect(MB::U.clock_now - t).to be < 0.5
      end

      it 'mixes all players into one output' do
        outputs = []
        allow(MB::Sound).to receive(:output).and_wrap_original { |m, **kw| m.call(**kw).tap { |o| outputs << o } }

        MB::Sound.bg(220.hz.sine)
        MB::Sound.bg(330.hz.sine)
        expect(outputs.length).to eq(1)
      end

      it 'rejects :all as a name' do
        expect { MB::Sound.bg(:all, 220.hz.sine) }.to raise_error(ArgumentError, /reserved/)
      end
    end

    describe '#stop' do
      it 'stops the most recently started player with no arguments' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine)
        expect(MB::Sound.stop(fade: 0)).to eq([:b])
        expect(MB::Sound.stop(fade: 0)).to eq([:a])
        expect(MB::Sound.stop).to eq([])
      end

      it 'stops named players' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine)
        expect(MB::Sound.stop(:a, fade: 0)).to eq([:a])
        expect(MB::Sound.players.keys).to eq([:b])
      end

      it 'stops everything with :all or #outro' do
        MB::Sound.bg(220.hz.sine)
        MB::Sound.bg(330.hz.sine)
        expect(MB::Sound.stop(:all, fade: 0)).to eq([1, 2])

        MB::Sound.bg(220.hz.sine)
        expect(MB::Sound.outro(fade: 0)).to eq([1])
        expect(MB::Sound.players).to be_empty
      end

      it 'fades everything out over four bars with #outro' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine, at: :now)
        sleep 0.05
        expect(MB::Sound.outro).to contain_exactly(:a, :b)
        expect(MB::Sound.players.values).to all(end_with('(fading out)'))
      end

      it 'has #fadeout as an alias for #outro' do
        MB::Sound.bg(:a, 220.hz.sine)
        sleep 0.05
        expect(MB::Sound.fadeout(fade: 0)).to eq([:a])
        expect(MB::Sound.players).to be_empty
      end

      it 'no longer has #hush' do
        expect(MB::Sound).not_to respond_to(:hush)
      end

      it 'fades out over four bars by default' do
        MB::Sound.bg(:a, 220.hz.sine)
        sleep 0.05
        MB::Sound.stop(:a)
        expect(MB::Sound.players[:a]).to end_with('(fading out)')
        expect(MB::Sound::Session.default.fade_out).to eq(4)
      end

      it 'can fade out over a given number of bars' do
        MB::Sound.bg(:a, 220.hz.sine)
        sleep 0.05
        expect(MB::Sound.stop(:a, fade: 1/10r)).to eq([:a])
        expect(MB::Sound.players[:a]).to end_with('(fading out)')
        deadline = MB::U.clock_now + 5
        sleep 0.05 until MB::Sound.players.empty? || MB::U.clock_now > deadline
        expect(MB::Sound.players).to be_empty
      end

      it 'stops everything right away with #panic, including fading and waiting players' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine)   # waits for the next bar
        sleep 0.05
        MB::Sound.stop(:a)                       # fading out over four bars
        expect(MB::Sound.players.keys).to contain_exactly(:a, :b)

        expect(MB::Sound.panic).to contain_exactly(:a, :b)
        expect(MB::Sound.players).to be_empty
        expect(MB::Sound::Session.default).to be_idle
      end

      it 'keeps master effects but clears their tails with #panic' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.master(at: :now) { |mix| mix.delay(seconds: 0.5) }
        sleep 0.05 until MB::Sound.master.start_with?('master:')

        MB::Sound.panic
        expect(MB::Sound.master).to start_with('master:')
        expect(MB::Sound::Session.default.instance_variable_get(:@master_chains).length).to be <= 2
      end

      it 'warns about unknown players' do
        expect(MB::Sound).to receive(:warn).with(/No background player 12345/)
        expect(MB::Sound.stop(12345)).to eq([])
      end
    end
  end

  describe '#master' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    it 'sets, shows, and removes master effects' do
      expect(MB::Sound.master).to eq('bypass')
      expect(MB::Sound.master { |mix| mix.softclip }).to start_with('master:')
      expect(MB::Sound.master).to start_with('master:')
      expect(MB::Sound::Session.default.master_active?).to eq(true)
      MB::Sound.master(nil)
      deadline = MB::U.clock_now + 2
      sleep 0.01 until MB::Sound.master == 'bypass' || MB::U.clock_now > deadline
      expect(MB::Sound.master).to eq('bypass')
    end

    it 'is also available as master_fx' do
      expect(MB::Sound.master_fx(false)).to eq('bypass')
    end

    it 'rejects a block and a value together, or other values' do
      expect { MB::Sound.master(nil) { |m| m } }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound.master(5) }.to raise_error(ArgumentError, /got 5/)
    end
  end

  describe '#wait' do
    let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_size: 800, realtime: true) }

    after do
      session.close
      MB::Sound.rewind
    end

    def within(&block)
      MB::Sound::Session.with_context(session: session, &block)
    end

    it 'returns right away if nothing is playing' do
      within { expect(MB::Sound.wait).to eq(true) }
    end

    it 'waits for sounds to end and the mix to be quiet for a second' do
      frames = 0
      session.add_tap { |mix| frames += mix[0].length }
      within do
        MB::Sound.bg(1.constant.until(0.1))
        expect(MB::Sound.wait).to eq(true)
      end
      expect(session).to be_idle
      expect(frames).to be >= 48000 * (0.1 + MB::Sound::Session::TAIL_QUIET_SECONDS)
    end

    it 'stops waiting for a tail that never ends after the tail limit' do
      stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 1) # instead of 10 s of rendering
      within do
        MB::Sound.bg(1.constant.until(0.05))
        MB::Sound.master(at: :now) { |mix| mix.delay(seconds: 0.1, feedback: 1, dry: 1, wet: 1) }
        expect(MB::Sound.wait(timeout: 30)).to eq(true)
      end
    end

    it 'gives up after a timeout' do
      paced = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2), buffer_size: 800, realtime: true)
      MB::Sound::Session.with_context(session: paced) do
        MB::Sound.bg(1.constant)
        t = MB::U.clock_now
        expect(MB::Sound.wait(timeout: 0.2)).to eq(false)
        expect(MB::U.clock_now - t).to be_between(0.2, 1)
      end
    ensure
      paced&.close
    end

    it 'refuses to wait inside a scheduled block' do
      MB::Sound::Session.with_context(session: session, batch: []) do
        expect { MB::Sound.wait }.to raise_error(/scheduled block/)
      end
    end
  end

  describe '#swap' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    let(:bass) { MB::Sound.seq(MB::Sound::C2).n4.loop }

    it 'swaps a clip in a background player' do
      MB::Sound.bg(:bass, bass.tone)
      expect(MB::Sound.swap(:bass, MB::Sound.seq(MB::Sound::D2).n4.loop)).to eq(:bass)
      expect(MB::Sound.swap(:bass, bass => MB::Sound.seq(MB::Sound::E2).n4.loop, at: :now)).to eq(:bass)
    end

    it 'rejects missing or doubled arguments' do
      expect { MB::Sound.swap(:bass) }.to raise_error(ArgumentError, /Pass a new clip/)
      expect { MB::Sound.swap(:bass, bass, bass => bass) }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound.swap(:nope, bass) }.to raise_error(ArgumentError, /No background player/)
    end
  end

  describe '#resume, #stopped, and #forget' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    it 'resumes a stopped named player' do
      MB::Sound.bg(:pad, 220.hz.sine)
      MB::Sound.stop(:pad, fade: 0)
      expect(MB::Sound.stopped.keys).to eq([:pad])
      expect(MB::Sound.resume(:pad)).to eq(:pad)
      expect(MB::Sound.players.keys).to eq([:pad])
      expect(MB::Sound.forget).to eq([])
    end

    it 'warns when there is nothing to resume' do
      expect(MB::Sound).to receive(:warn).with(/nothing has been stopped/)
      expect(MB::Sound.resume).to be_nil
      expect(MB::Sound).to receive(:warn).with(/:nope/)
      expect(MB::Sound.resume(:nope)).to be_nil
    end
  end

  describe '#visualize' do
    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.rewind
    end

    it 'plots the newest mix buffers until interrupted, then removes its tap' do
      MB::Sound.bg(220.hz.sine)
      plotted = []
      allow_any_instance_of(MB::Sound::PlotOutput).to receive(:plot) { |_, data|
        plotted << data
        raise Interrupt if plotted.length == 3
      }
      allow($stdout).to receive(:write)

      result = MB::Sound.visualize
      expect(result[:frames]).to eq(2)
      expect(result[:fps]).to be > 0
      expect(plotted.map(&:length).uniq).to eq([2])
      expect(plotted.uniq(&:object_id).length).to eq(3) # never the same buffer twice
      expect(MB::Sound::Session.default.instance_variable_get(:@taps)).to be_empty
    end

    it 'is also called vis' do
      expect(MB::Sound.method(:vis)).to eq(MB::Sound.method(:visualize))
    end

    it 'warns and returns if nothing has been played in the background' do
      expect(MB::Sound).to receive(:warn).with(/Nothing is playing/)
      expect(MB::Sound.visualize).to be_nil
    end
  end

  describe '#render' do
    let(:filename) { tmp_path('render_spec.flac') }

    # These check render's timing and mixing at unity gain; the master bus
    # gain (reset before each example by spec_helper) is checked below.
    before { MB::Sound.master_gain(1) }

    it 'renders to an output object instead of a file, closing it at the end' do
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      expect(MB::Sound.render(out, 1.constant, seconds: 0.1)).to eq(0.1)
      expect(out.frames_written).to eq(4800)
      expect(out).to be_closed
    end

    it 'applies the master bus gain: -10 dB by default, or gain:' do
      MB::Sound.master_gain(MB::Sound::Session::DEFAULT_MASTER_GAIN)
      MB::Sound.render(filename, 1.constant, seconds: 0.1)
      expect(MB::Sound.read(filename)[0].max).to be_within(1e-6).of(-10.db)

      MB::Sound.render(filename, 1.constant, seconds: 0.1, gain: -6.db, overwrite: true)
      expect(MB::Sound.read(filename)[0].max).to be_within(1e-6).of(-6.db)

      MB::Sound.master_gain(-3.db)
      MB::Sound.render(filename, 1.constant, seconds: 0.1, overwrite: true)
      expect(MB::Sound.read(filename)[0].max).to be_within(1e-6).of(-3.db)
    end

    it 'renders a sequence for a number of bars at the current tempo' do
      bass = MB::Sound.seq(MB::Sound::C2, MB::Sound::G1).n8.loop
      seconds = MB::Sound.render(filename, bass.tone.ramp.at(1) * bass.env * 0.5, bars: 2)
      expect(seconds).to eq(4)

      data = MB::Sound.read(filename)
      expect(data.length).to eq(2)
      expect(data[0].length).to eq(4 * 48000)
      expect(data[0].abs.max).to be_between(0.1, 1)
    end

    it 'arranges a song on the file timeline with a block' do
      seconds = MB::Sound.render(filename, bars: 2, bpm: 120) do
        MB::Sound.bg(:a, 0.25.constant)
        MB::Sound.at_bar(2) { MB::Sound.bg(:b, 0.5.constant); MB::Sound.stop(:a, fade: 0) }
      end
      expect(seconds).to eq(4)

      data = MB::Sound.read(filename)[0]
      expect(data[96000 - 10]).to be_within(0.01).of(0.25)
      expect(data[96000 + 10]).to be_within(0.01).of(0.5)
      expect(MB::Sound::Session.default.scheduled).to be_empty # the live session is untouched
    end

    it 'counts bars on the timeline, following tempo changes during the render' do
      seconds = MB::Sound.render(filename, bars: 4, bpm: 120) do
        MB::Sound.bg(1.constant)
        MB::Sound.at_bar(3) { MB::Sound.bpm(60) }
      end
      expect(seconds).to eq(2 * 2 + 2 * 4) # two bars at 120 BPM, two at 60
    end

    it 'adds the master tail after the bars limit with tail: true' do
      song = proc do
        MB::Sound.bg(0.5.constant)
        MB::Sound.master { |mix| mix.delay(seconds: 0.2) }
      end
      expect(MB::Sound.render(filename, bars: 1, bpm: 120, &song)).to eq(2)

      seconds = MB::Sound.render(filename, bars: 1, bpm: 120, tail: true, overwrite: true, &song)
      expect(seconds).to be_within(0.02).of(2 + 0.2 + 1) # the delay rings 0.2 s past the end, then a second of quiet
      data = MB::Sound.read(filename)[0]
      expect(data[(2.1 * 48000).round]).to be_within(0.01).of(0.5)
      expect(data[(2.3 * 48000).round].abs).to be < 0.001
    end

    it 'accepts a Duration for bars' do
      expect(MB::Sound.render(filename, 1.constant, bars: 2.beats, bpm: 120)).to eq(1)
    end

    it 'stops when every sound ends' do
      seconds = MB::Sound.render(filename, 440.hz.sine.until(0.5), bpm: 90)
      expect(seconds).to be_within(0.02).of(0.5)
    end

    it 'renders the tail of master effects after the last sound ends' do
      seconds = MB::Sound.render(filename, bpm: 120) do
        MB::Sound.bg(0.5.constant.until(0.1))
        MB::Sound.master { |mix| mix.delay(seconds: 0.2) }
      end

      # The delay ends at 0.3 seconds, followed by a second of silence
      expect(seconds).to be_within(0.02).of(1.3)
      data = MB::Sound.read(filename)[0]
      expect(data[(0.25 * 48000).round]).to be_within(0.01).of(0.5)
    end

    it 'limits master tails to ten seconds and the length given' do
      expect(MB::Sound::Session::MAX_TAIL_SECONDS).to eq(10)
      stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 1) # instead of 10 s of rendering

      infinite = proc do
        MB::Sound.bg(0.5.constant.until(0.1))
        MB::Sound.master { |mix| mix.delay(seconds: 0.1, feedback: 1, dry: 1, wet: 1) }
      end
      expect(MB::Sound.render(filename, &infinite)).to be_within(0.02).of(1.1)
      expect(MB::Sound.render(filename, seconds: 0.5, overwrite: true, &infinite)).to eq(0.5)
    end

    it 'swaps clips at scheduled times, keeping the graph' do
      bass = MB::Sound.seq(MB::Sound::C3).n4.loop
      bass2 = MB::Sound.seq(MB::Sound::G3).n4.loop
      MB::Sound.render(filename, bars: 2, bpm: 120) do
        MB::Sound.bg(:bass, bass.number / 100.0, fade: 0)
        MB::Sound.at_bar(2) { MB::Sound.swap :bass, bass => bass2 }
      end

      data = MB::Sound.read(filename)[0]
      expect(data[96000 - 1]).to be_within(0.001).of(0.48) # C3
      expect(data[96000]).to be_within(0.001).of(0.55) # G3
    end

    it 'does not overwrite files unless asked' do
      MB::Sound.render(filename, 440.hz.sine.until(0.1))
      expect { MB::Sound.render(filename, 440.hz.sine.until(0.1)) }.to raise_error(/exists/i)
      expect { MB::Sound.render(filename, 440.hz.sine.until(0.1), overwrite: true) }.not_to raise_error
    end

    it 'does not move the live timeline' do
      expect { MB::Sound.render(filename, 440.hz.sine.until(0.1)) }.not_to change { MB::Sound.transport.position }
    end
  end

  describe '#seek and #rewind' do
    after(:each) { MB::Sound.rewind }

    it 'moves the timeline to the start of a bar' do
      MB::Sound.seek(3)
      expect(MB::Sound.transport.position).to eq(2)
      expect(MB::Sound.transport.bar).to eq(3)
      MB::Sound.rewind
      expect(MB::Sound.transport.position).to eq(0)
    end

    it 'rejects bars before the first' do
      expect { MB::Sound.seek(0) }.to raise_error(ArgumentError)
    end
  end
end
