require 'digest'
require 'fileutils'

module MB
  module Sound
    module GraphIO
      # The files a bundle document needs (graph-io phase 3): wavetables
      # and samples, MIDI files, and sound files, kept in the bundle's
      # assets/ directory and named relative to the document
      # (`Wavetable["assets/pad.flac"]`, `midi_file("assets/groove.mid")`).
      #
      # A bundle is a directory `name.mbg/` holding `name.mbg.rb` and
      # `assets/`.  GraphIO.save makes one when the graph needs files (or
      # with bundle: true); the document lists each asset with its SHA-256
      # (`asset "assets/pad.flac", sha256: "..."`), checked when the file is
      # read.
      #
      # The RubyWriter asks an Assets for the name of each table that isn't
      # a library table (#wavetable) and of each String that names an
      # existing sound or MIDI file (#file).  Planning only names the files;
      # #write copies or saves them.
      class Assets
        # The bundle subdirectory for assets.
        DIR = 'assets'

        # File name extensions of Strings taken for file names (sound and
        # MIDI files).
        EXTENSIONS = %w[.flac .wav .wave .aif .aiff .ogg .oga .opus .mp3 .m4a .caf .mid .midi .smf].freeze

        # The source file of a table read with Wavetable.from_file and no
        # options (FileGuard notes it on the table), which a bundle copies
        # as it is; nil for other tables.
        def self.table_file(table)
          table.instance_variable_defined?(:@graph_io_file) ? table.instance_variable_get(:@graph_io_file) : nil
        end

        # One planned asset: its +name+ in the bundle (assets/x.flac), and a
        # +source+ file to copy or a +table+ to save.
        Entry = Struct.new(:name, :source, :table, :sha256)

        attr_reader :entries

        def initialize
          @entries = []
          @by_source = {}
          @by_table = {}.compare_by_identity
          @names = {}
        end

        # True if nothing was asked for.
        def empty?
          @entries.empty?
        end

        # The bundle name for String +string+ if it names an existing sound
        # or MIDI file (relative to the working directory, or to the
        # document it came from), else nil.
        def file(string)
          return nil unless EXTENSIONS.include?(File.extname(string).downcase)
          path = source_path(string)
          return nil unless path && File.file?(path)
          real = File.realpath(path)
          @by_source[real] ||= add(Entry.new(unique(File.basename(real)), real, nil))
          @by_source[real].name
        end

        # The bundle name for +table+ (a Wavetable that isn't a library
        # table): its source file when it was read from one without
        # options, else a FLAC written by Wavetable#save (frames and the
        # tags that rebuild it; within -130 dB of the original).
        def wavetable(table)
          src = Assets.table_file(table)
          if src && File.file?(src)
            real = File.realpath(src)
            return(@by_source[real] ||= add(Entry.new(unique(File.basename(real)), real, nil))).name
          end
          @by_table[table] ||= add(Entry.new(unique("#{table_basename(table)}.flac"), nil, table))
          @by_table[table].name
        end

        # The bundle name for Sample +sample+ (one without a lineage): its
        # source file when it was read from one without options, else a FLAC
        # written by Sample#save (the audio and the settings as tags).
        def sample(sample)
          src = sample.file
          if src && File.file?(src)
            real = File.realpath(src)
            return(@by_source[real] ||= add(Entry.new(unique(File.basename(real)), real, nil))).name
          end
          base = sample.name.to_s.sub(/\.[A-Za-z0-9]+\z/, '')
          @by_table[sample] ||= add(Entry.new(unique("#{base.empty? ? 'sample' : base}.flac"), nil, sample))
          @by_table[sample].name
        end

        # Copies and saves the assets into bundle directory +dir+.  Returns
        # the entries with their SHA-256 sums.
        def write(dir)
          FileUtils.mkdir_p(File.join(dir, DIR))
          @entries.each do |e|
            out = File.join(dir, e.name)
            if e.source
              FileUtils.cp(e.source, out)
            else
              e.table.save(out, overwrite: true)
            end
            e.sha256 = Digest::SHA256.file(out).hexdigest
          end
          @entries
        end

        private

        def add(entry)
          @entries << entry
          entry
        end

        # assets/<base>, with a number added if the name is taken.
        def unique(base)
          base = base.gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A[.]+/, '')
          base = 'asset' if base.empty?
          stem = File.basename(base, '.*')
          ext = File.extname(base)
          name = base
          i = 2
          while @names.key?(name)
            name = "#{stem}_#{i}#{ext}"
            i += 1
          end
          @names[name] = true
          "#{DIR}/#{name}"
        end

        def table_basename(table)
          n = table.name.to_s.sub(/\.[A-Za-z0-9]+\z/, '')
          n.empty? ? 'wavetable' : n
        end

        # Where +string+ points: inside its document's directory for a
        # String read from a document, else from the working directory.
        def source_path(string)
          if FileGuard.document_string?(string)
            FileGuard.resolve(string)
          else
            File.expand_path(string)
          end
        rescue GraphIO::LoadError
          nil
        end
      end
    end
  end
end
