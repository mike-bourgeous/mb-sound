RSpec.describe(MB::Sound::IOInput) do
  # fix-batch-1106: the golden check's "Errno::EBUSY: Device or resource
  # busy" fingerprinting a short render (2026-11-04) was IOBase#run
  # shrinking the pipe with F_SETPIPE_SZ after starting ffmpeg, which
  # fails once the pipe holds more than the new size.  The size is now
  # set before the command starts (Starter.popen's pipe_size:).
  describe 'a command that fills its pipe at once' do
    # Bytes waiting in pipe +io+ (FIONREAD, Linux).
    def queued(io)
      buf = [0].pack('i')
      io.ioctl(0x541B, buf)
      buf.unpack1('i')
    end

    # Starter.popen, returning only once the child stopped filling the
    # pipe (the race lost every time).
    def popen_after_fill
      allow(MB::Sound::Starter).to receive(:popen).and_wrap_original do |m, *args, **opts|
        io, child = m.call(*args, **opts)
        last = -1
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          n = queued(io)
          break if n > 0 && n == last
          last = n
          sleep 0.05
        end
        [io, child]
      end
    end

    it 'starts, reads, and keeps the smaller pipe' do
      skip 'F_SETPIPE_SZ is Linux-only' unless RUBY_PLATFORM.include?('linux')
      popen_after_fill
      input = MB::Sound::IOInput.new(['sh', '-c', 'head -c 100000 /dev/zero'], 1, 1024, sample_rate: 48000)
      expect(input.instance_variable_get(:@io).fcntl(1032)).to eq(4096) # (F_GETPIPE_SZ: 1024 frames of one float)
      expect(input.read(1000)[0].length).to eq(1000)
      expect(input.read(30000)[0].length).to eq(24000)
      expect(input.close.success?).to eq(true)
    end
  end
end
