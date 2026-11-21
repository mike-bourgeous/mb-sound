# What the live console says about the sound card (console-offers-1): the
# open line per backend, the pull size, the one-time warning when the sound
# server pulls more than the buffer, and the JACK period changing.  The
# backend facts are stubbed on a DeviceOutput on miniaudio's null device.
RSpec.describe(MB::Sound::DeviceReport, :aggregate_failures) do
  pipewire_libjack = '/usr/lib/x86_64-linux-gnu/pipewire-0.3/jack/libjack.so.0.3.1402'
  jackd_libjack = '/usr/lib/x86_64-linux-gnu/libjack.so.0.1.0'
  let(:pipewire_libjack) { pipewire_libjack }
  let(:jackd_libjack) { jackd_libjack }

  before do
    described_class.reset!
    @outputs = []
  end

  after do
    @outputs.each(&:close)
    MB::Sound.live = false
    described_class.reset!
  end

  # A DeviceOutput on the null device whose backend facts are +backend+,
  # +name+, +period+, and +stats+ (merged into the real ones; a Proc gives
  # them at each call).
  def card(backend: :null, name: 'Card', period: 128, stats: {}, buffer_size: 512, **opts)
    o = MB::Sound::DeviceOutput.new(channels: 2, backends: [:null], buffer_size: buffer_size, adaptive: true, **opts)
    @outputs << o
    allow(o).to receive(:backend).and_return(backend)
    allow(o).to receive(:device_name).and_return(name)
    allow(o).to receive(:period).and_return(period)
    real = o.method(:stats)
    allow(o).to receive(:stats) { real.call.merge(stats.respond_to?(:call) ? stats.call : stats) }
    o
  end

  def jack(buffer_size, library: pipewire_libjack)
    allow(MB::Sound::Jack).to receive(:info).and_return({ client_name: 'sound', sample_rate: 48000, buffer_size: buffer_size, cycles: 10, skipped_cycles: 2, repeated_cycles: 0 })
    allow(described_class).to receive(:jack_library).and_return(library)
  end

  it "prints nothing outside live mode (scripts, specs): DeviceOutput's open isn't remembered" do
    card
    expect { described_class.poll }.not_to output.to_stdout
  end

  it 'prints a JACK output through PipeWire once, with the pull, and warns once with what to type' do
    MB::Sound.live = true
    jack(1024)
    o = card(backend: :jack, name: 'sound', period: 1024)
    described_class.opened(o) # (the stubs came after the real open)
    expect {
      expect { described_class.poll }.to output(
        "Audio out: jack client \"sound\" (PipeWire's JACK) at 48000 Hz, buffer 512 frames (latency :default), pulls 1024 frames\n"
      ).to_stdout
    }.to output(
      "Audio out: PipeWire pulls 1024 frames at a time, twice mb-sound's 512-frame buffer, so the screens get new audio half as often and sound comes later; " \
      "PipeWire keeps the period (quantum) it had when mb-sound joined: start with PIPEWIRE_QUANTUM=512/48000 bin/sound.rb, " \
      "or set it for everything with `pw-metadata -n settings 0 clock.force-quantum 512` (0 undoes it)\n"
    ).to_stderr
    expect { described_class.poll }.not_to output.to_stdout

    # The period changes: one line, no second warning
    jack(2048)
    expect { described_class.poll }.to output("Audio out: PipeWire now pulls 2048 frames at a time (was 1024)\n").to_stdout
    expect { described_class.poll }.not_to output.to_stdout
  end

  it "words it for jackd when the JACK library isn't PipeWire's, and says nothing more when the pull fits" do
    MB::Sound.live = true
    jack(1024, library: jackd_libjack)
    o = card(backend: :jack, name: 'sound')
    expect(described_class.open_line(o)).to eq('Audio out: jack client "sound" at 48000 Hz, buffer 512 frames (latency :default), pulls 1024 frames')
    expect { described_class.check(o, 1024) }.to output(
      /\AAudio out: the JACK server pulls 1024 frames at a time, twice mb-sound's 512-frame buffer, .*; set the JACK server's period \(buffer size\) to 512 frames \(jackd -p 512, or your JACK control app\)\n\z/
    ).to_stderr
    expect { described_class.check(o, 2048) }.not_to output.to_stderr # (once per process)

    described_class.reset!
    jack(256, library: jackd_libjack)
    expect { described_class.check(o, 256) }.not_to output.to_stderr
    expect { described_class.check(o, 512) }.not_to output.to_stderr
  end

  it 'gives other backends their pull once a second has played, then warns in general words' do
    MB::Sound.live = true
    played = 0
    o = card(backend: :pulseaudio, name: 'Built-in Audio Analog Stereo', period: 480, stats: -> { { frames_played: played, max_callback: 1024 } })
    described_class.opened(o)
    expect { described_class.poll }.to output(
      "Audio out: pulseaudio \"Built-in Audio Analog Stereo\" at 48000 Hz, buffer 512 frames (latency :default), period 480, pull size known after a second of sound (`latency` shows it)\n"
    ).to_stdout
    played = 24_000
    expect { described_class.poll }.not_to output.to_stdout
    played = 48_000
    expect {
      expect { described_class.poll }.to output("Audio out: the sound card pulls 1024 frames at a time\n").to_stdout
    }.to output(/\AAudio out: the sound card pulls 1024 frames at a time, twice mb-sound's 512-frame buffer, .*; set the sound server's period \(buffer size\) to 512 frames\n\z/).to_stderr
    expect { described_class.poll }.not_to output.to_stdout
  end

  it 'prints an ALSA output with its period, and resampling' do
    o = card(backend: :alsa, name: 'hw:0,0', period: 256)
    allow(o).to receive(:resampling?).and_return(true)
    allow(o).to receive(:device_rate).and_return(44100.0)
    expect(described_class.open_line(o, nil)).to eq(
      'Audio out: alsa "hw:0,0" at 48000 Hz resampled to 44100 Hz, buffer 512 frames (latency :default), period 256, pull size known after a second of sound (`latency` shows it)'
    )
    expect(described_class.buffer_frames(o)).to eq(470)
  end

  it 'gives `latency` the facts: the open line, the queue, the underruns and skipped JACK cycles, and the advice' do
    jack(1024)
    o = card(backend: :jack, name: 'sound', stats: { underruns: 3, concealed_gaps: 2, concealed: 960 })
    text = described_class.facts(o)
    lines = text.lines.map(&:chomp)
    expect(lines[0]).to eq("Audio out: jack client \"sound\" (PipeWire's JACK) at 48000 Hz, buffer 512 frames (latency :default), pulls 1024 frames")
    expect(lines[1]).to match(/\AQueue: 50 ms \(adaptive, up to 85 ms\); latency now \d+ ms \(the queue plus the card's buffer\)\z/)
    expect(lines[2]).to eq('Underruns (xruns): 3 so far, 2 concealed (20 ms); JACK skipped 2 cycles')
    expect(lines[3]).to start_with('Pull: PipeWire pulls 1024 frames at a time')
    expect(lines.length).to eq(4)

    expect(described_class.facts(nil)).to eq('Audio out: not open (it opens when something plays)')
    null = MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, buffer_size: 800)
    expect(described_class.facts(null)).to start_with('Audio out: NullOutput at 48000 Hz, buffer 800 frames (no sound card')
  end

  it 'finds the JACK library the process loaded, from /proc/self/maps where there is one' do
    lib = described_class.jack_library
    if File.readable?('/proc/self/maps') && File.read('/proc/self/maps').include?('libjack.so')
      expect(File.basename(lib)).to start_with('libjack.so')
    else
      expect(lib).to be_nil
    end
  end
end
