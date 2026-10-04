require 'shellwords'

# These use miniaudio's null backend: a timer-driven device thread that runs
# the real callback path at the real rate without hardware.
RSpec.describe('MB::Sound::FastAudio', :aggregate_failures) do
  let(:rate) { 48000 }

  # Opens a null-backend playback device, closed after the example.
  def playback(in_channels: 2, out_channels: 2, queue: 4096, capture: 0, sample_rate: rate)
    MB::Sound::FastAudio::Playback.new([:null], -1, 'mb-sound-spec', in_channels, out_channels, sample_rate, 0, queue, capture).tap { |p|
      @playbacks << p
    }
  end

  # The captured frames as an Array of per-channel SFloats, starting at the
  # first nonzero sample (the null device plays silence before the first
  # write).
  def captured(pb)
    frames = Numo::SFloat.from_binary(pb.captured).reshape(true, pb.device_channels)
    start = (0...frames.shape[0]).find { |i| frames[i, true].ne(0).any? }
    raise 'Nothing was played' if start.nil?
    pb.device_channels.times.map { |c| frames[start..., c].dup }
  end

  def wait_until(timeout: 2)
    deadline = MB::U.clock_now + timeout
    sleep 0.005 until yield || MB::U.clock_now > deadline
  end

  before { @playbacks = [] }
  after { @playbacks.each(&:close) }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_audio.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastAudio.respond_to?(:devices)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  it 'is miniaudio 0.11.25' do
    expect(MB::Sound::FastAudio::MINIAUDIO_VERSION).to eq('0.11.25')
  end

  describe '.enabled_backends' do
    it 'includes the null backend' do
      expect(MB::Sound::FastAudio.enabled_backends).to include(:null)
    end
  end

  describe '.devices' do
    it 'lists the null devices' do
      list = MB::Sound::FastAudio.devices([:null], 'mb-sound-spec')
      expect(list[:backend]).to eq(:null)
      expect(list[:playback]).to eq([{ index: 0, name: 'NULL Playback Device', default: true }])
      expect(list[:capture].length).to eq(1)
    end

    it 'raises for unknown backends' do
      expect { MB::Sound::FastAudio.devices([:nope], 'x') }.to raise_error(ArgumentError, /nope/)
    end
  end

  describe MB::Sound::FastAudio::Playback do
    it 'describes the device' do
      pb = playback
      expect(pb.backend).to eq(:null)
      expect(pb.device_name).to eq('NULL Playback Device')
      expect(pb.sample_rate).to eq(rate)
      expect(pb.device_channels).to eq(2)
      expect(pb.queue_limit).to eq(4096)
      expect(pb.period).to be > 0
      expect(pb.periods).to be > 0
      expect(pb.closed?).to eq(false)
    end

    it 'opens at other requested rates the device supports' do
      expect(playback(sample_rate: 44100).sample_rate).to eq(44100)
    end

    it 'plays exactly what was written, in any buffer sizes' do
      pb = playback(capture: 12000)
      l = Numo::SFloat.new(9000).rand(-1, 1)
      r = Numo::SFloat.new(9000).rand(-1, 1)

      [0...1, 1...800, 800...5001, 5001...9000].each do |range|
        expect(pb.write([l[range], r[range]])).to eq(range.size)
      end

      wait_until { pb.stats[:queued] == 0 }
      wait_until { pb.captured.bytesize >= 12000 * 8 }
      cl, cr = captured(pb)
      expect(cl[0...9000]).to eq(l)
      expect(cr[0...9000]).to eq(r)
      expect(pb.stats[:frames_written]).to eq(9000)
    end

    it 'converts other NArray types and views to float' do
      pb = playback(in_channels: 1, out_channels: 1, capture: 4000)
      data = Numo::DFloat.linspace(-0.5, 0.5, 200)
      pb.write([data[(0..) % 2]])
      wait_until { pb.stats[:queued] == 0 }
      expect(captured(pb)[0][0...100].to_a).to eq(Numo::SFloat.cast(data[(0..) % 2]).to_a)
    end

    it 'fans a mono input out to every device channel' do
      pb = playback(in_channels: 1, out_channels: 2, capture: 4000)
      pb.write([Numo::SFloat[0.1, 0.2, 0.3, 0.4]])
      wait_until { pb.stats[:queued] == 0 }

      l, r = captured(pb)
      expect(l[0...4].to_a).to eq(Numo::SFloat[0.1, 0.2, 0.3, 0.4].to_a)
      expect(r[0...4]).to eq(l[0...4])
    end

    it 'never queues more than the limit, and paces writes to the device clock' do
      pb = playback(queue: 2048)
      buf = Numo::SFloat.zeros(500) + 0.25
      max_queued = 0

      start = MB::U.clock_now
      40.times do
        pb.write([buf, buf])
        max_queued = [max_queued, pb.stats[:queued]].max
      end
      elapsed = MB::U.clock_now - start

      # 20000 frames, all but the last <= 2048 waiting for the device
      expect(max_queued).to be <= 2048
      expect(elapsed).to be_within(0.06).of((20000 - 2048).to_f / rate)
      expect(pb.stats[:underruns]).to eq(0)
    end

    it 'counts each time the audio runs out, not every silent callback' do
      pb = playback
      expect(pb.stats[:underruns]).to eq(0)
      sleep 0.03 # silence before the first write isn't an underrun
      expect(pb.stats[:underruns]).to eq(0)

      2.times do
        pb.write([Numo::SFloat.zeros(100), Numo::SFloat.zeros(100)])
        sleep 0.05
      end

      expect(pb.stats[:underruns]).to eq(2)
      expect(pb.stats[:frames_played]).to be > 0.08 * rate
    end

    it 'raises for mismatched channels and lengths' do
      pb = playback
      expect { pb.write([Numo::SFloat[1]]) }.to raise_error(ArgumentError, /Expected 2 channels, got 1/)
      expect { pb.write([Numo::SFloat[1], Numo::SFloat[1, 2]]) }.to raise_error(ArgumentError, /Channel 1 has 2/)
      expect { pb.write([Numo::SFloat[[1]], Numo::SFloat[[1]]]) }.to raise_error(ArgumentError, /1D/)
    end

    it 'raises for bad options' do
      expect { playback(in_channels: 3, out_channels: 2) }.to raise_error(ArgumentError, /Input channels/)
      expect { playback(out_channels: 0) }.to raise_error(ArgumentError, /Output channels/)
      expect { playback(queue: 1) }.to raise_error(ArgumentError, /Queue size/)
      expect {
        MB::Sound::FastAudio::Playback.new([:null], 5, 'x', 2, 2, rate, 0, 4096, 0)
      }.to raise_error(MB::Sound::FastAudio::Error, /device 5 does not exist/)
    end

    it 'can be closed more than once, and raises IOError when written after closing' do
      pb = playback
      pb.close
      pb.close
      expect(pb.closed?).to eq(true)
      expect { pb.write([Numo::SFloat[1], Numo::SFloat[1]]) }.to raise_error(IOError, /closed/)
      expect { pb.sample_rate }.to raise_error(IOError, /closed/)
    end

    it 'wakes a blocked writer with IOError when closed from another thread' do
      pb = playback(queue: 1024)
      big = Numo::SFloat.zeros(rate * 5)
      t = Thread.new { pb.write([big, big]) }
      wait_until { pb.stats[:queued] > 0 }
      sleep 0.02

      pb.close
      expect { t.join(1) }.to raise_error(IOError, /closed/)
    end

    it 'can interrupt a blocked writer' do
      pb = playback(queue: 1024)
      big = Numo::SFloat.zeros(rate * 5)
      t = Thread.new do
        Thread.current.report_on_exception = false
        pb.write([big, big])
      rescue Interrupt => e
        e
      end
      wait_until { pb.stats[:queued] > 0 }
      sleep 0.02

      t.raise(Interrupt)
      expect(t.join(1)&.value).to be_a(Interrupt)
    end

    it 'refuses to write from a forked child' do
      pb = playback
      rd, wr = IO.pipe
      pid = fork do
        rd.close
        begin
          pb.write([Numo::SFloat[1], Numo::SFloat[1]])
          wr.write('wrote')
        rescue IOError => e
          wr.write(e.message)
        end
        wr.close
        exit!(0)
      end
      wr.close
      Process.wait(pid)

      expect(rd.read).to match(/another process/)
      expect(pb.closed?).to eq(false)
    end
  end
end
