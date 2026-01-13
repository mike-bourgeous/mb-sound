require 'shellwords'
require 'json'

module MB
  module Sound
    # An input stream type that uses FFMPEG to parse an audio stream from most
    # file formats.
    class FFMPEGInput < IOInput
      # Note: number of frames may be approximate
      attr_reader :filename, :frames, :info, :raw_info, :duration, :metadata

      # A list of metadata keys that should not be parsed numerically.
      EXCLUDED_CONVERSIONS = [
        # Channel layout of e.g. '7.1' should stay as a String
        :channel_layout
      ]

      # Uses ffprobe to get information about the specified file.  Pass an
      # unescaped filename (no shell backslashes, quotes, etc).
      #
      # Returns a Hash with :streams, containing an array of Hashes describing
      # each audio/video/other stream in the file (or just audio streams if
      # +audio_only+ is true); and :format, containing a Hash describing the
      # file as a whole.
      def self.parse_info(filename, format: nil, audio_only: true)
        fnesc = filename.shellescape

        format_opt = format ? "-f #{format.shellescape}" : ''
        audio_opt = audio_only ? '-select_streams a' : ''
        raw_info = `ffprobe -loglevel 8 -print_format json -show_format -show_streams #{audio_opt} #{format_opt} #{fnesc}`
        raise "ffprobe failed for #{filename.inspect}: #{$?}\n\t#{raw_info}" unless $?.success?

        convert_values(JSON.parse(raw_info, symbolize_names: true)).tap { |h|
          h[:streams]&.sort_by! { |s| s[:index] || 0 }
        }
      end

      # For internal use by .parse_info.  Converts numbers represented as
      # strings to Ruby numeric types.
      def self.convert_values(h)
        renames = []

        h.each do |k, v|
          if k.to_s =~ /\A[[:upper:]_-]+\z/
            renames << k
          end

          next if EXCLUDED_CONVERSIONS.include?(k)

          case v
          when Array
            h[k] = v.map { |el| convert_values(el) }

          when Hash
            h[k] = convert_values(v)

          when /\A[0-9]+\z/
            h[k] = v.to_i

          when /\A[0-9]+\.[0-9]+\z/
            h[k] = v.to_f

          when %r{\A[0-9]+/0\z}
            # Prevent division by zero in the following Rational conversion
            h[k] = 0

          when %r{\A[0-9]+/[0-9]+\z}
            h[k] = v.to_r
          end
        end

        renames.each do |k|
          h[k.to_s.downcase.to_sym] = h.delete(k)
        end

        h
      end

      # Initializes an input stream that will use the `ffmpeg` command to read
      # the specified audio stream (first stream if unspecified) from the given
      # file.
      #
      # Note that this supports recording audio by using a platform-specific
      # ffmpeg virtual format (e.g. dshow, alsa, pulse, or avfoundation), but
      # this method of recording audio introduces significant delay.
      #
      # +filename+ - The filename to read.  The file must exist, unless a
      #              +format+ is specified (to support capture devices).
      # +stream_idx+ - The number of audio stream to read in multi-stream files
      #                (0 is the default).  This is the order in which the
      #                stream is listed in the file, not a format-specific
      #                stream ID, so if a file has two video and two audio
      #                tracks, the audio tracks will still be indexes 0 and 1.
      # +resample+ - If an integer, asks ffmpeg to resample to that rate.
      # +channels+ - If not nil, asks ffmpeg to convert the number of channels.
      # +format+ - An optional input format to override ffmpeg's detection
      #            based on file extension.  Run `ffmpeg -formats` for a list
      #            of formats supported by your copy of ffmpeg.  This may, for
      #            example, allow you to record audio from a sound card.
      # +loglevel+ - A log level to pass to ffmpeg (e.g. 'warning', 'error').
      #              The default is 8, which suppresses all or nearly all
      #              console output from ffmpeg.
      # +buffer_size+ - The number of samples per channel per buffer to return
      #                 in #buffer_size.  This value is sometimes used as the
      #                 minimum quantity of readable data, and on Linux is also
      #                 used by IOInput to suggest a pipe buffer size to the
      #                 kernel to reduce latency.
      def initialize(filename, stream_idx: 0, resample: nil, channels: nil, format: nil, loglevel: nil, buffer_size: nil)
        raise 'No filename given' unless filename
        raise "File #{filename.inspect} is not readable" unless File.readable?(filename) || format
        @filename = filename
        fnesc = filename.shellescape

        # Get info for all streams from ffprobe so we know stream IDs, etc.
        @raw_info = FFMPEGInput.parse_info(@filename, format: format)
        @metadata = @raw_info.dig(:format, :tags) || {}

        raise "Stream index must be an integer" unless stream_idx.is_a?(Integer)
        unless @raw_info[:streams][stream_idx]
          raise "Stream index is out of range of audio streams (0..#{@raw_info[:streams].size - 1})"
        end
        @info = @raw_info[:format].merge(@raw_info[:streams][stream_idx])
        @stream_idx = stream_idx
        @stream_id = @info[:index]&.to_i || 0

        if channels
          raise "Channel count must be an integer greater than 0" unless channels.is_a?(Integer) && channels > 0
        else
          channels = @info[:channels]
          raise "Missing channels from stream info" unless channels
        end

        @sample_rate = info[:sample_rate]

        if @info[:duration_ts]
          @frames = @info[:duration_ts].to_r
          @frames *= @info[:time_base] || (1.to_r / @info[:sample_rate])
          @frames *= @info[:sample_rate]
          @frames = @frames.ceil
        else
          @frames = ((@info[:duration] || 0) * @sample_rate).ceil
        end

        if resample
          raise "Sampling rate must be a positive Numeric" unless resample.is_a?(Numeric) && resample > 0
          @sample_rate = resample.to_f
          @frames = (@frames * @sample_rate / @info[:sample_rate]).ceil if @info.include?(:sample_rate)
        end

        @duration = @frames.to_f / @sample_rate

        # Usually format is set when ffmpeg is being used for realtime input,
        # so set a smaller pipe size to reduce buffer lag and drop frames to
        # keep live sync in that case.
        buffer_size ||= format ? 1024 : 2048

        # Compensate for possible delay at the start of a stream e.g. in a
        # video where the audio starts after the video
        start = @info[:start_time]
        start = 0 unless start.is_a?(Numeric)
        @frames += (start * @sample_rate).ceil

        resample_opt = resample ? "-ar '#{@sample_rate}'" : ''
        channels_opt = channels ? "-ac '#{channels}' -af 'aresample=matrix_encoding=dplii'" : ''
        format_opt = format ? "-f #{format.shellescape}" : ''
        log_opt = "-loglevel #{loglevel&.to_s&.shellescape || 8}"

        super(
          [
            "sh", "-c",
            "ffmpeg -nostdin #{log_opt} #{format_opt} -i #{fnesc} #{resample_opt} " +
            "#{channels_opt} -map 0:#{@stream_id} -f f32le -"
          ],
          channels,
          buffer_size,
          sample_rate: @sample_rate
        )
      end

      # Closes the input stream and raises an error if ffmpeg returned an
      # error.
      def close
        super.tap { |result|
          # TODO: capture ffmpeg output for the error message
          raise "Reading from #{@filename} failed" unless result.success?
        }
      end

      # Returns a playback progress as a percentage of the total length from 0
      # to 100.
      def progress
        @frames_read * 100.0 / @frames
      end

      # Returns the number of seconds played so far.
      def elapsed
        @frames_read.to_f / @sample_rate
      end
    end
  end
end
