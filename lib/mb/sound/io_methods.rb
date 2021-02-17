require 'logger'

module MB
  module Sound
    # IO-related methods to include in the sound command-line interface.
    #
    # See the modules MB::Sound extends itself with to find all command-line
    # interface methods.
    module IOMethods
      # Returns true if the given Array looks like a (possibly nested) numeric
      # array, false if it's not an array or contains non-numeric data.  Only
      # checks the first element of an array.
      def is_numeric_array?(array)
        case array[0]
        when Array
          is_numeric_array?(array[0])

        when Numeric
          true

        else
          false
        end
      end

      # Converts a single Tone or Numeric Array to NArray.  If given an Array
      # of Tones or Numeric Arrays, returns an Array of NArray.
      def convert_sound_to_narray(sound, depth = 0)
        case sound
        when Tone
          sound.generate

        when String
          # If the filename is within an array, only return the first channel
          read(sound).yield_self { |v| depth > 0 ? v[0] : v }

        when Array
          if is_numeric_array?(sound)
            Numo::NArray.cast(sound)
          else
            sound.map { |el| convert_sound_to_narray(el, depth + 1) }
          end

        else
          sound
        end
      end

      # Like #any_sound_to_array, but ensures everything is in a Hash.  If
      # given an Array, returns a Hash mapping array indices to the converted
      # sounds.
      def any_sound_to_hash(sounds)
        if sounds.is_a?(Array)
          sounds = sounds.map.with_index { |v, idx|
            case v
            when String
              k = File.basename(v)

            when Tone
              k = "#{v.frequency.round(2)}Hz"

            else
              k = idx
            end

            [k, v]
          }.to_h
        elsif !sounds.is_a?(Hash)
          sounds = {0 => sounds}
        end

        any_sound_to_array(sounds)
      end

      # Like #convert_sound_to_narray, but wraps everything in a top-level
      # Array if it is not already in one.  If given a Hash, then preserves the
      # keys and maps them to the new values.
      def any_sound_to_array(array)
        if array.is_a?(Hash)
          return array.keys.zip(any_sound_to_array(array.values)).to_h
        end

        convert_sound_to_narray(array).yield_self { |v| v.is_a?(Array) ? v : [v] }
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
              @jack ||= MB::Sound::JackFFI[]
              @jack.logger = Logger.new(STDOUT, level: Logger::ERROR)
              o = @jack.input(channels: channels, connect: device || :physical)
            else
              MB::Sound::JackInput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)
            end
          elsif `pgrep pulseaudio`.strip.length > 0
            MB::Sound::AlsaInput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
          else
            MB::Sound::AlsaInput.new(device: device || 'default', rate: rate, channels: channels, buffer_size: buffer_size)
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
        info = {rate: rate, channels: channels, device: device, buffer_size: buffer_size}

        if plot
          graphical = plot.is_a?(Hash) && plot[:graphical] || false
          p = { plot: plotter(graphical: graphical) }
          p.merge!(plot) if plot.is_a?(Hash)

          @plot_outputs ||= {}
          o = @plot_outputs[[plot, info]]
          o = nil if o&.closed?
          o ||= MB::Sound::PlotOutput.new(output(**info), **p)
          @plot_outputs[[plot, info]] ||= o

          return o
        end

        @outputs ||= {}
        o = @outputs[info]
        return o if o && !(o.respond_to?(:closed?) && o.closed?)
        
        o = nil
        case RUBY_PLATFORM
        when /linux/
          if `pgrep jackd`.strip.length > 0
            if defined?(JackFFI)
              @jack ||= MB::Sound::JackFFI[]
              @jack.logger = Logger.new(STDOUT, level: Logger::ERROR)
              o = @jack.output(channels: channels, connect: device || :physical)
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

        @outputs[info] = o

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
