module MB
  module Sound
    module Generative
      # Generators following the session key live (gen-ux-1; the
      # maintainer, 2026-11-17: "explicit source, implicit source if none
      # specified, rootless scale follows, chord progression"): a source
      # that follows the key is read again for every cycle, so `key :a, at:
      # 8.bars` moves a running motifs, melody, or strikes.
      #
      # What follows the key:
      # - Scales made without a root: `scale(:phrygian)` (or `scale(:phrygian,
      #   :key)`) keeps its mode on the session key's root; bare `scale` (or
      #   `scale(:key)`) is the session key itself, root and mode
      #   (Scale#following).
      # - Values built from those (`scale(:dorian).weights.blur(0.1) +
      #   tones(D3, F3)`, `harmony(0 => scale(:minor), ...)`, `.over(...)`):
      #   their recipe (Generative::Value) is played again with the key's
      #   scales, so every operator applies to the key in effect.
      # - Progressions (`progression(1, 6, 3, 7)`), chords on degrees of the
      #   key's scale (Progression).
      # - Nothing: a generator given no source follows the session key's
      #   scale (`motifs(8)`, `melody(vary: true)`).
      #
      # Generators read the key once per cycle as a steered option (Steer,
      # through a KeyFollow::Param): at the cycle's decision point, for the
      # cycle's start, counting key changes already queued to land by then
      # (Session#planned_key_at: `key :a, at: bar(9)`, scheduled blocks,
      # scene launches), so a cycle starting on a key change plays in the
      # new key; a key typed during the last beat before a cycle lands from
      # the next one, as a knob turn would.
      module KeyFollow
        module_function

        # True if +x+ follows the session key (see the module description).
        def follows?(x)
          case x
          when Scale then x.follows_key?
          when Progression then x.follows_key?
          when Value
            r = x.recipe or return false
            follows?(r[0]) || r[2].any? { |a| arg_follows?(a) } || r[3].each_value.any? { |a| arg_follows?(a) }
          else false
          end
        end

        def arg_follows?(a)
          case a
          when Hash then a.any? { |k, v| follows?(k) || follows?(v) }
          when Array then a.any? { |v| follows?(v) }
          else follows?(a)
          end
        end

        # The Scale a generator given no source follows: the session key,
        # root and mode (as bare `scale`).
        def implicit
          MB::Sound.scale
        end

        # +x+ for MusicalKey +key+: following Scales on the key, values made
        # from them rebuilt from their recipes (cached per value and key),
        # Progressions as their Harmony; anything else as it is.
        def resolve(x, key)
          case x
          when Scale then x.follows_key? ? x.at_key(key) : x
          when Progression then x.harmony(key)
          when Value
            return x unless follows?(x)
            cache = (CACHE_LOCK.synchronize { CACHE[x] ||= {} })
            CACHE_LOCK.synchronize { cache[key] } || begin
              v = rebuild(x, key)
              CACHE_LOCK.synchronize {
                cache.shift while cache.length >= 64
                cache[key] ||= v
              }
            end
          else x
          end
        end

        # +x+'s recipe played again with its parts resolved for +key+.
        def rebuild(x, key)
          receiver, name, args, kwargs = x.recipe
          args = args.map { |a| resolve_arg(a, key) }
          kwargs = kwargs.transform_values { |a| resolve_arg(a, key) }
          return MB::Sound.public_send(name, *args, **kwargs) if receiver.nil?
          resolve(receiver, key).public_send(name, *args, **kwargs)
        end

        def resolve_arg(a, key)
          case a
          when Hash then a.to_h { |k, v| [resolve(k, key), resolve(v, key)] }
          when Array then a.map { |v| resolve(v, key) }
          else resolve(a, key)
          end
        end

        # The session key at timeline position +pos+: the rendering (or
        # current) Session's, counting key changes queued to land by then,
        # else +transport+'s (or the current transport's).
        def key_at(pos, transport = nil)
          session = Session.span&.session || Session.existing
          return session.planned_key_at(pos) if session
          (transport || Sequence.current_transport).key_at(pos)
        end

        # Resolved values by source value and key (weak keys, so values
        # nobody holds are dropped).
        CACHE = ObjectSpace::WeakMap.new
        CACHE_LOCK = Mutex.new

        # The steered option (see Steer) a generator reads its following
        # source through: the source resolved for the session key at the
        # cycle's start (#cycle_start?).
        class Param < MIDI::Param::Base
          # The source value (a following Scale, Progression, or value).
          attr_reader :source

          def initialize(source)
            @recipe = nil
            @source = source
          end

          # The source resolved for the key at timeline position +pos+.
          def value_at(pos, frame: nil, transport: nil, stream: nil)
            KeyFollow.resolve(@source, KeyFollow.key_at(pos, transport))
          end

          # True: Steer reads it for the cycle's start, not the decision
          # point.
          def cycle_start?
            true
          end

          def to_ruby(&value_text)
            value_text ? value_text.call(@source) : RubyValue.to_ruby(@source)
          end
        end

        # A chord progression on degrees of a scale (the session key's by
        # default): MB::Sound#progression.  #harmony gives the Harmony for a
        # key: each chord a keyframe of the scale's notes plus the chord's
        # tones at +weight+, held until the next (+curve:+ :step) and
        # looping, so generators re-voice into each chord as it comes.
        class Progression
          include Value

          # Roman numerals for degrees 1 to 7.
          ROMAN = %w[i ii iii iv v vi vii].freeze

          # The chords as [degree (from 1), length (whole notes)].
          attr_reader :chords

          # The scale (a Scale; following the key unless it has a root).
          attr_reader :scale

          # The chord-tone weight over the scale notes.
          attr_reader :weight

          # The loop length in whole notes.
          attr_reader :length

          def initialize(chords, every:, scale:, weight:, curve:)
            @recipe = nil
            raise ArgumentError, 'progression needs chords: progression(1, 6, 3, 7) or progression(:i, :VI, :III, :VII)' if chords.empty?
            raise ArgumentError, "progression's scale: is a Scale (scale(:minor) follows the key's root; got #{scale.inspect})" unless scale.is_a?(Scale)
            raise ArgumentError, "progression's weight: is a positive number (got #{weight.inspect})" unless weight.is_a?(Numeric) && weight.real? && weight > 0
            default = Progression.length(every, 'every:')
            @chords = chords.map { |c|
              degree, len = c.is_a?(Array) ? c : [c, nil]
              raise ArgumentError, "A progression chord with a length is [degree, length], like [1, 2.bars] (got #{c.inspect})" if c.is_a?(Array) && c.length != 2
              [Progression.degree(degree), len.nil? ? default : Progression.length(len, 'chord lengths')].freeze
            }.freeze
            @scale = scale
            @weight = weight
            @curve = curve
            @length = @chords.sum(&:last)
            @harmonies = {}
            @mutex = Mutex.new
          end

          # True unless the progression's scale has its own root.
          def follows_key?
            @scale.follows_key?
          end

          # The Harmony of this progression in MusicalKey +key+ (nil: the
          # scale as it is, for a fixed scale or a snapshot).
          def harmony(key = nil)
            sc = key && follows_key? ? @scale.at_key(key) : @scale
            @mutex.synchronize { @harmonies[sc] } || begin
              base = sc.weights
              pos = 0r
              frames = @chords.to_h { |degree, len|
                w = base + Weights.tones(*sc.chord(degree - 1)) * @weight
                at = pos
                pos += len
                [at.zero? ? 0 : Sequence::Duration.new(at), w]
              }
              h = Harmony.new(frames, curve: @curve, loop: Sequence::Duration.new(@length))
              @mutex.synchronize {
                @harmonies.shift while @harmonies.length >= 64
                @harmonies[sc] ||= h
              }
            end
          end

          # The progression spread over +range+ (a FieldTimeline, as
          # Harmony#over), following the key as the progression does
          # (`strikes(chords.over(A2..A3))`).
          def over(range, around: nil, width: nil)
            FieldTimeline.new(harmony, range, around: around, width: width).with_recipe(self, :over, [range], { around: around, width: width }.compact)
          end

          # The degree (1 to 7, or more for larger scales) of +x+: an
          # Integer from 1, or a Roman numeral Symbol or String (:i, :VI;
          # case is ignored: chords are the scale's own).
          def self.degree(x)
            case x
            when Integer
              raise ArgumentError, "Progression degrees count from 1 like Roman numerals (got #{x}; 1 is the tonic chord)" unless x >= 1
              x
            when Symbol, String
              i = ROMAN.index(x.to_s.downcase)
              raise ArgumentError, "#{x.inspect} isn't a Roman numeral (i to vii; :i, :IV, :vi) or a degree from 1" unless i
              i + 1
            else
              raise ArgumentError, "A progression chord is a degree from 1, a Roman numeral (:i, :VI), or [degree, length] (got #{x.inspect})"
            end
          end

          # +x+ (a length like 1.bar or 2.beats) in whole notes.
          def self.length(x, what)
            raise ArgumentError, "progression's #{what} are lengths like 1.bar or 2.beats (got #{x.inspect})" unless x.is_a?(Sequence::Duration)
            x.check_length("progression's #{what}").whole_notes.tap { |w|
              raise ArgumentError, "progression's #{what} must be positive (got #{x})" unless w > 0
            }
          end

          def plain_ruby(_value_text)
            'progression(...)'
          end

          def to_s
            to_ruby
          end

          def inspect
            "#<Progression #{self}>"
          end
        end
      end

      # A Progression is a probability scale wherever one is taken: as
      # itself, its Harmony in the scale it was given.
      Progression = KeyFollow::Progression
    end
  end
end
