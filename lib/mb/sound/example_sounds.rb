module MB
  module Sound
    # The example sounds the README and help pages name (`sounds/drums.flac`,
    # `sounds/synth0.flac`, ...) ship in mb-sound's own sounds/ folder.  A
    # relative file name under sounds/ that isn't a file in the working
    # directory reads mb-sound's copy, so the examples work from any
    # directory, as after `gem install` (design/notes/release.md).  A file
    # of that name in the working directory still wins, and names from graph
    # documents keep their document's rules (GraphIO::FileGuard).
    module ExampleSounds
      # mb-sound's example sounds.
      DIR = File.join(Internal::GEM_ROOT, 'sounds').freeze

      # +path+ itself, or mb-sound's copy of a missing relative
      # `sounds/...` file.
      def self.resolve(path)
        return path unless path.is_a?(String) && path.start_with?('sounds/')
        return path if defined?(GraphIO::FileGuard) && GraphIO::FileGuard.document_string?(path)
        return path if File.exist?(path) || path.split('/').include?('..')

        shipped = File.join(DIR, path.delete_prefix('sounds/'))
        File.file?(shipped) ? shipped : path
      end

      # FFMPEGInput (file_input, MB::Sound.read, Samples, play 'file')
      module SoundFile
        def initialize(filename, *args, **kwargs, &block)
          super(ExampleSounds.resolve(filename), *args, **kwargs, &block)
        end
      end

      MB::Sound::FFMPEGInput.prepend(SoundFile)
    end
  end
end
