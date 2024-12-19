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
        return false unless array.is_a?(Array)

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

        when GraphNode
          # TODO: this could be improved for plotting or saving signal chains/graphs
          sound.sample(960)

        else
          sound
        end
      end

      # Like #any_sound_to_array, but ensures everything is in a Hash.  If
      # given an Array, returns a Hash mapping array indices to the converted
      # sounds.
      def any_sound_to_hash(sounds)
        if sounds.is_a?(Array) && !sounds[0].is_a?(Numeric)
          sounds = sounds.map.with_index { |v, idx|
            case v
            when String
              k = "#{idx}: #{File.basename(v)}"

            when Tone
              k = "#{idx}: #{v.frequency.round(2)}Hz #{v.wave_type}"

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
      # channel.  Resamples to 48kHz unless a different +:rate+ is specified.
      # Pass nil for +:rate+ to disable resampling.
      #
      # See MB::Sound::FFMPEGInput for more flexible sound input.
      def read(filename, max_frames: nil, rate: 48000)
        input = file_input(filename, resample: rate)
        input.read(max_frames || input.frames)
      ensure
        input&.close
      end

      # Writes an Array of Numo::NArrays into the given sound file.  If the sound
      # file already exists and +:overwrite+ is false, an error will be raised.
      #
      # Writes at most +:max_length+ seconds if +data+ is a Tone or a signal
      # graph.
      #
      # The sample +:rate+ defaults to 48kHz to match the default resampling of
      # #read, and the default sample rate of #input and #output.
      #
      # See MB::Sound::FFMPEGOutput for more flexible sound output.
      def write(filename, data, rate: 48000, overwrite: false, max_length: nil)
        # TODO: Handle the signal graph DSL better in convert_sound_to_narray
        if data.is_a?(GraphNode) && !data.is_a?(Tone)
          buffer_size = data.graph_buffer_size || 800
          output = file_output(
            filename,
            rate: rate,
            channels: 1,
            overwrite: overwrite,
            buffer_size: buffer_size
          )

          t = 0
          loop do
            buf = data.sample(output.buffer_size)
            break if buf.nil? || buf.empty?
            output.write([buf])

            t += output.buffer_size.to_f / rate
            break if max_length && t >= max_length
          end
        elsif data.is_a?(Array) && data.all?(GraphNode)
          buffer_size = data.map(&:graph_buffer_size).compact.min || 800

          output = file_output(
            filename,
            rate: rate,
            channels: data.length,
            overwrite: overwrite,
            buffer_size: buffer_size
          )

          t = 0
          loop do
            buf = data.map { |d| d.sample(output.buffer_size) }
            break if buf.all? { |d| d.nil? || d.empty? }

            buf = buf.map { |d|
              if d.nil? || d.empty?
                Numo::SFloat.zeros(output.buffer_size)
              elsif d.length < output.buffer_size
                MB::M.zpad(d, output.buffer_size)
              else
                d
              end
            }

            output.write(buf)

            t += output.buffer_size.to_f / rate
            break if max_length && t >= max_length
          end
        else
          data = any_sound_to_array(data)
          output = file_output(filename, rate: rate, channels: data.length, overwrite: overwrite)
          output.write(data)
        end
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

      # Opens the given file as an input stream with a :read method.  Resamples
      # to 48k by default.  Other keyword arguments are passed to
      # MB::Sound::FFMPEGInput#initialize.
      #
      # See MB::Sound::FFMPEGInput.
      def file_input(filename, resample: 48000, **kwargs)
        MB::Sound::FFMPEGInput.new(filename, resample: resample, **kwargs)
      end

      # Opens the given file as an output stream with a :write method.  The
      # number of +:channels+ must be provided.  Sample rate defaults to 48k.
      # Existing files will not be overwritten, and an error will be raised,
      # unless +:overwrite+ is true.  Other keyword arguments are passed to
      # MB::Sound::FFMPEGOutput#initialize.
      #
      # See MB::Sound::FFMPEGOutput.
      def file_output(filename, rate: 48000, channels:, overwrite: false, **kwargs)
        if !overwrite && File.exist?(filename)
          raise FileExistsError, "#{filename.inspect} already exists"
        end

        MB::Sound::FFMPEGOutput.new(filename, channels: channels, rate: rate, **kwargs)
      end

      # When the mb-sound-jackffi gem is present and the :jack_ffi input or
      # output type is used, this returns a shared instance of the
      # MB::Sound::JackFFI connection to the Jackd audio server.  Used by
      # #input and #output.
      def jack
        @jack ||= MB::Sound::JackFFI[].tap { |j| j.logger = Logger.new(STDOUT, level: Logger::ERROR) }
      end

      # Tries to auto-detect an input device for recording sound.  Returns a
      # sound input stream with a :read method for reading all channels, and
      # :split and :sample methods for use with node graphs (see GraphNode and
      # GraphNode::IOSampleMixin).
      #
      # For input types that support naming a specific device, the INPUT_DEVICE
      # environment variable, the DEVICE environment variable, or the +:device+
      # parameter may be used to override the default.  Environment variables
      # take precedence.  For Jackd, the device is a prefix for port names, with
      # the default being 'system:capture_'.
      #
      # The input type may be changed using the INPUT_TYPE environment
      # variable.  Supported input types are :jack_ffi, :jack, :alsa_pulse,
      # :alsa, and :null.
      #
      # See FFMPEGInput, mb-sound-jackffi, JackInput, and AlsaInput for more
      # flexible recording.
      def input(rate: 48000, channels: 2, device: nil, buffer_size: nil)
        input_type = detect_input

        case input_type
        when :jack_ffi
          inp = jack.input(channels: channels, connect: device || :physical)

        when :jack
          inp = MB::Sound::JackInput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)

        when :alsa_pulse
          inp = MB::Sound::AlsaInput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)

        when :alsa
          inp = MB::Sound::AlsaInput.new(device: device || 'default', rate: rate, channels: channels, buffer_size: buffer_size)

        when :null
          # TODO: Allow changing the duration of the null input using environment variables
          inp = MB::Sound::NullInput.new(rate: rate, channels: channels)

        else
          raise NotImplementedError, 'TODO: support other platforms'
        end

        # mb-sound-jackffi cannot depend on this gem since we depend on it.
        # Therefore we have to mix in GraphNode stuff here instead of including
        # it in mb-sound-jackffi.  We could split the node graph code into a
        # separate gem to get around this.
        inp.extend(GraphNode) unless inp.is_a?(GraphNode)
        inp.extend(GraphNode::IOSampleMixin) unless inp.is_a?(GraphNode::IOSampleMixin)

        inp
      end

      # Returns a Symbol describing the type of input that should be used,
      # based on operating system-specific detection and the INPUT_TYPE
      # environment variable.  See #input.
      def detect_input
        return ENV['INPUT_TYPE'].gsub(/^:/, '').to_sym if ENV['INPUT_TYPE']

        case RUBY_PLATFORM
        when /linux/
          if `pgrep jackd`.strip.length > 0
            if defined?(JackFFI)
              :jack_ffi
            else
              :jack
            end
          elsif `pgrep pulseaudio`.strip.length > 0
            :alsa_pulse
          else
            :alsa
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
      # The output type may be changed using the OUTPUT_TYPE environment
      # variable.  Supported output types are :jack_ffi, :jack, :alsa_pulse,
      # :alsa, and :null.
      #
      # See FFMPEGOutput, mb-sound-jackffi, JackOutput, and AlsaOutput for more
      # flexible playback.
      #
      # Pass either true or a Hash of options for MB::Sound::PlotOutput in
      # +:plot+ to enable live plotting.
      def output(rate: 48000, channels: 2, device: nil, buffer_size: nil, plot: nil)
        info = {rate: rate, channels: channels, device: device, buffer_size: buffer_size, plot: plot}

        if plot
          graphical = plot.is_a?(Hash) && plot[:graphical] || false
          p = { plot: plotter(graphical: graphical) }
          p.merge!(plot) if plot.is_a?(Hash)

          @plot_outputs ||= {}
          o = @plot_outputs[[plot, info]]
          o = nil if o&.closed?
          o ||= MB::Sound::PlotOutput.new(output(**info.merge(plot: nil)), **p)
          @plot_outputs[[plot, info]] ||= o

          return o
        end

        @outputs ||= {}
        o = @outputs[info]
        return o if o && !(o.respond_to?(:closed?) && o.closed?)

        o = nil
        output_type = detect_output
        case output_type
        when :jack_ffi
          o = jack.output(channels: channels, connect: device || :physical)

        when :jack
          o = MB::Sound::JackOutput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)

        when :alsa_pulse
          o = MB::Sound::AlsaOutput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)

        when :alsa
          o = MB::Sound::AlsaOutput.new(device: device || 'default', rate: rate, channels: channels, buffer_size: buffer_size)

        when :null
          o = MB::Sound::NullOutput.new(channels: channels, rate: rate, buffer_size: buffer_size)

        else
          raise "Unsupported output type: #{output_type.inspect}"
        end

        @outputs[info] = o

        o
      end

      # Returns a Symbol describing the type of output that should be used,
      # based on operating system-specific detection and the OUTPUT_TYPE
      # environment variable.  See #output.
      def detect_output
        return ENV['OUTPUT_TYPE'].gsub(/^:/, '').to_sym if ENV['OUTPUT_TYPE']

        case RUBY_PLATFORM
        when /linux/
          if `pgrep jackd`.strip.length > 0
            if defined?(JackFFI)
              :jack_ffi
            else
              :jack
            end
          elsif `pgrep pulseaudio`.strip.length > 0
            :alsa_pulse
          else
            :alsa
          end

        else
          raise NotImplementedError, 'TODO: support other platforms'
        end
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
