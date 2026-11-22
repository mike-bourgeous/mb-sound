module MB
  module Sound
    module Sampler
      # Finds SoundFonts by name (drum-gen-1, 2026-11-22; the maintainer:
      # use the apt-installed kits, and on the Mac "Check homebrew first,
      # then copy as needed"): `sf2('Black_Pearl')` is the first font on the
      # search path whose file name is "Black_Pearl" (ignoring case and the
      # .sf2 extension), else the one whose name starts with it; several
      # starting with it raise, naming them.  Each folder is indexed with
      # MB::Sound::MediaIndex (subfolders too; a name found in several
      # subfolders of one folder is reported once, the first in path order
      # playing), and the first folder holding the name wins, as PATH does.
      #
      # The search path (.dirs), in order: $MB_SOUND_SOUNDFONTS (folders
      # separated like PATH), the user's ~/.local/share/sounds/sf2 and
      # ~/.local/share/soundfonts, the system's /usr/local/share/sounds/sf2,
      # /usr/share/sounds/sf2 (where Debian's soundfont packages put them:
      # avldrums.lv2-soundfont, fluid-soundfont-gm, timgm6mb-soundfont,
      # csound-soundfont), /usr/share/soundfonts, Homebrew's share folders
      # on a Mac (/opt/homebrew/share/soundfonts and sounds/sf2,
      # /usr/local/share/soundfonts: Homebrew ships no SoundFont formula or
      # cask in 2026-11, so these hold fonts copied there by hand), and
      # ~/Library/Audio/Sounds/Banks (where macOS apps look).  Folders that
      # don't exist are skipped.
      #
      #     Sampler::FontPath.find('Black_Pearl')   # => "/usr/share/sounds/sf2/Black_Pearl_4_LV2.sf2", or nil
      #     Sampler::FontPath.names                 # => ["Black_Pearl_4_LV2", "FluidR3_GM", ...]
      module FontPath
        # The SoundFont file extensions indexed.
        EXTENSIONS = %w[sf2].freeze

        # The folders searched after $MB_SOUND_SOUNDFONTS, in order.
        DIRS = %w[
          ~/.local/share/sounds/sf2 ~/.local/share/soundfonts
          /usr/local/share/sounds/sf2 /usr/share/sounds/sf2 /usr/share/soundfonts
          /opt/homebrew/share/soundfonts /opt/homebrew/share/sounds/sf2 /usr/local/share/soundfonts
          ~/Library/Audio/Sounds/Banks
        ].freeze

        # Raised for a name that matches several fonts.
        class Ambiguous < ArgumentError; end

        class << self
          # Folders searched instead of the search path when not nil (an
          # Array): spec_helper sets [] so specs never play an installed
          # font, and specs give their own folder of synthetic fonts.
          attr_accessor :only
        end
        self.only = nil

        module_function

        # True if +path+ (a String) is a bare font name to look up: no
        # folder separator.
        def name?(path)
          s = path.to_s
          !s.empty? && !s.include?('/') && !s.include?('\\')
        end

        # The folders searched, in order (existing ones only).
        def dirs
          env = ENV['MB_SOUND_SOUNDFONTS'].to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
          (FontPath.only || (env + DIRS)).filter_map { |d|
            full = File.expand_path(d) rescue next
            full if File.directory?(full)
          }.uniq
        end

        # The path of the font named +name+ (see the module description),
        # or nil.  Raises Ambiguous when several fonts start with it.
        def find(name)
          want = stem(name)
          dirs.each do |dir|
            idx = MediaIndex.for(dir, extensions: EXTENSIONS)
            files = fonts(idx)
            exact = files.select { |f| stem(f) == want }
            return idx.resolve(exact.first, warn: true).path unless exact.empty?

            starts = files.select { |f| stem(f).start_with?(want) }
            names = starts.map { |f| File.basename(f, '.*') }.uniq
            raise Ambiguous, "#{name.inspect} matches #{names.length} SoundFonts in #{dir} (#{names.sort.join(', ')}): name one" if names.length > 1
            return idx.resolve(starts.first, warn: true).path if starts.any?
          end
          nil
        end

        # The names (file names without .sf2) of every font on the search
        # path, the first of each name, sorted.
        def names
          dirs.flat_map { |d| fonts(MediaIndex.for(d, extensions: EXTENSIONS)).map { |f| File.basename(f, '.*') } }.uniq { |n| stem(n) }.sort_by(&:downcase)
        end

        # A message for +name+ when no font has it: the folders searched.
        def missing(name)
          d = dirs
          where = d.empty? ? 'no SoundFont folder exists' : "searched #{d.join(', ')}"
          "no SoundFont named #{name.inspect} (#{where}; MB_SOUND_SOUNDFONTS adds folders#{suggestion(name)})"
        end

        # The lookup form of a font file or name: its base name without the
        # extension, as MediaIndex compares names.
        def stem(name)
          base = File.basename(name.to_s.tr('\\', '/'))
          base = base.sub(/\.sf2\z/i, '')
          MediaIndex.key(base)
        end

        # Every font file of MediaIndex +idx+ (paths, in path order).
        def fonts(idx)
          idx.paths
        end

        def suggestion(name)
          require 'did_you_mean'
          all = names
          s = DidYouMean::SpellChecker.new(dictionary: all).correct(name.to_s).first
          s ? "; did you mean #{s.inspect}?" : ''
        end
      end
    end
  end
end
