require 'shellwords'

require_relative 'io_input'

module MB
  module Sound
    # An input stream type that uses FFMPEG to parse an audio stream from most
    # file formats.
    class FFMPEGInput < IOInput
      attr_reader :filename, :rate, :channels, :frames, :info

      # Uses ffprobe to get information about the specified file.  Pass an
      # unescaped filename (no shell backslashes, quotes, etc).
      #
      # Returns an array of Hashes, one Hash for each audio stream in the file.
      def self.parse_info(filename)
        fnesc = filename.shellescape

        # TODO: add -show_format
        raw_info = `ffprobe -loglevel 8 -show_streams -select_streams a #{fnesc}`

        streams = raw_info.each_line.chunk_while { |b, a|
          a != "[STREAM]\n" && b != "[/STREAM]\n"
        }.select { |chunk|
          chunk[0] == "[STREAM]\n"
        }.map { |chunk|
          # Filter out start/end tags and any line that isn't a key/value pair
          chunk.reject { |l|
            l.start_with?('[') || !l.include?('=')
          }.map { |l|
            kv = l.split('=', 2).map(&:strip)

            kv[0] = kv[0].to_sym

            case kv[1]
            when /\A[0-9]+\z/
              kv[1] = kv[1].to_i

            when /\A[0-9]+\.[0-9]+\z/
              # FIXME: this parses channel_layout: "7.1" as float
              kv[1] = kv[1].to_f

            when %r{\A[0-9]+/0\z}
              # Prevent division by zero
              kv[1] = 0

            when %r{\A[0-9]+/[0-9]+\z}
              kv[1] = kv[1].to_r
            end

            kv
          }.to_h
        }
      end

      # Initializes an input stream that will use the `ffmpeg` command to read
      # the specified audio stream (first stream if unspecified) from the given
      # file.
      #
      # +filename+ - The filename to read.
      # +stream_id+ - The number of audio stream to read in multi-stream files (0
      #               is the default).
      # +resample+ - If an integer, asks ffmpeg to resample to that rate.
      # +channels+ - If not nil, asks ffmpeg to convert the number of channels.
      def initialize(filename, stream_id: 0, resample: nil, channels: nil)
        raise "File is not readable" unless File.readable?(filename)
        @filename = filename
        @fnesc = filename.shellescape

        raise "Stream ID must be an integer" unless stream_id.is_a?(Integer)
        @stream_id = stream_id

        # First get info for all streams from ffprobe
        @info = FFMPEGInput.parse_info(@filename)

        if channels
          raise "Channel count must be an integer greater than 0" unless channels.is_a?(Integer) && channels > 0
          @channels = channels
        else
          @channels = @info[stream_id][:channels]
          raise "Missing channels from stream info" unless @channels
        end

        if resample
          raise "Sampling rate must be an integer greater than 0" unless resample.is_a?(Integer) && resample > 0
          @rate = resample
        else
          @rate = @info[stream_id][:sample_rate]
        end

        start = @info[stream_id][:start_time]
        start = 0 unless start.is_a?(Numeric)
        duration = @info[stream_id][:duration]
        @frames = (start + duration * @rate).ceil

        resample_opt = resample ? "-ar '#{@rate}'" : ''
        channels_opt = channels ? "-ac '#{@channels}' -af 'aresample=matrix_encoding=dplii'" : ''
        @pipe = IO.popen(["sh", "-c", "ffmpeg -nostdin -loglevel 8 -i #{@fnesc} #{resample_opt} #{channels_opt} -f f32le -"], "r")

        super(@pipe, @channels)
      end

      # Closes the input pipe from ffmpeg, which should cause it to exit.
      def close
        @pipe.close if @pipe && !@pipe.closed?
        @pipe = nil
      end
    end
  end
end
