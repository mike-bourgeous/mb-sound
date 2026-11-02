module MB
  module Sound
    module Tracker
      # The per-tick effect math of the trackers' pitch effects (tracker-2),
      # as small units that each keep their own state and turn it into one
      # tick's value, so they can be tested alone (spec/lib/mb/sound/tracker/
      # effects_spec.rb) and wrapped by a general effect framework later.
      # Tracker::Player's formats hold them per channel and apply the values
      # in their own period units.
      #
      # The behavior of each unit follows the formats' documentation and
      # measurements of openmpt123's output on synthetic one-note modules
      # (the reference player is run as an outside program only; see
      # design/notes/trackers.md, Pitch).
      module Effects
        # Vibrato and tremolo waveforms: a +table+ of 64 values per cycle,
        # positive where the effect raises the period (lowers the pitch).
        #
        # - :protracker (MOD, XM): ProTracker's half sine of 32 steps
        #   (0..255) and its negative, a ramp from 0 rising to 248 and
        #   wrapping to -256 halfway (pitch falling), a square of 256 / -256
        #   (measured: a depth 8 square swings 16 periods).
        # - :st3 (S3M): the same sine and square, the ramp mirrored (pitch
        #   rising first).
        # - :it (IT, without old effects): a 64-step sine of 0..64 starting
        #   with the pitch going up, a ramp from the highest pitch down, and
        #   a square that is up for half the cycle and 0 for the other half.
        #   Measured from openmpt123 at speed 1 (one step a tick): offsets
        #   are 1/64 semitone steps of (value * depth) >> 4.
        #
        # Waveform 3 (random) plays as the sine (counted as unsupported by
        # the players that see it).
        module Waveform
          PT_SINE = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
                     255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24].freeze

          # IT's quarter sine (17 values, 0..64; the rest by symmetry),
          # consistent with every tick measured at depths 8 and 15.
          IT_QUARTER = [0, 6, 12, 19, 24, 30, 36, 41, 45, 49, 53, 56, 59, 61, 62, 64, 64].freeze

          TABLES = {
            protracker: [
              Array.new(64) { |p| p < 32 ? PT_SINE[p] : -PT_SINE[p - 32] },
              Array.new(64) { |p| p < 32 ? p * 8 : p * 8 - 512 },
              Array.new(64) { |p| p < 32 ? 256 : -256 },
            ],
            st3: [
              Array.new(64) { |p| p < 32 ? PT_SINE[p] : -PT_SINE[p - 32] },
              Array.new(64) { |p| p < 32 ? -p * 8 : 512 - p * 8 },
              Array.new(64) { |p| p < 32 ? 255 : -255 },
            ],
            it: [
              Array.new(64) { |p|
                q = p & 31
                v = IT_QUARTER[q <= 16 ? q : 32 - q]
                p < 32 ? -v : v
              },
              Array.new(64) { |p| 2 * p - 64 },
              Array.new(64) { |p| p < 32 ? -64 : 0 },
            ],
          }.transform_values { |t| t.map(&:freeze).freeze }.freeze

          module_function

          # The +kind+'s value of waveform +wave+ (0 sine, 1 ramp, 2 square,
          # 3 random as the sine; 4-7 the same without retriggering) at
          # +pos+ (0..63).
          def value(kind, wave, pos)
            w = wave & 3
            TABLES.fetch(kind)[w == 3 ? 0 : w][pos & 63]
          end
        end

        # A vibrato (or tremolo) oscillator: its waveform position and
        # waveform, retriggered by notes, read and advanced per tick by
        # #tick under a format's +timing+:
        #
        # - :protracker: nothing on a row's first tick (the period goes
        #   back to the note's), then read and advance.
        # - :fasttracker (XM, multichannel MODs, S3M): the first tick reads
        #   without advancing, later ticks read and advance.
        # - :impulse (IT): every tick, the first included, advances and
        #   reads.
        class Oscillator
          attr_accessor :pos, :wave
          attr_reader :kind, :timing

          TIMINGS = %i[protracker fasttracker impulse].freeze

          def initialize(kind: :protracker, timing: :protracker)
            raise ArgumentError, "timing: is one of #{TIMINGS.inspect} (got #{timing.inspect})" unless TIMINGS.include?(timing)
            Waveform::TABLES.fetch(kind)
            @kind = kind
            @timing = timing
            @pos = 0
            @wave = 0
          end

          # A new note: back to the cycle's start unless the waveform says
          # not to retrigger (4-7).
          def retrigger
            @pos = 0 if @wave < 4
          end

          # The waveform's value for tick +t+ of a row at +speed+ (position
          # steps a tick), or nil on ticks the effect leaves alone.
          def tick(t, speed)
            case @timing
            when :protracker
              return nil if t == 0
              v = value
              @pos = (@pos + speed) & 63
              v
            when :fasttracker
              v = value
              @pos = (@pos + speed) & 63 if t > 0
              v
            else
              @pos = (@pos + speed) & 63
              value
            end
          end

          # The waveform's value at the current position.
          def value
            Waveform.value(@kind, @wave, @pos)
          end
        end

        # Arpeggio (0xy / Jxy): the semitones above the note on tick +t+:
        # 0, then +x+, then +y+.  FastTracker 2 (+order: :fasttracker+)
        # counts its ticks down from the row's +speed+, so at speed 6 it
        # plays 0, y, x, 0, y, x.
        module Arpeggio
          module_function

          def semitones(param, t, speed: 6, order: :protracker)
            k = order == :fasttracker ? (speed - t) % 3 : t % 3
            case k
            when 0 then 0
            when 1 then param >> 4
            else param & 15
            end
          end
        end

        # Slides of a period (or any value) by steps.
        module Slide
          module_function

          # +value+ moved by +step+ toward +target+, stopping there (tone
          # portamento).
          def toward(value, target, step)
            value < target ? [value + step, target].min : [value - step, target].max
          end

          # +value+ plus +amount+, kept in +limits+ ([low, high], or nil for
          # none; then above +floor+, so a period never reaches 0).
          def by(value, amount, limits, floor: 1)
            v = value + amount
            limits ? v.clamp(*limits) : [v, floor].max
          end
        end

        # IT's linear slides by +units+ of 1/64 semitone, as its tables
        # step them: units below 16 exactly (its fine table), larger ones in
        # whole 1/16 semitones (truncated toward zero; its coarse table).
        # Measured on vibrato offsets from openmpt123.
        def self.it_linear_units(units)
          a = units.abs
          q = a < 16 ? a : a & ~3
          units < 0 ? -q : q
        end
      end
    end
  end
end
