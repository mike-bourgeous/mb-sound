RSpec.describe(MB::Sound::BackgroundOutput) do
  # Records everything written to it, optionally sleeping like a realtime
  # output that blocks until there is room for more data.
  let(:recorder_class) {
    Class.new do
      attr_reader :writes, :channels, :sample_rate, :buffer_size
      attr_accessor :fail

      def initialize(channels: 2, buffer_size: 480, realtime: false)
        @channels = channels
        @sample_rate = 48000
        @buffer_size = buffer_size
        @realtime = realtime
        @writes = Queue.new
        @closed = false
      end

      def write(data)
        raise 'Test failure' if @fail
        @writes << data.map(&:dup)
        sleep(data[0].length.to_f / @sample_rate) if @realtime
        data[0].length
      end

      def close; @closed = true; end
      def closed?; @closed; end

      def all_writes
        Array.new(@writes.length) { @writes.pop }
      end
    end
  }

  let(:recorder) { recorder_class.new }
  let(:out) { MB::Sound::BackgroundOutput.new(recorder) }

  after(:each) {
    out.close rescue nil
  }

  def silent?(write)
    write.all? { |c| c.abs.max == 0 }
  end

  it 'delegates sample rate, channels, and buffer size' do
    expect(out.sample_rate).to eq(48000)
    expect(out.channels).to eq(2)
    expect(out.buffer_size).to eq(480)
  end

  it 'writes queued data to the wrapped output in order' do
    bufs = Array.new(5) { |i| [Numo::SFloat.new(480).fill(i + 1), Numo::SFloat.new(480).fill(-i - 1)] }
    bufs.each { |b| out.write(b) }
    out.close

    written = recorder.all_writes.reject { |w| silent?(w) }
    expect(written).to eq(bufs)
  end

  it 'accepts a single Numo::NArray for a mono output' do
    mono = MB::Sound::BackgroundOutput.new(recorder_class.new(channels: 1))
    expect(mono.write(Numo::SFloat.ones(100))).to eq(100)
    mono.close
    expect(mono.output.all_writes.reject { |w| silent?(w) }).to eq([[Numo::SFloat.ones(100)]])
  end

  it 'copies data so callers can reuse their buffers' do
    buf = [Numo::SFloat.ones(480), Numo::SFloat.ones(480)]
    out.write(buf)
    buf.each { |c| c.fill(0.5) }
    out.close

    expect(recorder.all_writes.reject { |w| silent?(w) }).to eq([[Numo::SFloat.ones(480)] * 2])
  end

  it 'writes silence at roughly realtime when idle' do
    out
    sleep 0.3
    out.close

    writes = recorder.all_writes
    expect(writes).to all(satisfy { |w| silent?(w) })

    # 0.3 seconds plus the two-buffer lead time, with room for scheduling jitter
    seconds = writes.sum { |w| w[0].length }.to_f / 48000
    expect(seconds).to be_between(0.2, 0.45)
  end

  it 'counts underruns when the caller stops writing' do
    out.write([Numo::SFloat.ones(480)] * 2)
    sleep 0.1
    expect(out.underruns).to eq(1)
  end

  it 'blocks the caller when the output is slower than the writes' do
    slow = MB::Sound::BackgroundOutput.new(recorder_class.new(realtime: true))
    t = MB::U.clock_now
    20.times { slow.write([Numo::SFloat.zeros(2400)] * 2) } # 1 second of audio
    elapsed = MB::U.clock_now - t
    slow.close

    # At most the queue size plus one in-progress buffer may be unplayed
    expect(elapsed).to be > 0.8
  end

  it 're-raises errors from the background thread' do
    out.write([Numo::SFloat.zeros(480)] * 2)
    recorder.fail = true
    sleep 0.1

    expect { out.write([Numo::SFloat.zeros(480)] * 2) }.to raise_error(MB::Sound::BackgroundOutput::OutputThreadError) { |e|
      expect(e.cause.message).to eq('Test failure')
    }
    expect(out.closed?).to eq(true)
  end

  it 'raises an error for the wrong number of channels' do
    expect { out.write([Numo::SFloat.zeros(480)]) }.to raise_error(ArgumentError, /channels/)
  end

  describe '#close' do
    it 'closes the wrapped output and prevents further writes' do
      out.close
      expect(out.closed?).to eq(true)
      expect(recorder.closed?).to eq(true)
      expect { out.write([Numo::SFloat.zeros(480)] * 2) }.to raise_error(IOError, /closed/)
    end

    it 'can be called more than once' do
      out.close
      expect { out.close }.not_to raise_error
    end
  end

  describe '#strict_buffer_size?' do
    it 'is true if the wrapped output does not say' do
      expect(out.strict_buffer_size?).to eq(true)
    end

    it 'delegates to the wrapped output' do
      o = MB::Sound::BackgroundOutput.new(MB::Sound::NullOutput.new(channels: 2, strict_buffer_size: false))
      expect(o.strict_buffer_size?).to eq(false)
      o.close
    end
  end
end
