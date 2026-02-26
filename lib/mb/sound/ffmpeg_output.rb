module MB
  module Sound
    class FFMPEGOutput < IOOutput
      attr_reader :filename

      # Starts an FFMPEG process to write audio to the given +filename+.  The
      # +filename+ must point to a writable directory, unless a +format+
      # override is specified (to allow using ffmpeg's virtual output formats,
      # such as alsa, pulse, dshow, and avfoundation).
      #
      # +sample_rate+ - The sample rate to write into the output file.  This
      #                 should normally match the sample rate of the input file
      #                 or generated sound, otherwise the audio will play at a
      #                 different speed.
      # +channels+ - The number of channels to write to the output file.
      # +codec+ - An optional audio codec string to pass to ffmpeg to override
      #           its detection based on file extension.
      # +bitrate+ - An optional audio bitrate to override the default value
      #             chosen by ffmpeg, if the codec in use supports a bitrate
      #             parameter.  This may be a number of bits per second, or a
      #             string with a scale suffix like '64k'.
      # +format+ - An optional output format to override ffmpeg's detection
      #            based on file extension.  Run `ffmpeg -formats` for a list
      #            of formats supported by your copy of ffmpeg.  This may, for
      #            example, allow playback of audio to a sound card.
      # +loglevel+ - A log level to pass to ffmpeg (e.g. 'warning', 'error').
      #              The default is 8, which suppresses all or nearly all
      #              console output from ffmpeg.
      # +buffer_size+ - The number of samples per channel per buffer to return
      #                 in #buffer_size.  This value is sometimes used as the
      #                 minimum quantity of writable data, and on Linux is also
      #                 used by IOInput to suggest a pipe buffer size to the
      #                 kernel to reduce latency.
      def initialize(filename, sample_rate:, channels:, codec: nil, bitrate: nil, format: nil, loglevel: nil, buffer_size: nil, metadata: nil)
        if format
          @filename = filename
        else
          dirname = File.expand_path(File.dirname(filename))
          raise "#{dirname.inspect} isn't a directory" unless File.directory?(dirname)
          raise "Directory #{dirname.inspect} isn't writable" unless File.writable?(dirname)
          @filename = File.join(dirname, File.basename(filename))
          @extname = File.extname(@filename)
        end

        raise "Sample rate must be a positive Numeric" unless sample_rate.is_a?(Numeric) && sample_rate > 0
        @sample_rate = sample_rate.to_f

        raise "Channels must be a positive Integer" unless channels.is_a?(Integer) && channels > 0

        # Usually format is set when ffmpeg is being used for realtime output,
        # so set a smaller pipe size to reduce buffer lag and apply
        # backpressure to playback in that case.
        buffer_size ||= format ? 2048 : 32768

        # Default to 32-bit floating point samples in .wav files if no codec is
        # specified.
        codec ||= 'pcm_f32le' if @extname&.downcase == '.wav'

        # no shellescape because no shell
        super(
          [
            'ffmpeg',
            '-nostdin',
            '-y',
            '-loglevel', loglevel || '8',
            '-ar', @sample_rate.to_s,
            '-ac', channels.to_s,
            '-f', 'f32le',
            '-i', 'pipe:',
            *(format ? ['-f', format.to_s] : []),
            *(codec ? ['-acodec', codec.to_s] : []),
            *(bitrate ? ['-b:a', bitrate.to_s] : []),
            *(metadata ? make_metadata(metadata) : []),
            @filename
          ],
          channels,
          buffer_size,
          sample_rate: @sample_rate
        )
      end

      # Closes the output stream and raises an error if ffmpeg returned an
      # error.
      def close
        super.tap { |result|
          # TODO: capture ffmpeg output for the error message
          raise "Writing to #{@filename} failed with result #{result.exitstatus}: #{result}" unless result.success?
        }
      end

      # Tell other classes that this output can accept writes of any size, not
      # just the specified buffer size.
      def strict_buffer_size?
        # TODO: return true for file formats with fixed-sized frames like MP3
        # or video files?
        false
      end
      alias strict_buffer_size strict_buffer_size?

      private

      # Used by the constructor to create metadata-related command-line
      # arguments to ffmpeg.
      def make_metadata(h)
        raise 'Metadata must be a Hash' unless h.is_a?(Hash)
        raise 'Metadata keys must not contain equals signs' if h.keys.any? { |k| k.to_s.include?('=') }
        raise 'Metadata keys must not be blank' if h.keys.any? { |k| k.to_s.strip.empty? }

        h.flat_map { |k, v|
          ['-metadata', "#{k.to_s.strip}=#{v.to_s}"]
        }
      end
    end
  end
end
