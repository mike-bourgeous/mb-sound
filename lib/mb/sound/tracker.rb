module MB
  module Sound
    # Tracker modules (MOD, 669, S3M, XM, IT) as mb-sound sets (tracker-1;
    # design/notes/trackers.md): pure-Ruby readers turn each format into a
    # format-neutral Song (samples, instruments, patterns of cells, the
    # order list, speed and tempo); Tracker::Player steps the song tick by
    # tick like a tracker's replay routine, working out every channel's
    # sample, pitch, volume, and pan; Tracker::Import turns that into a
    # set: a track per channel playing a Sampler::Instrument of the
    # module's samples, a clip per pattern visit per channel (notes with
    # pitch marks, plus bend, volume, and pan lanes at tick resolution), a
    # scene per pattern visit, and a flow with a section per order entry.
    #
    #     song = mod_import('tune.mod')      # a Tracker::Set
    #     play song                          # the whole song
    #     song.setup; go :p03                # one pattern as a scene
    module Tracker
      # Ticks per whole note: a tick is 1/96 of a whole note, so the
      # session tempo in BPM is the module's tempo (a tick lasts 2.5 /
      # tempo seconds) and rows of speed 6 are sixteenths.
      TICKS_PER_WHOLE = 96

      # Formats and their readers, in detection order.
      READERS = {}

      # The longest file read (bytes).
      MAX_BYTES = 64 * 1024 * 1024

      module_function

      # Reads the module at +path+ (or binary +bytes+) into a Song, finding
      # the format from the file's signature.  Paths in graph documents go
      # through GraphIO::FileGuard.
      def read(path = nil, bytes: nil, name: nil)
        raise ArgumentError, 'Give a module path or bytes:' if path.nil? && bytes.nil?
        if bytes.nil?
          real = defined?(GraphIO::FileGuard) ? GraphIO::FileGuard.resolve(path, 'reading a tracker module') : path
          raise ArgumentError, "No module file #{path.inspect}" unless File.file?(real)
          size = File.size(real)
          raise FormatError, "#{File.basename(path)} is #{size} bytes (modules up to #{MAX_BYTES} are read)" if size > MAX_BYTES
          bytes = File.binread(real)
        end
        name ||= path ? File.basename(path.to_s) : 'module'
        format = detect(bytes, name: name)
        READERS.fetch(format).read(bytes, name: name)
      end

      # File name extensions of modules (also Amiga "mod.name" files).
      EXTENSIONS = %w[.mod .669 .s3m .xm .it].freeze

      # True if +path+ (a String) names a module file by its extension
      # (or an Amiga-style "mod." prefix) and exists: `play 'tune.mod'`
      # and `render 'x.flac', 'tune.xm'` import it (see TrackerMethods).
      def module_file?(path)
        return false unless path.is_a?(String)
        base = File.basename(path).downcase
        (EXTENSIONS.include?(File.extname(base)) || base.start_with?('mod.')) && File.file?(path)
      end

      # The format of +bytes+ (:it, :xm, :s3m, :"669", :mod), or raises
      # FormatError.
      def detect(bytes, name: 'module')
        found = READERS.find { |_, r| r.match?(bytes) }
        return found[0] if found
        raise FormatError, "#{name}: not a module this reader knows (#{READERS.keys.join(', ')}; 15-sample SoundTracker MODs aren't read)"
      end
    end
  end
end

require_relative 'tracker/song'
require_relative 'tracker/binary'
require_relative 'tracker/mod_reader'
require_relative 'tracker/six_six_nine_reader'
require_relative 'tracker/s3m_reader'
require_relative 'tracker/xm_reader'
require_relative 'tracker/it_reader'
require_relative 'tracker/player'
require_relative 'tracker/import'
require_relative 'tracker/set'

MB::Sound::Tracker::READERS[:it] = MB::Sound::Tracker::ITReader
MB::Sound::Tracker::READERS[:xm] = MB::Sound::Tracker::XMReader
MB::Sound::Tracker::READERS[:s3m] = MB::Sound::Tracker::S3MReader
MB::Sound::Tracker::READERS[:"669"] = MB::Sound::Tracker::SixSixNineReader
MB::Sound::Tracker::READERS[:mod] = MB::Sound::Tracker::ModReader
