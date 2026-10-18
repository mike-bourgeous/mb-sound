RSpec.describe(MB::Sound::PlaybackMethods) do
  before(:each) do
    ENV['OUTPUT_TYPE'] = 'null'
  end

  after(:each) do
    ENV.delete('OUTPUT_TYPE')
  end

  describe '#play' do
    # A NullOutput on a virtual clock (play's waiting consumes what the
    # render thread writes) that keeps what it writes, except silent buffers
    let(:out) {
      Class.new(MB::Sound::NullOutput) {
        def written = @written ||= []
        def write(data)
          written << data.map(&:dup) if data.any? { |c| c.abs.max > 0 }
          super
        end
        def channel(c) = Numo::SFloat.zeros(0).concatenate(*written.map { |d| d[c] })
      }.new(channels: 2, sleep: :virtual)
    }

    before(:each) { MB::Sound.use_output(out) }

    after(:each) do
      MB::Sound::Session.default.close
      MB::Sound.use_output(nil)
      MB::Sound.rewind
    end

    # Plays +sound+ quietly without plotting; returns the seconds it took.
    def play_quietly(sound, **options)
      t = MB::U.clock_now
      expect(MB::Sound.play(sound, plot: false, quiet: true, **options)).to eq(nil)
      expect(MB::Sound.players).not_to have_key(:play)
      MB::U.clock_now - t
    end

    let(:arp) { MB::Sound::Sample['spec/test_data/arp_a7.flac'] }

    {
      'a graph that ends' => -> { 440.hz.sine.until(0.05) },
      'a channel bundle' => -> { MB::Sound.stereo(220.hz.sine, 330.hz.sine).until(0.05) },
      'a Numo::NArray' => -> { Numo::SFloat.zeros(2400) },
      'an Array of numbers' => -> { [0.25] * 2400 },
      'an Array of channels' => -> { [Numo::SFloat.ones(100) * 0.5, Numo::SFloat.zeros(100)] },
      'a sound file' => -> { 'spec/test_data/arp_a7.flac' },
      'a MIDI file' => -> { 'spec/test_data/c_major.mid' },
      'a Sample' => -> { arp },
      'Slices' => -> { arp.slices(4) },
      'an Instrument' => -> { arp.to_instrument },
      'a keymap of slices' => -> { arp.slices(4).keymap },
      'a Clip' => -> { MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n16 },
      'a chop clip' => -> { arp.slices(4).chop(0, 1, 2, 3) },
      'a grid' => -> { MB::Sound.grid(16, kick: 'x...', hat: '..x.') },
      'a kit design' => -> { MB::Sound.kit { voice(:zap) { |h| h.fm(800, index: 3, decay: 0.05) } } },
      'a Wavetable' => -> { MB::Sound::Wavetable[Numo::SFloat.linspace(-1, 1, 64)] },
      'an Envelope' => -> { MB::Sound.adsr(0.001, 0.01, 0.5, 0.01, hold: 0.02) },
    }.each do |what, sound|
      it "plays #{what} until it ends" do
        play_quietly(instance_exec(&sound))
        expect(out.channel(0).abs.max).to be > 0.001 unless what.include?('NArray')
      end
    end

    it 'keeps a stereo Sample in stereo' do
      play_quietly(arp)
      l, r = out.channel(0), out.channel(1)
      expect((l - r).abs.max).to be > 0.01
    end

    it 'plays a sample once, then returns' do
      expect(play_quietly(arp)).to be < 10
      expect(out.channel(0).length).to be >= arp.length
    end

    it 'applies the master bus gain like the session does' do
      play_quietly(1.constant.until(0.01))
      expect(out.channel(0).max).to be_within(1e-6).of(-10.db)

      out.written.clear
      MB::Sound.master_gain(1)
      play_quietly(1.constant.until(0.01))
      # (full scale meets the live output's safety limiter: no master chain)
      expect(out.channel(0).max).to be_within(1e-6).of(MB::Sound::Session::SafetyLimiter::SAFETY_CEILING.to_f)
    end

    it 'scales by gain:' do
      MB::Sound.master_gain(1)
      play_quietly(1.constant.until(0.01), gain: 0.5)
      expect(out.channel(0).max).to be_within(1e-6).of(0.5)
    end

    it 'plays through the master chain' do
      MB::Sound.master_gain(1)
      MB::Sound.master(on: :now) { |mix| mix * 0.25 }
      play_quietly(1.constant.until(0.01))
      expect(out.channel(0).max).to be_within(1e-6).of(0.25)
    end

    it 'tells how to stop graphs that may play forever, and how a clip was played' do
      expect { MB::Sound.play(1.constant.until(0.01), plot: false) }.to output(/Playing.*Ctrl-C/m).to_stderr
      expect { MB::Sound.play(Numo::SFloat.zeros(10), plot: false) }.not_to output(/Ctrl-C/).to_stderr
      expect { MB::Sound.play(MB::Sound.seq(MB::Sound::C4).n32, plot: false) }.to output(/soft saw/).to_stderr
    end

    it 'stops on Ctrl-C' do
      thread = Thread.new { MB::Sound.play(440.hz.sine, plot: false, quiet: true) }
      deadline = MB::U.clock_now + 5
      sleep 0.01 until MB::Sound.players.key?(:play) || MB::U.clock_now > deadline
      expect(MB::Sound.players).to have_key(:play)
      thread.raise(Interrupt)
      expect(thread.value).to eq(nil)
      deadline = MB::U.clock_now + 5
      MB::Sound::Internal.wait_audio(MB::Sound::Session.current, 0.01) while MB::Sound.players.key?(:play) && MB::U.clock_now < deadline # (the stop's fade)
      expect(MB::Sound.players).not_to have_key(:play)
      expect(MB::Sound.stopped).to have_key(:play) # resume :play brings it back
    end

    it 'plots the mix while it plays, then stops plotting' do
      allow(MB::Sound).to receive(:visualize).and_wrap_original { |m, stop:, **kw|
        expect(kw[:header]).to match(/Playing/)
        MB::Sound::Internal.wait_audio(MB::Sound::Session.current, 0.01) until stop.call # (the real one plots by wall clock)
        { frames: 0, fps: 0 }
      }
      expect { MB::Sound.play(440.hz.sine.until(0.05), quiet: false, plot: true) }.to output(/Playing/).to_stderr
      expect(MB::Sound).to have_received(:visualize)
    end

    it 'plots into the terminal UI\'s scope pane while one is up, writing nothing over its screen (ux-1 bug 3)' do
      restored = 0
      screen = double('screen')
      allow(screen).to receive(:plot_pane) { |kind| expect(kind).to eq(:spectrum); -> { restored += 1 } }
      allow(MB::Sound::UI).to receive(:screen).and_return(screen)
      expect {
        expect { MB::Sound.play(440.hz.sine.until(0.05), quiet: false, plot: true, spectrum: true) }.to output(/Playing/).to_stderr
      }.not_to output.to_stdout
      expect(screen).to have_received(:plot_pane).once
      expect(restored).to eq(1) # the slot it put in comes out again
    end

    it 'gives a friendly error for things it cannot play' do
      expect { MB::Sound.play(Object.new) }.to raise_error(MB::Sound::Playable::Unplayable, /Can't play Object.*help :play/)
      expect { MB::Sound.play(nil) }.to raise_error(ArgumentError, /Nothing to play/)
      expect { MB::Sound.play('no/such/file.flac') }.to raise_error(ArgumentError, /No file/)
      expect { MB::Sound.play(:no_such_preset_here) }.to raise_error(ArgumentError, /No preset or genre/)
      expect { MB::Sound.play(MB::Sound.genre(:dnb).form) }.to raise_error(ArgumentError, /play_form/)
    end

    it 'names the ways an unplayable thing offers' do
      thing = Class.new { def synth = nil }.new
      expect { MB::Sound.play(thing) }.to raise_error(ArgumentError, /x\.synth \{/)
    end

    it 'warns instead of raising in live mode' do
      MB::Sound.live = true
      expect { expect(MB::Sound.play(Object.new)).to eq(nil) }.to output(/Can't play Object.*live mode: ignored/).to_stderr
    ensure
      MB::Sound.live = false
    end

    it 'plays anything with #to_playable' do
      thing = Class.new { def to_playable = MB::Sound.seq(MB::Sound::A4).n32 }.new
      play_quietly(thing)
      expect(out.channel(0).abs.max).to be > 0.001
    end

    it 'starts like bg (without waiting) inside a render block' do
      seconds = MB::Sound.render(MB::Sound::NullOutput.new(channels: 2, sleep: false)) {
        expect(MB::Sound.play(440.hz.sine.until(0.25), plot: false, quiet: true)).to be_a(MB::Sound::Session::Journal::Entry)
      }
      expect(seconds).to be_within(0.02).of(0.25)
    end

    it 'plays a synth preset by name with a demo phrase' do
      skip 'no dnb_pluck preset' unless MB::Sound::GraphIO.find_preset(:dnb_pluck)
      expect { MB::Sound.play(:dnb_pluck, plot: false) }.to output(/demo phrase/).to_stderr
      expect(out.channel(0).abs.max).to be > 0.001
    end

    it 'plays a genre template briefly, then returns' do
      bpm, bar_length = MB::Sound.transport.bpm, MB::Sound.transport.bar_length
      template = MB::Sound.genre(:dnb)
      allow(MB::Sound).to receive(:play_form) { MB::Sound.bg(:try_genre, 220.hz.sine.until(0.05)) } # (setup runs as usual)
      expect(template.seconds.to_f).to be > 90 # so play shortens it
      expect { MB::Sound.play(template, plot: false) }.to output(/genre :dnb.*s of \d+/).to_stderr
      expect(MB::Sound.players).to be_empty
    ensure
      # Template#setup sets the shared transport's tempo and meter
      MB::Sound.transport.bpm = bpm
      MB::Sound.transport.bar_length = bar_length
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
        expect([a, b].map(&:name)).to eq([1, 2])
        expect(MB::Sound.players.keys).to eq([1, 2])

        MB::Sound.stop(a, fade: 0) # an entry stands for its player
        expect(MB::Sound.bg(440.hz.sine).name).to eq(1)
      end

      it 'accepts a name and replaces the player with the same name' do
        expect(MB::Sound.bg(:bass, 220.hz.sine).name).to eq(:bass)
        expect(MB::Sound.bg(:bass, 110.hz.sine).name).to eq(:bass)
        expect(MB::Sound.players.keys).to eq([:bass])
      end

      it 'returns the journal entry, which says where the change lands' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound::Session.default.transport.seek(1/8r) # mid-bar, so the next graph waits for bar 2
        entry = MB::Sound.bg(:b, 330.hz.sine)
        expect(entry).to be_a(MB::Sound::Session::Journal::Entry)
        expect(entry).to have_attributes(kind: :bg, subject: :b, status: :queued)
        expect(entry.to_s).to eq('bg :b lands 2:1 (queued)')
        expect(MB::Sound.players[:b]).to match(/starts at bar 2/)
      end

      it 'says once how to end a ringing sum with an input that never ends' do
        MB::Sound::GraphNode::RingHint.enabled = true
        hit = 330.hz.triangle * MB::Sound.adsr(0.001, 0.05, 0, 0.01)
        expect {
          MB::Sound.bg(:a, 110.hz.sine + hit)
        }.to output(/rings until all of its inputs end, and one never ends.*Ctrl-C.*\.ring\(:first\)/).to_stderr
        expect { MB::Sound.bg(:b, 110.hz.sine + hit) }.not_to output.to_stderr # once
        expect(MB::Sound::GraphNode::RingHint.enabled).to eq(false)
      end

      it 'gives no ringing-sum hint for sums that end, never end anyway, or end with their first input' do
        MB::Sound::GraphNode::RingHint.enabled = true
        hit = -> { 330.hz.triangle * MB::Sound.adsr(0.001, 0.05, 0, 0.01) }
        expect {
          MB::Sound.bg(:a, (110.hz.sine + hit.()).ring(:first))
          MB::Sound.bg(:b, 110.hz.sine + 220.hz.sine)
          MB::Sound.bg(:c, (110.hz.sine + hit.()) * MB::Sound.adsr(0.01, 0.1, 0, 0.1))
          MB::Sound.bg(:d, hit.() + 0.1)
        }.not_to output.to_stderr
        expect(MB::Sound::GraphNode::RingHint.enabled).to eq(true)
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
        expect(MB::Sound.stop(fade: 0)).to have_attributes(kind: :stop, name: :b)
        expect(MB::Sound.stop(fade: 0).name).to eq(:a)
        expect(MB::Sound.stop).to eq([])
      end

      it 'stops named players' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine)
        expect(MB::Sound.stop(:a, fade: 0).to_s).to match(/\Astop :a landed \d+:/)
        expect(MB::Sound.players.keys).to eq([:b])
      end

      it 'stops everything with :all or #outro' do
        MB::Sound.bg(220.hz.sine)
        MB::Sound.bg(330.hz.sine)
        expect(MB::Sound.stop(:all, fade: 0).map(&:name)).to eq([1, 2])

        MB::Sound.bg(220.hz.sine)
        expect(MB::Sound.outro(fade: 0).name).to eq(1)
        expect(MB::Sound.players).to be_empty
      end

      it 'fades everything out over four bars with #outro' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.bg(:b, 330.hz.sine, at: :now)
        sleep 0.05
        expect(MB::Sound.outro.map(&:name)).to contain_exactly(:a, :b)
        expect(MB::Sound.players.values).to all(end_with('(fading out)'))
      end

      it 'has #fadeout as an alias for #outro' do
        MB::Sound.bg(:a, 220.hz.sine)
        sleep 0.05
        expect(MB::Sound.fadeout(fade: 0).name).to eq(:a)
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
        expect(MB::Sound.stop(:a, fade: 1/10r).name).to eq(:a)
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

        entries = nil
        expect { entries = MB::Sound.panic }.to output("panic: stopped 2 players\n").to_stderr
        expect(entries.map { |e| [e.kind, e.name] }).to contain_exactly([:stop, :a], [:stop, :b])
        expect(MB::Sound.players).to be_empty
        expect(MB::Sound::Session.default).to be_idle
      end

      it 'keeps master effects but clears their tails with #panic' do
        MB::Sound.bg(:a, 220.hz.sine)
        MB::Sound.master(at: :now) { |mix| mix.delay(0.5) }
        sleep 0.05 until MB::Sound.master.start_with?('master:')

        expect { MB::Sound.panic }.to output(/\Apanic: stopped 1 player/).to_stderr
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
      # (the default Session is realtime: its live output has the safety limiter)
      expect(MB::Sound.master).to eq('bypass (live output: a safety limiter at -1 dBFS until a master chain is set)')
      expect(MB::Sound.master { |mix| mix.softclip }.data[:description]).to start_with('master:')
      expect(MB::Sound.master).to start_with('master:')
      expect(MB::Sound::Session.default.master_active?).to eq(true)
      MB::Sound.master(nil)
      deadline = MB::U.clock_now + 2
      sleep 0.01 until MB::Sound.master.start_with?('bypass') || MB::U.clock_now > deadline
      expect(MB::Sound.master).to start_with('bypass (live output: a safety limiter')
    end

    it 'is also available as master_fx' do
      expect(MB::Sound.master_fx(false).data[:description]).to eq('bypass')
    end

    it 'rejects a block and a value together, or other values' do
      expect { MB::Sound.master(nil) { |m| m } }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound.master(5) }.to raise_error(ArgumentError, /got 5/)
    end
  end

  describe '#wait' do
    let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: :virtual), buffer_size: 800, realtime: true) }

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
      expect(frames).to be >= (48000 * (0.1 + MB::Sound::Session::TAIL_QUIET_SECONDS)).round # (exact on the virtual clock)
    end

    it 'stops waiting for a tail that never ends after the tail limit' do
      stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 1) # instead of 10 s of rendering
      within do
        MB::Sound.bg(1.constant.until(0.05))
        MB::Sound.master(at: :now) { |mix| mix.delay(0.1, feedback: 1, dry: 1, wet: 1) }
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
      expect(MB::Sound.swap(:bass, MB::Sound.seq(MB::Sound::D2).n4.loop).name).to eq(:bass)
      expect(MB::Sound.swap(:bass, bass => MB::Sound.seq(MB::Sound::E2).n4.loop, at: :now).name).to eq(:bass)
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
      expect(MB::Sound.resume(:pad).name).to eq(:pad)
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

    it 'returns when its stop callable returns true, then removes its tap' do
      MB::Sound.bg(220.hz.sine)
      plotted = 0
      allow_any_instance_of(MB::Sound::PlotOutput).to receive(:plot) { plotted += 1 }
      allow($stdout).to receive(:write)

      result = MB::Sound.visualize(stop: -> { plotted >= 3 })
      expect(result[:frames]).to be >= 3
      expect(MB::Sound::Session.default.instance_variable_get(:@taps)).to be_empty
    end

    it "shows each buffer after the output's latency, when it is heard" do
      out = MB::Sound::NullOutput.new(channels: 2)
      out.define_singleton_method(:latency) { 0.2 }
      MB::Sound.use_output(out)
      MB::Sound.bg(220.hz.sine)

      start = MB::U.clock_now
      first = nil
      allow_any_instance_of(MB::Sound::PlotOutput).to receive(:plot) { |_, _data|
        first ||= MB::U.clock_now
        raise Interrupt
      }
      allow($stdout).to receive(:write)

      MB::Sound.visualize
      expect(first - start).to be >= 0.18
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

    describe 'time limits' do
      # Instead of 10 minutes of rendering
      before { stub_const('MB::Sound::PlaybackMethods::MAX_RENDER_SECONDS', 0.5) }

      let(:out) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }

      it 'stops endless sounds without bars: or seconds: at MAX_RENDER_SECONDS with a warning' do
        expect {
          expect(MB::Sound.render(out, 0.1.constant)).to eq(0.5)
        }.to output(/after 0.5 seconds; pass bars: or seconds:/).to_stderr
        expect(out.frames_written).to eq(24000)
      end

      it 'names .ring(:first) when a ringing sum with an input that never ends reaches MAX_RENDER_SECONDS' do
        hit = 330.hz.triangle * MB::Sound.adsr(0.001, 0.05, 0, 0.01)
        expect {
          expect(MB::Sound.render(out, 110.hz.sine.at(0.1) + hit)).to eq(0.5)
        }.to output(/after 0.5 seconds; pass bars: or seconds:.*\n.*never ends.*\.ring\(:first\)/).to_stderr
        expect {
          MB::Sound.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), (110.hz.sine.at(0.1) + hit).ring(:first))
        }.not_to output.to_stderr
      end

      it 'always reaches the end bar and its tail with bars:, past MAX_RENDER_SECONDS' do
        stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 0.25)
        song = proc do
          MB::Sound.bg(:pad, 0.1.constant)
          MB::Sound.master { |mix| mix.delay(0.1, feedback: 1, dry: 1, wet: 1) }
          # Two passes over bar 1 before bar 2: 3 bars of time for bars: 2
          MB::Sound.at_bar(2) { MB::Sound.seek 1 }
        end

        expect {
          expect(MB::Sound.render(out, bars: 2, bpm: 240, &song)).to eq(3)
        }.not_to output.to_stderr
        expect(out.frames_written).to eq(3 * 48000)

        out2 = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        expect {
          expect(MB::Sound.render(out2, bars: 2, bpm: 240, tail: true, &song)).to eq(3.25)
        }.not_to output.to_stderr
        expect(out2.frames_written).to eq(3.25 * 48000)
      end

      it 'stops a bars: render that never reaches its end bar at max_seconds:, tail included, without a warning' do
        song = proc do
          MB::Sound.bg(:pad, 0.1.constant)
          MB::Sound.master { |mix| mix.delay(0.1, feedback: 1, dry: 1, wet: 1) }
          # A seek back to bar 1 every half bar: bar 3 never comes
          MB::Sound.every(1/2r) { MB::Sound.seek 1 }
        end

        expect {
          expect(MB::Sound.render(out, bars: 2, bpm: 120, max_seconds: 0.75, tail: true, &song)).to eq(0.75)
        }.not_to output.to_stderr
        expect(out.frames_written).to eq(36000)
      end

      it 'caps seconds: and endless renders at max_seconds:' do
        expect(MB::Sound.render(out, 0.1.constant, seconds: 1, max_seconds: 0.25)).to eq(0.25)
        out2 = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        expect {
          expect(MB::Sound.render(out2, 0.1.constant, max_seconds: 0.75)).to eq(0.75)
        }.not_to output.to_stderr
        expect { MB::Sound.render(out2, 0.1.constant, max_seconds: 0) }.to raise_error(ArgumentError, /max_seconds/)
      end
    end

    describe 'with loudness:' do
      it 'normalizes the file to a number of LUFS or a named target' do
        expect(MB::Sound.render(filename, 1000.hz.sine.at(-30.db), seconds: 2, loudness: -16)).to eq(2)
        expect(MB::Sound.loudness(filename).integrated).to be_within(0.05).of(-16)

        MB::Sound.render(filename, 1000.hz.sine.at(-30.db), seconds: 2, loudness: :ebu_r128, overwrite: true)
        expect(MB::Sound.loudness(filename).integrated).to be_within(0.05).of(-23)
      end

      it 'warns when the true peak would pass the ceiling, or reduces the gain with peak: :reduce' do
        expect {
          MB::Sound.render(filename, 1000.hz.sine.at(-30.db), seconds: 1, loudness: -0.5)
        }.to output(/-1.0 dBTP; no limiter/).to_stderr

        expect {
          MB::Sound.render(filename, 1000.hz.sine.at(-30.db), seconds: 1, loudness: -0.5, peak: :reduce, overwrite: true)
        }.to output(/gain reduced/).to_stderr
        expect(MB::Sound.loudness(filename).true_peak).to be_within(0.05).of(-1)
      end

      it 'needs a filename' do
        out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        expect { MB::Sound.render(out, 1.constant, seconds: 0.1, loudness: -14) }.to raise_error(ArgumentError, /filename/)
        expect { MB::Sound.render(filename, 1.constant, seconds: 0.1, loudness: :nope) }.to raise_error(ArgumentError, /Unknown loudness target/)
      end
    end

    it 'warns when the mix went over full scale (clipped in the file, even with loudness:), with the gain: for headroom' do
      expect {
        MB::Sound.render(filename, 1000.hz.sine.at(2), seconds: 0.1, loudness: -18)
      }.to output(/went 6\.0 dB over full scale .*render with gain: -7\.db for headroom/).to_stderr
      expect(MB::Sound.loudness(filename).true_peak).to be < -10 # (normalized after clipping)

      expect { MB::Sound.render(filename, 1000.hz.sine, seconds: 0.1, overwrite: true) }.not_to output.to_stderr
      expect {
        MB::Sound.render(filename, 1000.hz.sine.at(2), seconds: 0.1, gain: -7.db, overwrite: true)
      }.not_to output.to_stderr

      out = MB::Sound::NullOutput.new(channels: 2, sleep: false) # (output objects aren't files)
      expect { MB::Sound.render(out, 1000.hz.sine.at(2), seconds: 0.1) }.not_to output.to_stderr
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

    # bin/songs/antialias_song.rb -b 2 raised in Envelope: at 112 BPM the
    # render ends 5/7 of a sample after bar 3, and graphs launched on bar 3
    # were given zero frames (Tones would even have ended on the nil that
    # sample(0) returns)
    it 'gives graphs launched in the last sample of a bar-limited render that sample' do
      out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      kicks = MB::Sound.seq(MB::Sound::C2).n4.loop
      counts = []
      spy = MB::Sound::GraphNode::ProcNode.new(1.constant) { |buf| counts << buf.length; buf }
      seconds = MB::Sound.render(out, bars: 2, bpm: 112) do
        MB::Sound.bg(:pad, 0.constant)
        MB::Sound.at_bar(3) do
          MB::Sound.bg(:kick, 60.hz.sine * kicks.env(0.0005, 0.12, 0, 0.05), fade: 0)
          MB::Sound.bg(:spy, spy, fade: 0)
        end
      end
      expect(out.frames_written).to eq(205715)
      expect(seconds).to eq(205715 / 48000.0)
      expect(counts).to eq([1])
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
        MB::Sound.master { |mix| mix.delay(0.2) }
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

    # A live session's timeline pauses while nothing plays; a render keeps
    # time while blocks are still to come (found by fixes-14: this rendered
    # 0 s)
    describe 'with nothing playing until a scheduled block' do
      let(:out) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }

      # Records every buffer written (dup: outputs may reuse buffers)
      def record(out)
        data = []
        allow(out).to receive(:write).and_wrap_original { |m, d| data << d[0].dup; m.call(d) }
        -> { data.reduce(:concatenate) }
      end

      # Bar 2's frame at 112 BPM in a bars: render with something playing
      # from bar 1, as renders already did
      let(:bar2_frame) {
        ref = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        data = record(ref)
        MB::Sound.render(ref, bars: 3, bpm: 112) do
          MB::Sound.bg(:pad, 0.constant, fade: 0)
          MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant, fade: 0) }
        end
        data.call.to_a.index { |v| v != 0 }
      }

      it 'renders silence until the block starts something on its exact frame, then to the end bar' do
        expect(bar2_frame).to eq((4 * 60 / 112r * 48000).floor)

        data = record(out)
        seconds = MB::Sound.render(out, bars: 3, bpm: 112, buffer_size: 128) do
          MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant, fade: 0) }
        end
        expect(seconds).to eq((3 * 4 * 60 / 112r * 48000).ceil / 48000.0)

        d = data.call
        expect(d.length).to eq(out.frames_written)
        expect(d.to_a.index { |v| v != 0 }).to eq(bar2_frame)
        expect(d[bar2_frame..].to_a.uniq).to eq([0.25])
      end

      it 'adds the master tail after the end bar with tail: true' do
        stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 0.25)
        seconds = MB::Sound.render(out, bars: 3, bpm: 120, tail: true) do
          MB::Sound.master { |mix| mix.delay(0.1, feedback: 1, dry: 1, wet: 1) }
          MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant, fade: 0) }
        end
        expect(seconds).to eq(6.25)
      end

      it 'keeps time with seconds:' do
        data = record(out)
        expect(MB::Sound.render(out, seconds: 3, bpm: 120) { MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant, fade: 0) } }).to eq(3)
        d = data.call
        expect(d.to_a.index { |v| v != 0 }).to eq(96000)
        expect(d.length).to eq(144000)
      end

      it 'renders until the block starts something and that ends, without bars: or seconds:' do
        data = record(out)
        seconds = MB::Sound.render(out, bpm: 120) do
          MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant.until(0.5), fade: 0) }
        end
        expect(seconds).to be_within(0.02).of(2.5) # ended players leave on the next buffer
        expect(data.call.to_a.index { |v| v != 0 }).to eq(96000)
      end

      it 'renders silence up to blocks that start nothing, and between sounds' do
        seconds = MB::Sound.render(out, bpm: 120) do
          MB::Sound.bg(:a, 0.25.constant.until(0.5), fade: 0)
          MB::Sound.at_bar(2) { }
          MB::Sound.at_bar(3) { MB::Sound.bg(:b, 0.25.constant.until(0.5), fade: 0) }
        end
        expect(seconds).to be_within(0.02).of(4.5)
      end

      it 'stops at MAX_RENDER_SECONDS with a warning for blocks later than that, without bars: or seconds:' do
        stub_const('MB::Sound::PlaybackMethods::MAX_RENDER_SECONDS', 0.5)
        expect {
          expect(MB::Sound.render(out, bpm: 120) { MB::Sound.at_bar(2) { MB::Sound.bg(:a, 0.25.constant) } }).to eq(0.5)
        }.to output(/after 0.5 seconds; pass bars: or seconds:/).to_stderr
      end

      it 'does not wait for repeating blocks without bars: or seconds:' do
        ran = 0
        seconds = MB::Sound.render(out, 0.25.constant.until(0.5), bpm: 120) do
          MB::Sound.every(1) { ran += 1 }
        end
        expect(seconds).to be_within(0.02).of(0.5)
        expect(ran).to eq(1)

        # Not even one that ran ahead (half a bar) while the sound played
        stub_const('MB::Sound::PlaybackMethods::MAX_RENDER_SECONDS', 5)
        out2 = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        seconds = MB::Sound.render(out2, 0.25.constant.until(1.6), bpm: 120) do
          MB::Sound.every(1) { ran += 1 }
        end
        expect(seconds).to be_within(0.02).of(1.6)
        expect(ran).to eq(3)
      end

      it 'waits for repeating blocks before the end bar with bars:' do
        ran = 0
        seconds = MB::Sound.render(out, 0.25.constant.until(0.5), bars: 3, bpm: 120) do
          MB::Sound.every(1) { ran += 1 }
        end
        expect(seconds).to eq(4) # bar 3's block; bar 4's is the end
        expect(ran).to eq(3)
      end

      it 'plays what the last repeating block started to silence, without padding to the end bar' do
        data = record(out)
        ran = 0
        seconds = MB::Sound.render(out, 0.25.constant.until(0.5), bars: 3, bpm: 120) do
          MB::Sound.every(1) { ran += 1; MB::Sound.bg(:b, 0.5.constant.until(1), fade: 0) if ran == 3 }
        end
        expect(ran).to be >= 3 # bar 4's block may run ahead while :b plays
        expect(seconds).to be_within(0.02).of(5) # bar 3 (4 s) plus 1 s, not cut at 4 s, not padded to 6 s
        d = data.call
        expect(d.to_a.index(0.5)).to eq(192000)
        expect(d[192000...240000].to_a.uniq).to eq([0.5])
      end

      it 'does not wait for blocks after the end bar' do
        seconds = MB::Sound.render(out, 0.25.constant.until(0.5), bars: 3, bpm: 120) do
          MB::Sound.at_bar(4) { MB::Sound.bg(:a, 0.25.constant) }
        end
        expect(seconds).to be_within(0.02).of(0.5)
      end
    end

    it 'renders the tail of master effects after the last sound ends' do
      seconds = MB::Sound.render(filename, bpm: 120) do
        MB::Sound.bg(0.5.constant.until(0.1))
        MB::Sound.master { |mix| mix.delay(0.2) }
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
        MB::Sound.master { |mix| mix.delay(0.1, feedback: 1, dry: 1, wet: 1) }
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
