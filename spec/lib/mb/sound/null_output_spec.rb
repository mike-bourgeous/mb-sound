require 'benchmark'

RSpec.describe(MB::Sound::NullOutput) do
  let(:null_sleep) { MB::Sound::NullOutput.new(channels: 1, sleep: true) }
  let(:null_sleep_44k) { MB::Sound::NullOutput.new(channels: 1, sleep: true, sample_rate: 44100) }
  let(:null_no_sleep) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:null_3ch) { MB::Sound::NullOutput.new(channels: 3, sleep: false) }
  let(:short_data) { [Numo::SFloat.zeros(12000)] }
  let(:long_data) { [Numo::SFloat.zeros(96000)] }

  describe '#initialize' do
    describe 'strict_buffer_size parameter' do
      it 'defaults to false' do
        expect(null_3ch.strict_buffer_size?).to eq(false)
      end

      it 'can be set to false' do
        expect(MB::Sound::NullOutput.new(channels: 1, strict_buffer_size: false).strict_buffer_size?).to eq(false)
      end

      it 'can be set to true' do
        expect(MB::Sound::NullOutput.new(channels: 1, strict_buffer_size: true).strict_buffer_size?).to eq(true)
      end
    end
  end

  describe '#close' do
    it 'prevents further writing' do
      expect { null_3ch.write([short_data] * 3) }.not_to raise_error
      null_3ch.close
      expect { null_3ch.write([short_data] * 3) }.to raise_error(/closed/)
    end
  end

  describe '#write' do
    context 'when sleep is true' do
      # Makes MB::U.clock_now return +times+ in order.
      def clock(*times)
        allow(MB::U).to receive(:clock_now).and_return(*times)
      end

      it 'waits for the length of the buffer' do
        clock(100.0)
        expect(Kernel).to receive(:sleep).with(0.25)
        null_sleep.write(short_data)
      end

      it 'keeps a steady rate, subtracting time spent between writes' do
        clock(100.0, 100.35)
        expect(Kernel).to receive(:sleep).with(0.25).ordered
        expect(Kernel).to receive(:sleep).with(be_within(1e-9).of(1.9)).ordered # 2.0 due at 102.25
        null_sleep.write(short_data)
        null_sleep.write(long_data)
      end

      it 'restarts the rate instead of catching up after falling far behind' do
        clock(100.0, 110.0)
        expect(Kernel).to receive(:sleep).with(0.25).twice
        null_sleep.write(short_data)
        null_sleep.write(short_data)
      end

      it 'waits based on sample rate' do
        clock(100.0)
        expect(Kernel).to receive(:sleep).with(1.0)
        null_sleep_44k.write([Numo::SFloat.zeros(44100)])
      end
    end

    context 'when sleep is false' do
      it 'returns instantly' do
        expect(Kernel).not_to receive(:sleep)
        null_no_sleep.write(short_data)
        null_no_sleep.write(long_data)
      end
    end

    it 'raises an error if given the wrong number of channels' do
      expect { null_no_sleep.write(short_data + long_data) }.to raise_error(/channels/i)
    end
  end

  describe 'sleep: :virtual' do
    let(:out) { MB::Sound::NullOutput.new(channels: 1, buffer_size: 100, sleep: :virtual) }
    let(:buf) { [Numo::SFloat.zeros(100)] }

    # Starts a writer thread writing +n+ buffers, recording frames_written
    # after each.
    def writer(n)
      Thread.new { n.times { out.write(buf) } }.tap { |t| t.report_on_exception = false }
    end

    it 'blocks the writer once it is three buffers ahead of what was consumed, without sleeping' do
      expect(Kernel).not_to receive(:sleep)
      t = writer(10)
      expect(out.consume(0)).to eq(300) # returns once the writer is blocked
      expect(t.alive?).to eq(true)
      expect(out.frames_written).to eq(300)

      # 250 frames (rounded from seconds) let 3 more buffers through: 300 + 250 >= 550 needs 6 buffers
      expect(out.consume(250 / 48000.0)).to eq(600)
      expect(out.frames_consumed).to eq(250)
      expect(out.consume(1, stall: 0.05)).to eq(1000) # the writer finished its 10 buffers (the stall safety returns)
      t.join
    end

    it 'never blocks the writer past close or release_writer' do
      t = writer(10)
      out.consume(0)
      out.release_writer
      expect(t.join(5)).to eq(t)
      expect(out.frames_written).to eq(1000)

      o2 = MB::Sound::NullOutput.new(channels: 1, buffer_size: 100, sleep: :virtual)
      t2 = Thread.new { 10.times { o2.write(buf) } rescue $! }
      o2.consume(0)
      o2.close
      expect(t2.value).to be_a(RuntimeError) # the next write after close raises
    end

    it 'lets foreground play finish as fast as the waiter consumes, the same way every time' do
      runs = 2.times.map do
        live = MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: :virtual)
        MB::Sound.use_output(live)
        MB::Sound.play(100.hz.sine.until(0.1), plot: false, quiet: true)
        [live.frames_written, live.frames_consumed]
      ensure
        MB::Sound::Session.default.close
        MB::Sound.use_output(nil)
        MB::Sound.rewind
      end
      expect(runs.uniq.length).to eq(1)
      expect(runs[0][0]).to be <= 4800 + 2 * 2400 + 800
    end

    it 'checks the sleep option' do
      expect { MB::Sound::NullOutput.new(channels: 1, sleep: :fast) }.to raise_error(ArgumentError, /virtual/)
      expect { MB::Sound::NullOutput.new(channels: 1).consume(1) }.to raise_error(ArgumentError, /virtual/)
    end
  end
end
