module MB
  module Sound
    module Sequence
      # Parses step-sequencer strings (e.g. 'x...x...') into Seqs.  One
      # character is one step.  See MB::Sound#grid.
      #
      # Characters are looked up in SYMBOLS; add new ones with Grid.register.
      module Grid
        # General MIDI drum note numbers, for naming grid rows.
        GM_DRUMS = {
          kick: 36, bass_drum: 36,
          rimshot: 37, side_stick: 37,
          snare: 38, clap: 39, electric_snare: 40,
          low_floor_tom: 41, closed_hat: 42, hat: 42, high_floor_tom: 43,
          pedal_hat: 44, low_tom: 45, open_hat: 46, low_mid_tom: 47,
          mid_tom: 47, high_mid_tom: 48, crash: 49, high_tom: 50, ride: 51,
          china: 52, ride_bell: 53, tambourine: 54, splash: 55, cowbell: 56,
          crash2: 57, ride2: 59, high_bongo: 60, low_bongo: 61, shaker: 70,
          maracas: 70, claves: 75,
        }.freeze

        # Step characters.  Values are a Hash of Seq::Step attributes for a
        # hit (merged over the defaults), :rest for an empty step, or :ignore
        # for characters that don't take up a step (for readability).
        SYMBOLS = {
          'x' => {},
          'X' => { velocity: Clip::ACCENT_VELOCITY },
          '?' => { probability: 0.5 },
          '.' => :rest,
          '|' => :ignore,
          ' ' => :ignore,
        }
        (1..9).each { |d| SYMBOLS[d.to_s] = { velocity: d / 9.0 } }

        # Adds or replaces a grid character.  +attrs+ is a Hash of Seq::Step
        # attributes (e.g. `{ velocity: 0.3 }`), :rest, or :ignore.
        def self.register(char, attrs)
          raise ArgumentError, 'Grid symbols must be a single character' unless char.is_a?(String) && char.length == 1
          SYMBOLS[char] = attrs
        end

        # Parses a grid +pattern+ String with steps of 1/+division+ whole
        # notes into a Seq whose hits have the given +value+ (e.g. a MIDI drum
        # note).
        def self.parse(division, pattern, value: GM_DRUMS[:kick], seed: 0)
          length = Duration.whole_notes(division)

          steps = pattern.each_char.filter_map { |c|
            attrs = SYMBOLS.fetch(c) {
              raise ArgumentError, "Unknown grid character #{c.inspect} in #{pattern.inspect} (known: #{SYMBOLS.keys.join})"
            }

            case attrs
            when :ignore
              nil
            when :rest
              Seq::Step.new(length: length)
            else
              Seq::Step.new(value: value, length: length, velocity: Clip::DEFAULT_VELOCITY, **attrs)
            end
          }

          Seq.new(steps, seed: seed)
        end

        # Returns the note number for a grid row name: a GM_DRUMS Symbol, a
        # Note, or a Numeric.
        def self.row_value(name, map = {})
          v = map.fetch(name) { name.is_a?(Symbol) ? GM_DRUMS[name] : name }
          v = v.number if v.is_a?(MB::Sound::Note)
          raise ArgumentError, "Unknown grid row #{name.inspect}; use a GM drum name (#{GM_DRUMS.keys.first(6).join(', ')}, ...), a Note, a number, or map: {}" unless v.is_a?(Numeric)
          v
        end
      end

      # Named grid rows returned by MB::Sound#grid, e.g. a drum pattern.  Each
      # row is a Seq, and rows can have different lengths (if looped, each
      # row loops on its own for polymeter).
      #
      # Example (bin/sound.rb):
      #     beat = grid(16, kick: 'x...x...', hat: 'x.x.X.x.').loop
      #     play 50.hz.sine.forever * beat[:kick].env(0, 0.2, 0, 0.05) + noise.filter(:highpass, cutoff: 8000) * beat[:hat].env(0, 0.03, 0, 0.02)
      class Kit
        include Enumerable

        # The row clips, keyed by name.
        attr_reader :rows

        def initialize(rows)
          @rows = rows.freeze
        end

        # Returns the Clip for the row with the given +name+.
        def [](name)
          @rows.fetch(name) { raise KeyError, "No row #{name.inspect} (rows: #{@rows.keys.map(&:inspect).join(', ')})" }
        end

        # Yields each name and row Clip.
        def each(&block)
          @rows.each(&block)
        end

        # Returns a Kit with every row looping independently.
        def loop(seed: nil)
          Kit.new(@rows.transform_values { |c| seed ? c.loop(seed: seed) : c.loop })
        end

        # Returns a Kit with every row's notes shortened (see Clip#legato).
        def legato(fraction)
          Kit.new(@rows.transform_values { |c| c.legato(fraction) })
        end

        # Returns a single Clip with all rows stacked (see Clip#&).
        def to_clip
          @rows.values.reduce(:&)
        end

        def to_s
          "Kit(#{@rows.map { |k, v| "#{k.inspect} => #{v}" }.join(', ')})"
        end

        def inspect
          "#<#{to_s}>"
        end
      end
    end
  end
end
