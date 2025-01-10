module MB
  module Sound
    # Include in I/O objects or classes to log reads and writes.  Set the IOLOG
    # environment variable to "1" to log a number of inputs and outputs.
    module IOLogger
      def iolog_output=(o)
        @iolog_output = o
      end

      def iolog_output
        @iolog_output ||= STDOUT
      end

      def logdepth
        Thread.current[:sound_io_log_depth] ||= 0
      end

      def logdepth=(d)
        Thread.current[:sound_io_log_depth] = d
      end

      def iolog(str, prefix: nil)
        iolog_output.puts "\e[36m#{Time.now.strftime('%Y-%m-%d_%H-%M-%S.%N')}\e[0m - \e[1;35m#{self.to_s.ljust(60)}\e[0m#{'| ' * logdepth}#{prefix}#{str}"
      end

      def iolog_around(operation)
        @iologidx ||= 0
        color_operation = "\e[34m#{'%05d' % @iologidx} \e[1m#{operation}\e[0m"
        @iologidx += 1

        iolog("#{color_operation} - \e[1mstarting\e[0m", prefix: '- ')

        self.logdepth = self.logdepth + 1
        before = Time.now
        yield

      ensure
        after = Time.now
        elapsed = after - before if after && before

        self.logdepth = self.logdepth - 1
        self.logdepth = 0 if self.logdepth < 0

        iolog("#{color_operation} - #{$! ? "\e[31mfailed\e[0m" : "\e[32msucceeded\e[0m"} - \e[35melapsed: #{elapsed}\e[0m", prefix: '- ')
        iolog_output.puts if self.logdepth == 0
      end

      def read(count)
        iolog_around("read #{count} frames") do
          super.tap { |v|
            iolog "Got #{v.length} channels with #{v[0].length} frames"
          }
        end
      end

      def write(data)
        iolog_around("write #{data.length} channels with #{data.map(&:length)} frames") do
          super
        end
      end
    end

    if ENV['IOLOG'] == '1'
      [
        MB::Sound::WindowReader,
        MB::Sound::WindowWriter,
        MB::Sound::ProcessReader,
        MB::Sound::MultiWriter,
        MB::Sound::ArrayInput,
        MB::Sound::NullInput,
        MB::Sound::NullOutput,
        MB::Sound::JackFFI::Input,
        MB::Sound::JackFFI::Output,
        MB::Sound::IOInput,
        MB::Sound::IOOutput,
        MB::Sound::InputBufferWrapper,
        MB::Sound::OutputBufferWrapper,
        MB::Sound::PlotOutput,
        MB::Sound::Loopback,
        MB::Sound::FFTWriter,
      ].each do |cls|
        cls.prepend(MB::Sound::IOLogger)
      end
    end
  end
end
