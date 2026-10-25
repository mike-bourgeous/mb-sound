RSpec.describe(MB::Sound::DeviceOutput, :aggregate_failures) do
  DEVICE_OUTPUT_ENV = [
    'AUDIO_BACKEND', 'OUTPUT_DEVICE', 'DEVICE', 'AUDIO_SAMPLE_RATE', 'AUDIO_PROFILE', 'AUDIO_BUFFER', 'AUDIO_LATENCY',
    'AUDIO_PERIOD', 'JACK_CLIENT_NAME', 'OUTPUT_TYPE', 'AUDIO_DEVICE_RATE', 'AUDIO_RESAMPLE', 'AUDIO_SET_DEVICE_RATE',
    'AUDIO_ADAPTIVE', 'AUDIO_CONCEAL'
  ]

  around(:each) do |ex|
    saved = DEVICE_OUTPUT_ENV.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # Opens a null-backend output (miniaudio's timer-driven fake device),
  # closed after the example.
  def device_output(**kwargs)
    MB::Sound::DeviceOutput.new(backends: [:null], **kwargs).tap { |o| @outputs << o }
  end

  def wait_until(timeout: 2)
    deadline = MB::U.clock_now + timeout
    sleep 0.005 until yield || MB::U.clock_now > deadline
  end

  # Drops the silence the null device plays before the first write.
  def trim_start(channels)
    start = (0...channels[0].length).find { |i| channels.any? { |c| c[i] != 0 } }
    channels.map { |c| c[start..] }
  end

  before { @outputs = [] }
  after { @outputs.each(&:close) }

  it 'opens a sound card and describes it' do
    o = device_output
    expect(o.backend).to eq(:null)
    expect(o.device_name).to eq('NULL Playback Device')
    expect(o.channels).to eq(2)
    expect(o.device_channels).to eq(2)
    expect(o.sample_rate).to eq(48000.0)
    expect(o.strict_buffer_size?).to eq(false)
    expect(o.inspect).to include('null', 'NULL Playback Device', '2ch', '48000Hz', 'default')
    expect(o.closed?).to eq(false)
  end

  describe 'adaptive queue' do
    let(:block) { [Numo::SFloat.zeros(256)] * 2 }

    # Writes, then lets the queue run dry before writing again
    def drop_out(o, pause: 0.03)
      o.write(block)
      sleep pause
      o.write(block)
    end

    it 'grows the queue by half after a dropout while writing' do
      o = device_output(profile: :low)
      expect(o.adaptive?).to eq(true)
      expect(o.queue_limit).to eq(512)
      expect(o.max_queue).to eq(4080) # the :safe profile's queue

      expect { drop_out(o) }.to output(/Audio dropout: raising the output queue to 16 ms/).to_stderr
      expect(o.queue_limit).to eq(768)
    end

    it 'does not grow after a gap between sounds' do
      o = device_output(profile: :low)
      expect { drop_out(o, pause: 0.4) }.not_to output.to_stderr
      expect(o.queue_limit).to eq(512)
    end

    it 'stops at the :safe queue' do
      o = device_output(profile: :low)
      expect { 8.times { drop_out(o) } }.to output.to_stderr
      expect(o.queue_limit).to eq(4080)
      expect { drop_out(o) }.not_to output.to_stderr
    end

    it 'shrinks back by a third after a while without dropouts, down to where it started' do
      stub_const('MB::Sound::DeviceOutput::SHRINK_AFTER', 0.1)

      # A deep enough queue that steady writing doesn't drop out on a busy
      # machine; pauses long enough to drain it, short enough to count
      o = device_output(profile: :low, latency: 0.05)
      expect(o.queue_limit).to eq(2400)
      expect { 2.times { drop_out(o, pause: 0.08) } }.to output.to_stderr
      expect(o.queue_limit).to eq(4080) # the :safe cap

      notes = []
      allow(o).to receive(:warn) { |msg| notes << msg }
      deadline = MB::U.clock_now + 0.6
      o.write(block) while MB::U.clock_now < deadline

      expect(o.queue_limit).to eq(2400)
      expect(notes).to eq([
        'No audio dropouts for 0 s: lowering the output queue to 57 ms',
        'No audio dropouts for 0 s: lowering the output queue to 50 ms',
      ])
    end

    it 'puts the queue back with #reset_queue' do
      o = device_output(profile: :low)
      expect { drop_out(o) }.to output.to_stderr
      expect(o.queue_limit).to eq(768)
      o.reset_queue
      expect(o.queue_limit).to eq(512)
    end

    it 'can be turned off' do
      o = device_output(profile: :low, adaptive: false)
      expect(o.adaptive?).to eq(false)
      expect(o.max_queue).to eq(512)
      expect { drop_out(o) }.not_to output.to_stderr

      ENV['AUDIO_ADAPTIVE'] = '0'
      expect(device_output(profile: :low).adaptive?).to eq(false)
    end
  end

  describe 'sample rates' do
    it 'resamples to a sound card running at another rate' do
      o = nil
      expect { o = device_output(device_rate: 44100, latency: 0.1) }.to output(/runs at 44100 Hz; resampling from 48000 Hz \(fastest\)/).to_stderr
      expect(o.sample_rate).to eq(48000)
      expect(o.device_rate).to eq(44100)
      expect(o.resampling?).to eq(true)
      expect(o.queue_limit).to eq(4410) # 0.1 s at the card's rate
      expect(o.inspect).to include('48000Hz->44100Hz')

      10.times { o.write([Numo::SFloat.zeros(800)] * 2) }
      expect(o.latency).to be_between(0.05, 0.1 + 0.04)
    end

    it 'runs at the card rate with resample: false' do
      o = nil
      expect { o = device_output(device_rate: 44100, resample: false) }.to output(/runs at 44100 Hz instead of 48000 Hz/).to_stderr
      expect([o.sample_rate, o.device_rate, o.resampling?]).to eq([44100, 44100, false])
    end

    it 'does not resample when the rates match' do
      o = device_output
      expect([o.sample_rate, o.device_rate, o.resampling?]).to eq([48000, 48000, false])
    end

    it 'uses AUDIO_DEVICE_RATE and AUDIO_RESAMPLE' do
      ENV['AUDIO_DEVICE_RATE'] = '32000'
      ENV['AUDIO_RESAMPLE'] = 'medium'
      o = nil
      expect { o = device_output(resample: :best) }.to output(/runs at 32000 Hz; resampling from 48000 Hz \(medium\)/).to_stderr
      expect([o.sample_rate, o.device_rate, o.resampling?]).to eq([48000, 32000, true])

      ENV['AUDIO_RESAMPLE'] = 'off'
      expect { o = device_output }.to output(/runs at 32000 Hz instead of 48000 Hz/).to_stderr
      expect([o.sample_rate, o.resampling?]).to eq([32000, false])
    end

    it 'raises for unknown resamplers' do
      expect { device_output(device_rate: 44100, resample: :sharp) }.to raise_error(ArgumentError, /Unknown resampler :sharp/)
    end
  end

  describe 'latency profiles' do
    it 'uses the :default profile unless told otherwise' do
      o = device_output
      expect(o.profile).to eq(:default)
      expect(o.buffer_size).to eq(512)
      expect(o.period).to eq(128)
      expect(o.queue_limit).to eq(2400)
    end

    it 'uses :low with two writes queued' do
      o = device_output(profile: :low)
      expect([o.buffer_size, o.period, o.queue_limit]).to eq([256, 128, 512])
    end

    it 'uses :video with 120 fps writes' do
      o = device_output(profile: :video)
      expect([o.buffer_size, o.period, o.queue_limit]).to eq([400, 128, 2400])
    end

    it "uses :safe with miniaudio's default period" do
      o = device_output(profile: 'safe')
      expect([o.buffer_size, o.period, o.queue_limit]).to eq([800, 480, 4080])
    end

    it 'lets arguments override the profile, and AUDIO_PROFILE choose it' do
      ENV['AUDIO_PROFILE'] = 'low'
      o = device_output(profile: :safe, buffer_size: 400)
      expect(o.profile).to eq(:low)
      expect([o.buffer_size, o.period, o.queue_limit]).to eq([400, 128, 800])
    end

    it 'lets AUDIO_BUFFER, AUDIO_PERIOD, and AUDIO_LATENCY override everything' do
      ENV['AUDIO_BUFFER'] = '400'
      ENV['AUDIO_PERIOD'] = '256'
      ENV['AUDIO_LATENCY'] = '0.1'
      o = device_output(buffer_size: 128, period: 64, latency: 0.01)
      expect([o.buffer_size, o.period, o.queue_limit]).to eq([400, 256, 4800])
    end

    it 'raises for unknown profiles' do
      expect { device_output(profile: :fast) }.to raise_error(ArgumentError, /Unknown audio profile :fast \(low, default, video, safe\)/)
    end
  end

  it 'plays exactly what is written' do
    o = device_output(capture: 6000)
    l = Numo::SFloat.new(4000).rand(-1, 1)
    r = Numo::SFloat.new(4000).rand(-1, 1)
    5.times { |i| o.write([l[(i * 800)...((i + 1) * 800)], r[(i * 800)...((i + 1) * 800)]]) }

    wait_until { o.stats[:queued] == 0 }
    cl, cr = trim_start(o.captured)
    expect(cl[0...4000]).to eq(l)
    expect(cr[0...4000]).to eq(r)
    expect(o.frames_written).to eq(4000)
    expect(o.frames_played).to be >= 4000
    expect(o.underruns).to eq(1) # the end of the audio
  end

  it 'plays MAIN and CUE channels of a 4-channel output (cue: 2)' do
    o = device_output(channels: 4, cue: 2, capture: 2000)
    expect(o.cue_channels).to eq(2)
    expect(o.device_channels).to eq(4)
    chans = Array.new(4) { Numo::SFloat.new(800).rand(-1, 1) }
    o.write(chans)
    wait_until { o.stats[:queued] == 0 }
    got = trim_start(o.captured)
    expect(got.length).to eq(4)
    4.times { |c| expect(got[c][0...800]).to eq(chans[c]) }
    expect { device_output(channels: 2, cue: 2) }.to raise_error(ArgumentError, /cue: must be 0 to 1/)
  end

  it 'plays a mono output on both channels of a stereo device' do
    o = device_output(channels: 1, capture: 3000)
    expect(o.channels).to eq(1)
    expect(o.device_channels).to eq(2)

    data = Numo::SFloat.linspace(0.1, 0.5, 100)
    o.write([data])
    wait_until { o.stats[:queued] == 0 }
    l, r = trim_start(o.captured)
    expect(l[0...100]).to eq(data)
    expect(r[0...100]).to eq(data)
  end

  it 'reports the latency from the queue and the device buffer' do
    o = device_output(latency: 0.05)
    expect(o.queue_limit).to eq(2400)

    # Only the device's own buffer before writing
    expect(o.latency).to be > 0
    expect(o.latency).to be < 0.05

    10.times { o.write([Numo::SFloat.zeros(800)] * 2) }
    expect(o.latency).to be_between(0.02, 0.05 + 0.03)
  end

  it 'tops the queue up one write at a time instead of in bursts' do
    # When full, a write waits only until it fits, so each write returns
    # with the queue nearly full, and writes are spaced about one write
    # apart.  Waiting for half the queue to play instead would let about
    # half the writes return at once (measured on the null device: median
    # queue 1664 of 2400, 33 of 50 writes returning at once).
    #
    # The queue stays fixed (adaptive: false): this is about pacing, and a
    # writer stalled for longer than the queue (a loaded machine, a GC
    # pause) made an adaptive output warn "Audio dropout: raising the
    # output queue" and grow its limit mid-measurement (spec:parallel,
    # 2026-10-18; reproduced with an 80 ms stall).  With a fixed queue the
    # same stall is one underrun.
    #
    # The property is measured per write from the device's own counters,
    # not from wall-clock time (omnibus9, 2026-10-18): a write that found
    # no room must return only after the device played more, and writes
    # that found room (catching up after the writer was late) may return
    # at once.  Counting writes under 1 ms as "instant" failed under load
    # (11 of 50 with 4 spec processes): after a stall every catch-up write
    # is instant, and a full-queue write whose device callback was due
    # within 1 ms waited less than that (measured: 0.43 ms).  The stall
    # below makes that case part of every run (an 80 ms writer stall,
    # longer than the 50 ms queue).
    o = device_output(profile: :default, adaptive: false)
    data = [Numo::SFloat.zeros(o.buffer_size)] * 2
    20.times { o.write(data) } # fill the queue

    depths = []
    unpaced = []
    full = 0
    50.times do |i|
      sleep 0.08 if i == 25 # a stalled writer (load, a GC pause)
      before = o.stats
      no_room = before[:queued] + o.buffer_size > o.queue_limit
      o.write(data)
      after = o.stats
      if no_room
        full += 1
        unpaced << i unless after[:frames_played] > before[:frames_played]
      end
      depths << after[:queued]
    end

    expect(unpaced).to eq([])
    expect(full).to be >= 30 # (most writes find the queue full: no bursts)
    expect(depths.sort[depths.length / 2]).to be >= o.queue_limit - o.buffer_size
  end

  it 'never queues less than two buffers' do
    expect(device_output(latency: 0.001, buffer_size: 512).queue_limit).to eq(1024)
  end

  it 'raises for the wrong number of channels' do
    expect { device_output.write([Numo::SFloat[1]]) }.to raise_error(/Expected 2 channels, got 1/)
  end

  it 'raises IOError when written after closing, and can close twice' do
    o = device_output
    o.close
    o.close
    expect(o.closed?).to eq(true)
    expect(o.inspect).to include('closed')
    expect { o.write([Numo::SFloat[1]] * 2) }.to raise_error(IOError)
  end

  it 'plays what a Session renders, sample for sample' do
    o = device_output(capture: 48000)
    transport = MB::Sound::Sequence::Transport.new
    session = MB::Sound::Session.new(master_gain: 1, output: o, transport: transport, buffer_size: 800, realtime: false, raise_errors: true)
    session.add(110.hz.saw.at(0.5), name: :saw)

    rendered = Array.new(20) { session.process_buffer.map(&:dup) }
    wait_until { o.stats[:queued] == 0 }

    # Gaps from a slow writer (e.g. under rake memcheck) break the exact
    # comparison; one underrun is the end of the audio
    skip 'the Session fell behind the sound card (e.g. under rake memcheck)' if o.underruns > 1

    expected = 2.times.map { |c| SpecBuffers.join(rendered.map { |b| b[c] }) }

    # The ramp starts at zero, so align the first nonzero samples
    captured = o.captured
    first_expected = (0...16000).find { |i| expected[0][i] != 0 }
    first_played = (0...captured[0].length).find { |i| captured[0][i] != 0 }
    offset = first_played - first_expected
    played = captured.map { |c| c[offset...(offset + 16000)] }

    expect(played[0]).to eq(expected[0])
    expect(played[1]).to eq(expected[1])
  ensure
    session&.close
  end

  describe 'environment variables' do
    it 'uses AUDIO_BACKEND, AUDIO_SAMPLE_RATE, AUDIO_LATENCY, and OUTPUT_DEVICE over arguments' do
      ENV['AUDIO_BACKEND'] = 'null'
      ENV['AUDIO_SAMPLE_RATE'] = '44100'
      ENV['AUDIO_LATENCY'] = '0.1'
      ENV['OUTPUT_DEVICE'] = 'null playback'

      o = MB::Sound::DeviceOutput.new(backends: [:nope], sample_rate: 96000, latency: 0.5, device: 'nothing')
      @outputs << o
      expect(o.backend).to eq(:null)
      expect(o.sample_rate).to eq(44100)
      expect(o.queue_limit).to eq(4410)
      expect(o.device_name).to eq('NULL Playback Device')
    end

    it 'uses DEVICE as a fallback for OUTPUT_DEVICE' do
      ENV['DEVICE'] = '7'
      expect { device_output }.to raise_error(MB::Sound::FastAudio::Error, /device 7 does not exist/)
    end
  end

  describe '.backends' do
    it 'parses comma-separated strings and symbols' do
      expect(MB::Sound::DeviceOutput.backends('jack, :pulseaudio,alsa')).to eq([:jack, :pulseaudio, :alsa])
      expect(MB::Sound::DeviceOutput.backends([:null])).to eq([:null])
    end

    it 'prefers AUDIO_BACKEND' do
      ENV['AUDIO_BACKEND'] = 'alsa'
      expect(MB::Sound::DeviceOutput.backends([:null])).to eq([:alsa])
    end

    it 'tries JACK first on Linux only when a JACK server is running' do
      stub_const('RUBY_PLATFORM', 'x86_64-linux')

      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(true)
      expect(MB::Sound::DeviceOutput.backends).to eq([:jack, :pulseaudio, :alsa])

      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(false)
      expect(MB::Sound::DeviceOutput.backends).to eq([:pulseaudio, :alsa])
    end

    describe '.jack_running?' do
      it 'asks JACK whether a server accepts clients' do
        allow(MB::Sound::FastAudio).to receive(:jack_server?).and_return(true, false)
        expect(MB::Sound::DeviceOutput.jack_running?).to eq(true)
        expect(MB::Sound::DeviceOutput.jack_running?).to eq(false)
      end
    end

    it "uses miniaudio's order on macOS" do
      stub_const('RUBY_PLATFORM', 'arm64-darwin24')
      expect(MB::Sound::DeviceOutput.backends).to eq(nil)
    end
  end

  describe '.devices' do
    it 'lists the playback devices' do
      expect(MB::Sound::DeviceOutput.devices(backends: [:null])).to eq([{ index: 0, name: 'NULL Playback Device', default: true }])
      expect(MB::Sound::DeviceOutput.backend(backends: [:null])).to eq(:null)
    end
  end

  describe '.device_index' do
    it 'returns -1 for the default device' do
      [nil, '', ' ', 'default'].each do |d|
        expect(MB::Sound::DeviceOutput.device_index(d, backends: [:null])).to eq(-1)
      end
    end

    it 'accepts indexes' do
      expect(MB::Sound::DeviceOutput.device_index(3)).to eq(3)
      expect(MB::Sound::DeviceOutput.device_index('2')).to eq(2)
    end

    it 'finds devices by part of their name, ignoring case' do
      expect(MB::Sound::DeviceOutput.device_index('null PLAY', backends: [:null])).to eq(0)
    end

    it 'lists the devices when none match' do
      expect { MB::Sound::DeviceOutput.device_index('speakers', backends: [:null]) }
        .to raise_error(ArgumentError, /No output device matches "speakers".*0: NULL Playback Device/m)
    end
  end

  describe '.client_name' do
    it 'uses JACK_CLIENT_NAME' do
      ENV['JACK_CLIENT_NAME'] = 'my synth!'
      expect(MB::Sound::DeviceOutput.client_name).to eq('my_synth_')
    end

    it "uses the script's name" do
      old = $0
      $0 = '/x/bin/effects/flanger.rb'
      expect(MB::Sound::DeviceOutput.client_name).to eq('flanger')
    ensure
      $0 = old
    end
  end

  describe 'MB::Sound.output' do
    it 'opens a DeviceOutput for the :device output type' do
      ENV['AUDIO_BACKEND'] = 'null'
      o = MB::Sound.output(output_type: :device, shared: false)
      @outputs << o
      expect(o).to be_a(MB::Sound::DeviceOutput)
      expect(o.backend).to eq(:null)
    end

    it 'opens a DeviceOutput for OUTPUT_TYPE=device' do
      ENV['AUDIO_BACKEND'] = 'null'
      ENV['OUTPUT_TYPE'] = 'device'
      o = MB::Sound.output(channels: 1, shared: false)
      @outputs << o
      expect(o).to be_a(MB::Sound::DeviceOutput)
      expect(o.channels).to eq(1)
    end
  end

  describe 'underrun concealment' do
    it 'plays silence by default for now, and takes :conceal or AUDIO_CONCEAL' do
      expect(device_output.concealment[:mode]).to eq(:silence)
      expect(device_output(conceal: :repeat).concealment[:mode]).to eq(:repeat)
      ENV['AUDIO_CONCEAL'] = 'fixed:30'
      c = device_output(conceal: :silence).concealment
      expect(c.values_at(:mode, :fixed, :grain_min, :grain_max)).to eq([:repeat, true, 0.03, 0.03])
    end

    it 'fills a gap in the written audio, counted in stats, and not after end_stream' do
      o = device_output(channels: 1, capture: 24000, adaptive: false, conceal: :repeat)
      t = Numo::DFloat.new(4800).seq(1)
      o.write([Numo::SFloat.cast(Numo::NMath.sin(t * 0.03) * 0.5)])
      wait_until { o.stats[:concealed] >= 2400 }
      expect(o.stats[:concealed_gaps]).to eq(1)
      expect(o.underruns).to eq(1)

      o.write([Numo::SFloat.zeros(10) + 0.1])
      o.end_stream
      wait_until { o.stats[:queued] == 0 }
      gaps = o.stats[:concealed_gaps]
      sleep 0.05
      expect(o.stats[:concealed_gaps]).to eq(gaps)
    end
  end

  describe MB::Sound::Concealment do
    it 'reads names, grain ranges, Lengths, and AUDIO_CONCEAL-style strings' do
      c = MB::Sound::Concealment
      expect(c.settings(:repeat)).to eq(c::DEFAULTS)
      expect(c.settings[:mode]).to eq(c::DEFAULT)
      expect(c.settings(true)).to eq(c::DEFAULTS)
      expect(c.settings(grain: 10.ms..40.ms).values_at(:grain_min, :grain_max)).to eq([0.01, 0.04])
      expect(c.settings(mode: :fixed, grain: 128.samples)[:grain_min]).to eq(128 / 48000.0)
      expect(c.settings('repeat:15-45').values_at(:grain_min, :grain_max)).to eq([0.015, 0.045])
      expect(c.settings(false)[:mode]).to eq(:silence)
      expect(c.settings(fade: nil)[:fade]).to be_nil
    end

    it 'raises for unknown or impossible settings' do
      c = MB::Sound::Concealment
      expect { c.settings(:loop) }.to raise_error(c::Error, /Unknown concealment :loop/)
      expect { c.settings(grian: 0.02) }.to raise_error(c::Error, /Unknown concealment setting :grian/)
      expect { c.settings(grain: 0.2) }.to raise_error(c::Error, /history must hold the longest grain/)
      expect { c.settings(grain: 0.05..0.02) }.to raise_error(c::Error, /backwards/)
    end
  end
end
