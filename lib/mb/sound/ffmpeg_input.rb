require 'shellwords'
require 'json'

require_relative 'io_input'

module MB
  module Sound
    # An input stream type that uses FFMPEG to parse an audio stream from most
    # file formats.
    class FFMPEGInput < IOInput
      attr_reader :filename, :rate, :channels, :frames, :info, :raw_info

      # A list of metadata keys that should not be parsed numerically.
      EXCLUDED_CONVERSIONS = [
        # Channel layout of e.g. '7.1' should stay as a String
        :channel_layout
      ]

      # Uses ffprobe to get information about the specified file.  Pass an
      # unescaped filename (no shell backslashes, quotes, etc).
      #
      # Returns an array of Hashes, one Hash for each audio stream in the file.
      def self.parse_info(filename)
        fnesc = filename.shellescape

        raw_info = `ffprobe -loglevel 8 -print_format json -show_format -show_streams -select_streams a #{fnesc}`
        raise "ffprobe failed: #{$?}" unless $?.success?

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
      # +filename+ - The filename to read.
      # +stream_idx+ - The number of audio stream to read in multi-stream files
      #                (0 is the default).  This is the order in which the
      #                stream is listed in the file, not a format-specific
      #                stream ID, so if a file has two video and two audio
      #                tracks, the audio tracks will still be indexes 0 and 1.
      # +resample+ - If an integer, asks ffmpeg to resample to that rate.
      # +channels+ - If not nil, asks ffmpeg to convert the number of channels.
      def initialize(filename, stream_idx: 0, resample: nil, channels: nil)
        raise "File #{filename.inspect} is not readable" unless File.readable?(filename)
        @filename = filename
        @fnesc = filename.shellescape

        # Get info for all streams from ffprobe so we know stream IDs, etc.
        @raw_info = FFMPEGInput.parse_info(@filename)

        raise "Stream index must be an integer" unless stream_idx.is_a?(Integer)
        unless @raw_info[:streams][stream_idx]
          raise "Stream index is out of range of audio streams (0..#{@raw_info[:streams].size - 1})"
        end
        @info = @raw_info[:format].merge(@raw_info[:streams][stream_idx])
        @stream_idx = stream_idx
        @stream_id = @info[:index]&.to_i || 0

        if channels
          raise "Channel count must be an integer greater than 0" unless channels.is_a?(Integer) && channels > 0
          @channels = channels
        else
          @channels = @info[:channels]
          raise "Missing channels from stream info" unless @channels
        end

        if resample
          raise "Sampling rate must be an integer greater than 0" unless resample.is_a?(Integer) && resample > 0
          @rate = resample
        else
          @rate = @info[:sample_rate]
        end

        start = @info[:start_time]
        start = 0 unless start.is_a?(Numeric)
        duration = @info[:duration]
        @frames = (start + duration * @rate).ceil

        resample_opt = resample ? "-ar '#{@rate}'" : ''
        channels_opt = channels ? "-ac '#{@channels}' -af 'aresample=matrix_encoding=dplii'" : ''
        @pipe = IO.popen(["sh", "-c", "ffmpeg -nostdin -loglevel 8 -i #{@fnesc} #{resample_opt} #{channels_opt} -map 0:#{@stream_id} -f f32le -"], "r")

        super(@pipe, @channels)
      end

      # Closes the input pipe from ffmpeg, which should cause it to exit.
      # Returns the Process::Status object for the ffmpeg process.
      def close
        if @pipe && !@pipe.closed?
          @pipe.close
          result = $?
        end
        @pipe = nil

        result
      end
    end
  end
end
