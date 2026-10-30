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
          crash2: 57, ride2: 59, high_bongo: 60, low_bongo: 61, mute_high_conga: 62,
          open_high_conga: 63, low_conga: 64, cabasa: 69, shaker: 70,
          maracas: 70, claves: 75,
        }.freeze

        # More row names: drum machine voices and short names, with the GM
        # notes they play (see MB::Sound::Drums::TR808::GM_MAP).
        ROW_ALIASES = {
          bd: 36, sd: 38, rim: 37, cp: 39, ch: 42, hh: 42, oh: 46, cb: 56, cy: 49, cymbal: 49,
          lt: 45, mt: 47, ht: 50, conga: 63, high_conga: 62, mid_conga: 63,
          lc: 64, mc: 63, hc: 62, clave: 75,
        }.freeze

        # Step characters.  Values are a Hash of Seq::Step attributes for a
        # hit (merged over the defaults), :rest for an empty step, :tie for a
        # step that holds the previous hit (MB::Sound::Tie), or :ignore
        # for characters that don't take up a step (for readability).
        SYMBOLS = {
          'x' => {},
          'X' => { velocity: Clip::ACCENT_VELOCITY, accented: true },
          '-' => :tie,
          '?' => { probability: 0.5 },
          'f' => { flam: true },
          'F' => { velocity: Clip::ACCENT_VELOCITY, accented: true, flam: true },
          '.' => :rest,
          '|' => :ignore,
          ' ' => :ignore,
        }
        (1..9).each { |d| SYMBOLS[d.to_s] = { velocity: d / 9.0 } }

        # Adds or replaces a grid character.  +attrs+ is a Hash of Seq::Step
        # attributes (e.g. `{ velocity: 0.3 }`), :rest, :tie, or :ignore.
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
            when :tie
              Seq::Step.new(length: length, tie: true)
            else
              Seq::Step.new(value: value, length: length, velocity: Clip::DEFAULT_VELOCITY, **attrs)
            end
          }

          Seq.new(steps, seed: seed)
        end

        # Returns the note number for a grid row name: a GM_DRUMS or
        # ROW_ALIASES Symbol, a Note, or a Numeric.
        def self.row_value(name, map = {})
          v = map.fetch(name) { name.is_a?(Symbol) ? GM_DRUMS.fetch(name) { ROW_ALIASES[name] } : name }
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
      #     play 50.hz.sine * beat[:kick].env(0, 0.2, 0, 0.05) + noise.filter(:highpass, cutoff: 8000) * beat[:hat].env(0, 0.03, 0, 0.02)
      class Kit
        include Enumerable
        include Named
        include PlayedBy

        # The row clips, keyed by name.
        attr_reader :rows

        # Row names of the clips kits were made with (weakly held), for
        # Session#swap with a Kit (see .row_name).
        ROW_NAMES = ObjectSpace::WeakMap.new

        # The row name +clip+ had in the last Kit made with it, or nil.
        def self.row_name(clip)
          ROW_NAMES[clip]
        end

        # +row_names: false+ leaves the rows unnamed for Session#swap: for
        # kits a patch makes from the kit it was given (a drum machine's
        # shuffle), so a swap replaces the given kit's rows and makes the
        # patch's transform again (see Session::ClipSwaps).
        def initialize(rows, row_names: true)
          @instrument = nil # (see PlayedBy)
          @rows = rows.freeze
          @rows.each { |name, clip| ROW_NAMES[clip] = name if clip.is_a?(Clip) } if row_names
        end

        # Returns the Clip for the row with the given +name+.
        def [](name)
          @rows.fetch(name) { raise KeyError, "No row #{name.inspect} (rows: #{@rows.keys.map(&:inspect).join(', ')})" }
        end

        # Yields each name and row Clip.
        def each(&block)
          @rows.each(&block)
        end

        # Returns a Kit with every row looping independently (+:align+ as in
        # Clip#loop).
        def loop(seed: nil, align: :timeline)
          Kit.new(@rows.transform_values { |c| seed ? c.loop(seed: seed, align: align) : c.loop(align: align) })
        end

        # Returns a Kit with every row's times and lengths multiplied by
        # +factor+ (see Clip#stretch).
        def stretch(factor)
          Kit.new(@rows.transform_values { |c| c.stretch(factor) })
        end

        # Returns a Kit with every row in half time (see Clip#halftime).
        # Also called #half_time.
        def halftime(factor = 2)
          Kit.new(@rows.transform_values { |c| c.halftime(factor) })
        end
        alias half_time halftime

        # Returns a Kit with every row in double time (see
        # Clip#doubletime).  Also called #double_time.
        def doubletime(factor = 2)
          Kit.new(@rows.transform_values { |c| c.doubletime(factor) })
        end
        alias double_time doubletime

        # Returns a Kit with every row's notes shortened (see Clip#legato).
        def legato(fraction)
          Kit.new(@rows.transform_values { |c| c.legato(fraction) })
        end

        # Kit transforms (parity-1, 2026-10-30): each runs the Clip method of
        # the same name on every row, so a row of the result is the row
        # transformed as a clip (the rows' own lengths, loops, and
        # alignments; a polymetric row rotates within its own length).
        # Seeded ones (#humanize, #permute) give each row its own seed,
        # Kit.row_seed(seed, name), so rows don't move in lockstep:
        # `kit.humanize(seed: 3)[:hat] == kit[:hat].humanize(seed:
        # Kit.row_seed(3, :hat))`.

        # The seed row +name+ draws from in seeded Kit transforms: +seed+
        # (an Integer) mixed with the name (Generative::Dice's hash, the
        # same in every process).
        def self.row_seed(seed, name)
          key = name.is_a?(Symbol) || name.is_a?(String) || name.is_a?(Integer) ? name : name.to_s
          Generative::Dice.fold(Generative::Dice.start(Integer(seed)), :kit_row, key) & ((1 << 62) - 1)
        end

        # Returns a Kit with every row played backward (see Clip#reverse).
        # Also #retrograde.
        def reverse
          Kit.new(@rows.transform_values(&:reverse))
        end
        alias retrograde reverse

        # Returns a Kit with every row's hits moved +amount+ later (or
        # earlier for a negative amount), wrapping around the row's length
        # (see Clip#rotate).
        #
        #     beat.rotate(1.n16)     # the whole pattern a 16th later, wrapped
        def rotate(amount)
          Kit.new(@rows.transform_values { |c| c.rotate(amount) })
        end

        # Returns a Kit with every row's hits moved +amount+ later (or
        # earlier) without wrapping: hits that leave a row drop out (see
        # Clip#shift).
        def shift(amount)
          Kit.new(@rows.transform_values { |c| c.shift(amount) })
        end

        # Returns a Kit with every row's notes (velocities, probabilities,
        # marks) moved among its hits (see Clip#permute): accents and
        # ghost notes trade places, the rhythm stays.  +order+ is nil
        # (random, from each row's seed, see Kit.row_seed) or an Array for
        # every row; row keywords give rows their own orders, leaving the
        # rows not named alone (`beat.permute(hat: [3, 2, 1, 0])`).  Also
        # #shuffle.
        def permute(order = nil, seed: nil, vary: false, **orders)
          unknown = orders.keys - @rows.keys
          raise ArgumentError, "No rows #{unknown.map(&:inspect).join(', ')} to permute (rows: #{@rows.keys.map(&:inspect).join(', ')})" unless unknown.empty?
          raise ArgumentError, 'Give one order for every row or orders by row name, not both' if order && !orders.empty?

          Kit.new(@rows.to_h { |name, c|
            next [name, c] unless orders.empty? || orders.key?(name)

            [name, c.permute(orders.fetch(name, order), seed: Kit.row_seed(seed || c.seed, name), vary: vary)]
          })
        end
        alias shuffle permute

        # Returns a Kit with every row humanized (see Clip#humanize), each
        # row from its own seed (Kit.row_seed of +:seed+, else of the
        # row's seed).
        #
        #     beat.loop.humanize(6.ms, velocity: 0.1)
        def humanize(time = Clip::HUMANIZE_TIME, velocity: 0, seed: nil, vary: nil)
          Kit.new(@rows.to_h { |name, c|
            [name, c.humanize(time, velocity: velocity, seed: Kit.row_seed(seed || c.seed, name), vary: vary)]
          })
        end

        # Returns a Kit with every row quantized (see Clip#quantize).
        def quantize(grid = Feel::GRID, amount: 1, ends: false, window: nil)
          Kit.new(@rows.transform_values { |c| c.quantize(grid, amount: amount, ends: ends, window: window) })
        end

        # Returns a Kit with every row swung (see Clip#swing).
        #
        #     beat.swing(0.6)
        def swing(amount = Feel::SWING, grid = Feel::GRID)
          Kit.new(@rows.transform_values { |c| c.swing(amount, grid) })
        end

        # Returns a Kit whose hits play with probability +p+ in each loop
        # cycle (see Clip#chance).  Also #maybe.
        def chance(p)
          Kit.new(@rows.transform_values { |c| c.chance(p) })
        end
        alias maybe chance

        # Returns a Kit whose hits play every +n+th loop cycle from cycle
        # +from+ (see Clip#every).
        def every(n, from: 1)
          Kit.new(@rows.transform_values { |c| c.every(n, from: from) })
        end

        # Returns a Kit with every hit's velocity set to +velocity+ (see
        # Clip#vel; clamped to 0..1 by Feel.fixed_velocity).
        #
        #     beat.vel(0.7)
        def vel(velocity)
          v = Feel.fixed_velocity(velocity)
          Kit.new(@rows.transform_values { |c| c.vel(v) })
        end

        # Returns a Kit with every hit ratcheted into +count+ hits (see
        # Clip#ratchet).
        #
        #     beat.ratchet(2, rate: 1.n32)
        def ratchet(count, rate: nil, velocity: nil)
          Kit.new(@rows.transform_values { |c| c.ratchet(count, rate: rate, velocity: velocity) })
        end

        # Returns a Kit that adds fill notes: rows (Clips, or a Kit or Hash
        # of Clips given as +other+ or returned by the block) that play only
        # during fills (only fill +name+ if given; see Clip#fill), layered
        # onto rows of the same name or added as new rows.  Layered rows
        # loop again if they looped (each row keeps its seed and alignment;
        # variations are played out as in Clip#&).
        #
        #     beat = grid(16, kick: 'X...x...X...x...', clap: '....X.......X...')
        #       .fill { grid(16, clap: '..........x.xxxx') }        # any fill
        #       .fill(:big, crash: grid(16, 'X...............', value: 49))
        #       .nofill(:hat)
        #       .loop
        def fill(name = nil, other = nil, **rows, &block)
          raise ArgumentError, "Fill names must be Symbols (got #{name.inspect}); pass rows as keywords or a Kit" unless name.nil? || name.is_a?(Symbol)
          other = block.call if block
          other = other.rows if other.is_a?(Kit)
          other = (other || {}).merge(rows)
          raise ArgumentError, 'Kit#fill needs rows: keywords, a Kit, or a block returning a Kit' if other.empty?

          new_rows = @rows.dup
          other.each do |row, clip|
            clip = Clip.from(clip) unless clip.is_a?(Clip)
            marked = clip.fill(name)
            old = new_rows[row]
            new_rows[row] = if old.nil?
                              marked
                            else
                              layered = old & marked
                              old.looping? ? layered.loop(seed: old.seed, align: old.align) : layered
                            end
          end
          Kit.new(new_rows)
        end

        # Returns a Kit whose named rows (every row if none are named) play
        # only outside fills (outside fill +name+ if given; see
        # Clip#nofill), e.g. hats that drop out under a fill:
        # `beat.nofill(:clap, name: :turn)`.
        def nofill(*names, name: nil)
          names = @rows.keys if names.empty?
          unknown = names - @rows.keys
          raise ArgumentError, "No rows #{unknown.map(&:inspect).join(', ')} (rows: #{@rows.keys.map(&:inspect).join(', ')})" unless unknown.empty?
          Kit.new(@rows.to_h { |k, c| [k, names.include?(k) ? c.nofill(name) : c] })
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
