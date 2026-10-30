module MB
  module Sound
    module Analysis
      # Musical key detection by the Krumhansl-Schmuckler method: the
      # long-term pitch class profile of a signal (Analysis::Chroma#fold)
      # correlated with a major and a minor key profile rotated to each of
      # the 12 tonics; the best of the 24 is the key.
      #
      #     k = Analysis::Key.detect(chroma.fold)   # or Key.of(audio)
      #     k.key           # => :Am (the Sample#key spelling)
      #     k.correlation   # => 0.87
      #     k.margin        # => 0.08 (over the runner-up)
      #     k.musical_key   # => A minor (a MusicalKey for `key ...`)
      #
      # Profiles (PROFILES): :krumhansl (Krumhansl and Kessler 1982, probe
      # tone ratings; the default) and :temperley (Temperley 2007's
      # Kostka-Payne corpus profile, as music21 has it).  Keys the method
      # often confuses: the relative major and minor (C and Am share their
      # notes) and the keys a fifth away; #margin says how clear the pick
      # was, and #scores lists all 24.
      module Key
        # Key profiles by name: [major, minor], C (or c) first.
        PROFILES = {
          krumhansl: [
            [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
            [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17],
          ],
          temperley: [
            [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
            [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330],
          ],
        }.freeze

        # Tonic spellings: major keys with flats (F, Bb, Eb, Ab, Db) and
        # minor keys with flats (Dm, Gm, Cm, Fm, Bbm, Ebm); the rest sharps
        # (F# major, C#m, G#m), as key signatures are usually written.
        MAJOR_NAMES = %w[C Db D Eb E F F# G Ab A Bb B].freeze
        MINOR_NAMES = %w[C C# D Eb E F F# G G# A Bb B].freeze

        # A key detection: +key+ (a Symbol like :Am, :"F#", :Eb), +tonic+
        # (pitch class 0..11), +mode+ (:major or :minor), +correlation+
        # (Pearson r of the profile and the key's profile), +margin+ (r
        # over the runner-up, which is +next_key+), +scores+ (every key's
        # r, best first, as [key, r] pairs), +profile+ (the PROFILES name),
        # and +chroma+ (the 12 shares read, C first).
        Result = Data.define(:key, :tonic, :mode, :correlation, :margin, :next_key, :scores, :profile, :chroma) do
          # The key as a MusicalKey (for the session key: `key k.tonic, k.mode`).
          def musical_key
            MusicalKey.new(root: tonic, mode: mode, spelling: key.to_s.delete_suffix('m'))
          end

          # The relative key (Am for C, C for Am).
          def relative
            mode == :major ? Key.symbol((tonic + 9) % 12, :minor) : Key.symbol((tonic + 3) % 12, :major)
          end

          # True when the pick is clear enough to call a key: correlation
          # at least +min+ and a margin of at least +margin+ over the
          # runner-up (see MIN_CORRELATION, MIN_MARGIN).
          def clear?(min: MIN_CORRELATION, margin: MIN_MARGIN)
            correlation >= min && self.margin >= margin
          end

          # Words for the pick, e.g. "A minor (r 0.87, next C major 0.79)".
          def to_s
            "#{Key.words(key)} (r #{format('%.2f', correlation)}, next #{Key.words(next_key)} #{format('%.2f', correlation - margin)})"
          end

          def inspect
            "#<Analysis::Key #{self}>"
          end
        end

        # The weakest correlation Result#clear? (and Sample#detect_key)
        # call a key.  Measured (listen-1, 2026-10-30): synthesized I-IV-V-I
        # and i-iv-V-i progressions in all 24 keys 0.83-0.96 (margins
        # 0.10-0.22; a 30-cent detuned one too), a saw Am clip 0.90, the
        # same over an 808 groove 0.89; drum loops alone 0.41 (the jungle
        # break), 0.66 (an 808 groove, its tuned kick and snare: D minor
        # with a 0.26 margin), 0.69 (a 909 groove, margin 0.01), white
        # noise 0.28.
        MIN_CORRELATION = 0.7

        # The smallest margin over the runner-up Result#clear? accepts.
        MIN_MARGIN = 0.02

        # The key Symbol of +tonic+ (pitch class) and +mode+ (:major or
        # :minor): :C, :Am, :"F#", :Ebm.
        def self.symbol(tonic, mode)
          mode == :minor ? :"#{MINOR_NAMES[tonic % 12]}m" : MAJOR_NAMES[tonic % 12].to_sym
        end

        # [tonic pitch class, :major or :minor] of a key Symbol or String
        # (:Am, :"F#", 'Bbm', :"A#m", 'C minor'), so enharmonic spellings
        # compare equal; nil for anything else.
        def self.parse(key)
          s = key.to_s.strip.tr('♯♭', '#b')
          m = s.match(/\A([A-Ga-g])(#|b|s)?\s*(m|min|minor|maj|major|M)?\z/)
          return nil unless m
          pc = MusicalKey.parse_root("#{m[1].upcase}#{m[2]}")[0]
          [pc, %w[m min minor].include?(m[3]) ? :minor : :major]
        end

        # True if keys +a+ and +b+ are the same key, whatever the spelling
        # (:"A#m" and :Bbm).
        def self.same?(a, b)
          pa = parse(a)
          pa && pa == parse(b)
        end

        # "A minor", "F# major" for a key Symbol.
        def self.words(key)
          tonic, mode = parse(key)
          return key.to_s unless tonic
          "#{key.to_s.delete_suffix('m')} #{mode}"
        end

        # Detects the key of a pitch class profile +chroma+ (12 values, C
        # first; an Array or Numo vector) with +profile+ (a PROFILES name
        # or a [major, minor] pair of 12-value Arrays).  Returns a Result.
        def self.detect(chroma, profile: :krumhansl)
          major, minor = profile.is_a?(Symbol) ? PROFILES.fetch(profile) {
            raise ArgumentError, "Unknown key profile #{profile.inspect} (#{PROFILES.keys.map(&:inspect).join(', ')})#{Form.suggest(profile, PROFILES.keys)}"
          } : profile
          c = chroma.to_a.map(&:to_f)
          raise ArgumentError, "A pitch class profile has 12 values (got #{c.length})" unless c.length == 12

          scores = []
          12.times do |t|
            # Rotate the profile so its tonic is pitch class t
            [[major, :major], [minor, :minor]].each do |prof, mode|
              rotated = Array.new(12) { |i| prof[(i - t) % 12] }
              scores << [symbol(t, mode), pearson(c, rotated), t, mode]
            end
          end
          scores.sort_by! { |s| -s[1] }
          best, second = scores[0], scores[1]
          Result.new(key: best[0], tonic: best[2], mode: best[3], correlation: best[1].round(4),
            margin: (best[1] - second[1]).round(4), next_key: second[0],
            scores: scores.map { |k, r, *| [k, r.round(4)].freeze }.freeze,
            profile: profile.is_a?(Symbol) ? profile : :custom, chroma: c.map { |v| v.round(5) }.freeze)
        end

        # Detects the key of audio +data+ (a Numo array, an Array of
        # channels, or a Chroma); +options+ go to Chroma.new.
        def self.of(data, sample_rate: 48000, profile: :krumhansl, **options)
          chroma = data.is_a?(Chroma) ? data : Chroma.new(data, sample_rate: sample_rate, **options)
          detect(chroma.fold, profile: profile)
        end

        # Pearson correlation of two equal-length Arrays (0 if either is
        # constant).
        def self.pearson(a, b)
          n = a.length
          ma = a.sum / n
          mb = b.sum / n
          num = sa = sb = 0.0
          n.times do |i|
            x = a[i] - ma
            y = b[i] - mb
            num += x * y
            sa += x * x
            sb += y * y
          end
          sa > 0 && sb > 0 ? num / Math.sqrt(sa * sb) : 0.0
        end
      end
    end
  end
end
