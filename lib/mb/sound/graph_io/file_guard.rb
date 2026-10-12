module MB
  module Sound
    module GraphIO
      # A file name from a graph document that breaks the file rules (an
      # absolute path, a `..` escape, a file outside the document's
      # directory, or a document without a directory).  The loader adds the
      # line.
      class FileError < LoadError; end

      # Keeps graph documents' file reads inside the document's directory,
      # whichever library method a file name reaches.
      #
      # The loader marks every String it makes from document text with the
      # document's Context (GraphIO::FileGuard.register; an instance
      # variable set before the string is frozen, which copies keep; a
      # WeakMap loses it: it holds its values weakly too, so a context
      # was collected once its loader was gone).  The library's lowest
      # file readers (Wavetable.from_file, FFMPEGInput (file_input,
      # MB::Sound.read), and MIDI::MIDIFile) pass their file names through .resolve, which
      # leaves names from anywhere else alone and turns a document's names
      # into paths inside its directory, or raises FileError.  So
      # `Wavetable['/etc/passwd']`, `440.hz.wavetable('../x.flac')`,
      # `phase_table`, `waveshape`, KeyMap zones, `Notes.new('x.mid')`, and
      # any later method that reads a file named by a document follow the
      # same rule as file_input and midi_file, including reads that happen
      # after the load.
      module FileGuard
        # Where a document's file names point: its directory (nil for text
        # loaded without base_dir:) and a label for messages.
        Context = Struct.new(:base_dir, :label, :assets)

        class << self
          # Marks +string+ (not frozen yet) as text of a document read in
          # +context+, and freezes it.  Returns the string.
          def register(string, context)
            string.instance_variable_set(:@graph_io_file_context, context)
            string.freeze
          end

          # True if +string+ came from a document.
          def document_string?(string)
            string.is_a?(String) && string.instance_variable_defined?(:@graph_io_file_context)
          end

          # +path+ unchanged unless it is a String from a document; then the
          # absolute path of the file inside the document's directory, after
          # checking the rules (see FileError).  +what+ names the reader for
          # messages.
          def resolve(path, what = 'reading a file')
            return path unless document_string?(path)

            check(path, path.instance_variable_get(:@graph_io_file_context), what)
          end

          # Checks +name+ (a file name from a document read in +ctx+) and
          # returns its absolute path.
          def check(name, ctx, what)
            unless ctx.base_dir
              raise FileError.new("#{what} (#{name.inspect}): only documents loaded from a file (or with base_dir:) may read files")
            end
            if name.start_with?('/', '~') || name.split(%r{[/\\]}).include?('..') || name.match?(/\A[a-zA-Z]:/) || name.include?("\0") || name.empty?
              raise FileError.new("#{what} (#{name.inspect}): files must be named relative to the document, inside its directory")
            end

            full = File.join(ctx.base_dir, name)
            if File.exist?(full)
              # Symbolic links may not lead outside the document's directory
              base = File.realpath(ctx.base_dir)
              real = File.realpath(full)
              unless real.start_with?(base + File::SEPARATOR)
                raise FileError.new("#{what} (#{name.inspect}): the file is a link to outside the document's directory")
              end
              ctx.assets&.verify(name, real)
            end
            full
          end
        end

        # Wavetable.from_file
        module WavetableFile
          def from_file(path, **kwargs)
            resolved = FileGuard.resolve(path, 'Wavetable.from_file')
            super(resolved, **kwargs).tap { |t|
              # Bundles copy the files of tables read with no options
              if kwargs.empty? && (resolved.is_a?(String) || resolved.is_a?(Pathname)) && !t.frozen?
                t.instance_variable_set(:@graph_io_file, File.expand_path(resolved.to_s))
              end
            }
          end
        end

        # FFMPEGInput (MB::Sound.file_input, MB::Sound.read)
        module SoundFile
          def initialize(filename, *args, **kwargs, &block)
            super(FileGuard.resolve(filename, 'reading a sound file'), *args, **kwargs, &block)
          end
        end

        # MIDI::MIDIFile.new (midi_file, Notes.new('x.mid'), MIDI streams)
        module MidiFile
          def initialize(filename, **kwargs)
            super(FileGuard.resolve(filename, 'reading a MIDI file'), **kwargs)
          end
        end

        MB::Sound::Wavetable.singleton_class.prepend(WavetableFile)
        MB::Sound::FFMPEGInput.prepend(SoundFile)
        MB::Sound::MIDI::MIDIFile.prepend(MidiFile)
      end
    end
  end
end
