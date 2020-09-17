require 'shellwords'

module MB
  module Sound
    class FFMPEGOutput < IOOutput
      attr_reader :filename, :rate, :channels

      # Starts an FFMPEG process to write audio to the given +filename+, with
      # the given sample +:rate+ and +:channels+.  The codec will be guessed by
      # ffmpeg from the file extension, unless +:codec+ is specified.  For some
      # codecs, the +:bitrate+ may be specified as a number of bits per second,
      # or a string with a scale suffix like '64k'.
      def initialize(filename, rate:, channels:, codec: nil, bitrate: nil)
        # TODO: Support special ffmpeg outputs like Pulseaudio?
        dirname = File.expand_path(File.dirname(filename))
        raise "#{dirname.inspect} isn't a directory" unless File.directory?(dirname)
        raise "Directory #{dirname.inspect} isn't writable" unless File.writable?(dirname)
        @filename = File.join(dirname, File.basename(filename))

        raise "Sample rate must be a positive Integer" unless rate.is_a?(Integer) && rate > 0
        @rate = rate

        raise "Channels must be a positive Integer" unless channels.is_a?(Integer) && channels > 0
        @channels = channels

        # no shellescape because no shell
        pipe = IO.popen(
          [
            'ffmpeg',
            '-nostdin',
            '-y',
            '-loglevel', '8',
            '-ar', @rate.to_s,
            '-ac', @channels.to_s,
            '-f', 'f32le',
            '-i', 'pipe:',
            *(codec ? ['-acodec', codec.to_s] : []),
            *(bitrate ? ['-b:a', bitrate.to_s] : []), 
            @filename
          ],
          'w'
        )
        super(pipe, channels)
      end
    end
  end
end
