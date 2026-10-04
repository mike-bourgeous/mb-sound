RSpec.describe(MB::Sound::DeviceInput, :aggregate_failures) do
  ENV_NAMES = [
    'AUDIO_BACKEND', 'INPUT_DEVICE', 'DEVICE', 'AUDIO_SAMPLE_RATE', 'AUDIO_PROFILE', 'AUDIO_BUFFER', 'AUDIO_LATENCY',
    'AUDIO_PERIOD', 'AUDIO_DEVICE_RATE', 'AUDIO_RESAMPLE', 'INPUT_TYPE'
  ]

  around(:each) do |ex|
    saved = ENV_NAMES.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # Opens an input on miniaudio's null device, recording a counting pattern
  # (frame number modulo 4096, scaled to -1..1, plus 0.001 per channel)
  # instead of silence, closed after the example.
  def device_input(**kwargs)
    MB::Sound::DeviceInput.new(backends: [:null], test_pattern: true, **kwargs).tap { |i| @inputs << i }
  end

  # Indexes of frames that don't follow the pattern from the frame before
  def breaks(data)
    steps = (data[1..] - data[0...-1]).to_a.map { |d| (d * 2048).round }
    steps.each_index.reject { |i| steps[i] == 1 || steps[i] == -4095 }
  end

  before { @inputs = [] }
  after { @inputs.each(&:close) }

  it 'opens a sound card and describes it' do
    i = device_input
    expect(i.backend).to eq(:null)
    expect(i.device_name).to eq('NULL Capture Device')
    expect(i.channels).to eq(2)
    expect(i.sample_rate).to eq(48000)
    expect(i.device_rate).to eq(48000)
    expect(i.resampling?).to eq(false)
    expect(i.profile).to eq(:default)
    expect(i.buffer_size).to eq(512)
    expect(i.queue_limit).to eq(2400)
    expect(i.strict_buffer_size?).to eq(false)
    expect(i.inspect).to include('null', 'NULL Capture Device', '2ch', '48000Hz', 'default')
  end

  it 'records continuously at the sound card clock, in any read sizes' do
    i = device_input
    t = MB::U.clock_now
    data = [1, 479, 480, 1000, 2840].map { |n| i.read(n) }
    elapsed = MB::U.clock_now - t

    l = data.map(&:first).reduce(:concatenate)
    r = data.map(&:last).reduce(:concatenate)
    expect(l.length).to eq(4800)
    expect(breaks(l)).to be_empty
    expect((r - l).abs.max).to be_within(1e-6).of(0.001) # the channel offset
    expect(elapsed).to be_within(0.05).of(0.1)
    expect(i.stats).to include(overruns: 0, skipped: 0)
  end

  it 'works as a graph node' do
    i = device_input(channels: 1)
    data = i.sample(800)
    expect(data.length).to eq(800)
    expect(breaks(data)).to be_empty
  end

  it 'skips the oldest audio when reading falls behind, staying near real time' do
    i = device_input(latency: 0.02)
    i.read(10)
    sleep 0.2
    data = i.read(4000)[0]

    # The queue fills during the pause, so the capture thread drops new
    # audio (overruns) and #read skips old audio; reading resumes near the
    # present with a jump or two in the audio
    expect(i.stats[:skipped]).to be > 0
    expect(i.stats[:overruns]).to be > 0
    expect(breaks(data).length).to be <= 2
    expect(i.latency).to be < 0.05
  end

  it 'resamples a sound card running at another rate' do
    i = device_input(channels: 1, device_rate: 44100)
    expect(i.sample_rate).to eq(48000)
    expect(i.device_rate).to eq(44100)
    expect(i.resampling?).to eq(true)
    expect(i.inspect).to include('44100Hz->48000Hz')

    data = Array.new(10) { i.read(480) }.map(&:first).reduce(:concatenate)
    expect(data.length).to eq(4800)
    expect(i.stats[:frames_captured]).to be_within(600).of(4410)
  end

  it 'records at the sound card rate with resample: false' do
    i = device_input(device_rate: 44100, resample: false)
    expect([i.sample_rate, i.device_rate, i.resampling?]).to eq([44100, 44100, false])
  end

  it 'raises IOError when read after closing, and can close twice' do
    i = device_input
    i.close
    i.close
    expect(i.closed?).to eq(true)
    expect(i.inspect).to include('closed')
    expect { i.read(10) }.to raise_error(IOError, /closed/)
  end

  it 'wakes a waiting reader with IOError when closed from another thread' do
    i = device_input
    t = Thread.new {
      Thread.current.report_on_exception = false
      i.read(48000 * 10)
    }
    sleep 0.05
    i.close
    expect { t.join(1) }.to raise_error(IOError, /closed/)
  end

  it 'can interrupt a waiting reader' do
    i = device_input
    t = Thread.new do
      Thread.current.report_on_exception = false
      i.read(48000 * 10)
    rescue Interrupt => e
      e
    end
    sleep 0.05
    t.raise(Interrupt)
    expect(t.join(1)&.value).to be_a(Interrupt)
  end

  it 'refuses to read in a forked child' do
    i = device_input
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      begin
        i.read(10)
        wr.write('read')
      rescue IOError => e
        wr.write(e.message)
      end
      wr.close
      exit!(0)
    end
    wr.close
    Process.wait(pid)
    expect(rd.read).to match(/another process/)
  end

  it 'lists input devices and finds them by name' do
    expect(MB::Sound::DeviceInput.devices(backends: [:null])).to eq([{ index: 0, name: 'NULL Capture Device', default: true }])
    expect(device_input(device: 'null capture').device_name).to eq('NULL Capture Device')
    expect { device_input(device: 'microphone') }.to raise_error(ArgumentError, /No input device matches "microphone".*0: NULL Capture Device/m)
  end

  it 'uses INPUT_DEVICE and the profile environment variables' do
    ENV['INPUT_DEVICE'] = '3'
    expect { device_input }.to raise_error(MB::Sound::FastAudio::Error, /input device 3 does not exist/)

    ENV.delete('INPUT_DEVICE')
    ENV['AUDIO_PROFILE'] = 'low'
    expect(device_input.buffer_size).to eq(256)
  end

  describe 'MB::Sound.input' do
    after { MB::Sound.instance_variable_set(:@inputs, {}) }

    it 'opens a DeviceInput for INPUT_TYPE=device' do
      ENV['INPUT_TYPE'] = 'device'
      ENV['AUDIO_BACKEND'] = 'null'
      inp = MB::Sound.input(channels: 1)
      dev = inp.respond_to?(:input) ? inp.input : inp.instance_variable_get(:@input)
      @inputs << dev if dev.is_a?(MB::Sound::DeviceInput)
      expect(dev).to be_a(MB::Sound::DeviceInput)
      expect(inp.read(100).map(&:length)).to eq([100])
    end
  end
end
