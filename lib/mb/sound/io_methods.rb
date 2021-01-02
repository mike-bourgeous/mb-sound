module MB
  module Sound
    # IO-related methods to include in the sound command-line interface.
    #
    # See the modules MB::Sound extends itself with to find all command-line
    # interface methods.
    module IOMethods
      # If given a raw NArray or an array of numeric values, wraps it in an
      # Array.  If given a Tone or array of Tones, calls its/their
      # MB::Sound::Tone#generate method.
      def any_sound_to_array(array)
        case array
        when Numo::NArray
          [array]

        when Array
          case array[0]
          when Numeric
            [array]

          else
            array.map { |el|
              el = el.generate if el.is_a?(MB::Sound::Tone)
              el
            }
          end

        when MB::Sound::Tone
          [array.generate]

        else
          array
        end
      end

      # Reads an entire sound file into an array of Numo::NArrays, one per
      # channel.  Always resamples to 48kHz.
      #
      # See MB::Sound::FFMPEGInput for more flexible sound input.
      def read(filename, max_frames: nil)
        input = MB::Sound::FFMPEGInput.new(filename, resample: 48000)
        input.read(max_frames || input.frames)
      ensure
        input&.close
      end

      # Writes an Array of Numo::NArrays into the given sound file.  If the sound
      # file already exists and +:overwrite+ is false, an error will be raised.
      #
      # See MB::Sound::FFMPEGOutput for more flexible sound output.
      def write(filename, data, rate:, overwrite: false)
        if !overwrite && File.exist?(filename)
          raise FileExistsError, "#{filename.inspect} already exists"
        end

        data = any_sound_to_array(data)

        output = MB::Sound::FFMPEGOutput.new(filename, rate: rate, channels: data.length)
        output.write(data)
      ensure
        output&.close
      end

      # Lists all files under the given directory, or under a 'sounds' directory
      # if no path is given.
      def list(dir=nil)
        path = dir || File.join(Dir.pwd, 'sounds')
        files = Dir[File.join(path, '**', '*.*')].map { |f|
          File.relative_path(dir || Dir.pwd, f)
        }
        puts files
      end

      # Tries to auto-detect an input device for recording sound.  Returns a
      # sound input stream with a :read method.
      #
      # For input types that support naming a specific device, the INPUT_DEVICE
      # environment variable, the DEVICE environment variable, or the +:device+
      # parameter may be used to override the default.  Environment variables
      # take precedence.  For Jackd, the device is a prefix for port names, with
      # the default being 'system:capture_'.
      #
      # See FFMPEGInput, JackInput, and AlsaInput for more flexible recording.
      def input(rate: 48000, channels: 2, device: nil, buffer_size: nil)
        case RUBY_PLATFORM
        when /linux/
          if `pgrep jackd`.strip.length > 0
            if defined?(JackFFI)
              MB::Sound::JackFFI[client_name: 'mb-sound'].input(channels: channels, connect: device || :physical)
            else
              MB::Sound::JackInput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)
            end
          elsif `pgrep pulseaudio`.strip.length > 0
            MB::Sound::AlsaInput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
          else
            MB::Sound::AlsaInput.new(device: 'default', rate: rate, channels: channels, buffer_size: buffer_size)
          end

        else
          raise NotImplementedError, 'TODO: support other platforms'
        end
      end

      # Tries to auto-detect an output device for playing sound.  Returns a sound
      # output stream with a :write method.
      #
      # For output types that support naming a specific device, the OUTPUT_DEVICE
      # environment variable, the DEVICE environment variable or +:device+
      # parameter may be used to override the default.  Environment variables
      # take precedence.  For JackD, the device is a prefix for port names, with
      # the default being 'system:playback_'.
      #
      # See FFMPEGOutput, JackOutput, and AlsaOutput for more flexible playback.
      #
      # Pass either true or a Hash of options for MB::Sound::PlotOutput in
      # +:plot+ to enable live plotting.
      def output(rate: 48000, channels: 2, device: nil, buffer_size: nil, plot: nil)
        o = nil
        case RUBY_PLATFORM
        when /linux/
          if `pgrep jackd`.strip.length > 0
            if defined?(JackFFI)
              o = MB::Sound::JackFFI[client_name: 'mb-sound'].output(channels: channels, connect: device || :physical)
            else
              o = MB::Sound::JackOutput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)
            end
          elsif `pgrep pulseaudio`.strip.length > 0
            o = MB::Sound::AlsaOutput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
          else
            o = MB::Sound::AlsaOutput.new(device: device || 'default', rate: rate, channels: channels, buffer_size: buffer_size)
          end

        else
          raise NotImplementedError, 'TODO: support other platforms'
        end

        if plot
          graphical = plot.is_a?(Hash) && plot[:graphical] || false
          p = { plot: plotter(graphical: graphical) }
          p.merge!(plot) if plot.is_a?(Hash)

          o = MB::Sound::PlotOutput.new(o, **p)
        end

        o
      end

      # Endlessly streams audio in non-overlapping +:block_size+ chunks from
      # MB::Sound.input to MB::Sound.output.
      #
      # If a block is given, the audio read will be yielded to the block as an
      # Array of Numo::NArrays.
      #
      # Press Ctrl-C to interrupt, or call break in the block.
      def loopback(rate: 48000, channels: 2, block_size: nil, plot: true)
        puts "\e[H\e[J"

        inp = input(rate: rate, channels: channels, buffer_size: block_size)
        inp.read(1)
        outp = output(rate: rate, channels: channels, buffer_size: block_size, plot: plot)
        block_size = outp.buffer_size if outp.respond_to?(:buffer_size)

        loop do
          data = inp.read(block_size)
          data = yield data if block_given?
          outp.write(data)
        end
      ensure
        inp&.close
        outp&.close
      end
    end
  end
end
