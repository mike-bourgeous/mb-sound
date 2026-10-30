module MB
  module Sound
    # A linear gain that remembers the decibel value it came from: what
    # Numeric#db returns (`-6.db`).  It acts like the Float gain everywhere
    # (arithmetic, comparisons, Numo, C extensions through #to_f), so
    # `sig * -20.db`, `at(-6.db)`, and `master_gain -6.db` work as they
    # always have, and arithmetic results are plain Floats (`-6.db * 2` is a
    # gain of 1.0, no longer a dB value).
    #
    # What the tag adds: methods that take levels in dB (dynamics thresholds,
    # ceilings, makeup, compander points) read a Decibels value as its exact
    # dB number, so `compress(threshold: -20.db)` and `makeup: 6.db` are
    # unambiguous (bare numbers there are linear gains, like gains
    # everywhere else), and graph export prints it back as `-20.db`.
    #
    #     g = -6.db        # => -6.db
    #     g.to_f           # => 0.5011872336272722
    #     g.decibels       # => -6
    #     g * 2            # => 1.0023744672545444 (a Float)
    class Decibels < Numeric
      # The decibel value as given (an Integer, Float, or Rational).
      attr_reader :decibels

      # Creates a gain of +decibels+ dB.  Prefer Numeric#db.
      def initialize(decibels)
        raise ArgumentError, "Decibels need a real number (got #{decibels.inspect})" unless decibels.is_a?(Numeric) && decibels.real?

        @decibels = decibels.is_a?(Decibels) ? decibels.decibels : decibels
        # The same expression Numeric#db always used, so gains are unchanged
        @linear = 10.0 ** (@decibels / 20.0)
        freeze
      end

      # The linear gain.
      def to_f
        @linear
      end

      # The dB value as a Float (exact, unlike #to_db, which measures the
      # linear gain).
      def db_value
        @decibels.to_f
      end

      # Ruby's numeric coercion: `2 * -6.db` multiplies 2 by the gain, as
      # with a Float (other kinds of numbers, e.g. Complex, keep their own
      # rules against the Float gain).
      def coerce(other)
        [other, @linear]
      end

      # Equal to Floats (and other numbers) of the same gain.
      def ==(other)
        other.is_a?(Decibels) ? @linear == other.to_f : @linear == other
      end
      alias === ==

      # Hash equality: only Decibels of the same dB value.
      def eql?(other)
        other.is_a?(Decibels) && @decibels.eql?(other.decibels)
      end

      def hash
        [Decibels, @decibels].hash
      end

      # Prints as Ruby that makes this value: `-6.db`.
      def inspect
        RubyValue.number(self)
      end

      # The gain as text, like the Float it stands for (so interpolated
      # descriptions don't change).
      def to_s
        @linear.to_s
      end

      # Everything else a Float does, done by the gain (results are plain
      # Floats, Integers, or Rationals).
      # Binary operators and comparisons take one argument without a
      # splat, so `gain < 0.5` allocates nothing (a splat's Array per call
      # was hidden per-buffer garbage where render paths compare gains;
      # `0.5 < gain` still goes through #coerce's Array: compare Floats on
      # render paths, render_path_guard_spec).
      BINARY = %i[+ - * / ** % < > <= >= <=> divmod fdiv quo modulo].freeze
      (Float.public_instance_methods(false) - [:coerce, :==, :===, :eql?, :hash, :inspect, :to_s, :to_f]).each do |name|
        if BINARY.include?(name)
          define_method(name) do |other|
            @linear.public_send(name, other)
          end
        else
          define_method(name) do |*args, &block|
            @linear.public_send(name, *args, &block)
          end
        end
      end

      def real?
        true
      end

      def integer?
        false
      end

      # Numo's binary operators (`buf * -6.db`) find the result type in each
      # array class's frozen UPCAST table by the other operand's class, and
      # fail on classes they don't know.  This gives Decibels the entries of
      # Float (then Numo casts it through #to_f).  Numo::NArray[-6.db]
      # (untyped) and Numo::NMath on a bare Decibels still see an object:
      # use Numo::SFloat[...] or #to_f there.
      def self.register_with_numo
        ObjectSpace.each_object(Class).select { |c| c <= Numo::NArray && c.const_defined?(:UPCAST, false) }.each do |c|
          table = c::UPCAST
          next unless table.key?(Float) && !table.key?(self)

          table = table.merge(self => table[Float]).freeze
          c.send(:remove_const, :UPCAST)
          c.const_set(:UPCAST, table)
        end
      end
      register_with_numo

      # Reading dB-valued arguments (one rule everywhere, maintainer
      # 2026-10-13; db-1, 2026-10-14): a Decibels value (-12.db) is read as
      # exactly that many dB, and a bare number is a linear gain, as gains
      # are everywhere else.  A bare negative number is a mistake: scripts
      # and specs raise ArgumentError ("for -20 dB write -20.db"); live mode
      # (MB::Sound.live?) reads it as dB, its old meaning, with a warning
      # once per call site.  A bare 0 is -inf dB where +zero+ allows it (a
      # full cut), else goes through MB::Sound.live_error (live mode reads
      # it as 0 dB).  With +above_one+, a linear gain above 1 (louder than
      # full scale, e.g. `threshold: 6`) warns once per call site.
      # Warnings name the first caller outside lib/.

      # Linear gains above this get the +above_one+ warning.
      LINEAR_WARN_ABOVE = 1.0

      @warnings = {}
      @warning_lock = Mutex.new

      class << self
        # A dB-valued argument as a linear gain (see above).
        def gain_of(value, name, zero: false, above_one: false)
          return checked(value, name).to_f if value.is_a?(Decibels)

          v = bare(value, name, zero: zero, above_one: above_one)
          v.is_a?(Array) ? 10.0 ** (v[0] / 20.0) : v
        end

        # A dB-valued argument in dB (see above).
        def db_of(value, name, zero: false, above_one: false)
          return checked(value, name).db_value if value.is_a?(Decibels)

          v = bare(value, name, zero: zero, above_one: above_one)
          return v[0] if v.is_a?(Array)

          v == 0 ? -Float::INFINITY : 20.0 * Math.log10(v)
        end

        # A ducking amount as dB of reduction (0 or more; Infinity for a full
        # cut): a Decibels value's magnitude, so -12.db and 12.db both duck
        # by 12 dB (ducking never boosts; maintainer 2026-10-14), a bare
        # linear gain at most 1 by its dB (0.25 ducks by 12 dB; 0 is a full
        # cut).  A bare number above 1 raises ("for 12 dB of ducking write
        # -12.db"), or in live mode is read as dB of reduction with a
        # warning; a bare negative number follows .db_of.
        def reduction_db(value, name)
          return checked(value, name).db_value.abs if value.is_a?(Decibels)

          v = checked(value, name).to_f
          if v > 1
            message = "#{name}: #{value.inspect} is a linear gain above 1, and ducking never boosts; for #{value.inspect} dB of ducking write -#{value.inspect}.db"
            raise ArgumentError, message unless MB::Sound.live?

            warn_once(:live_reduction, "#{name}: #{value.inspect} is read as #{value.inspect} dB of ducking in live mode; write -#{value.inspect}.db (bare numbers are linear gains)")
            return v
          end

          db_of(value, name, zero: true).abs
        end

        # Raises unless +value+ is a real number (not NaN); returns it.
        def checked(value, name)
          unless value.is_a?(Numeric) && value.real? && !value.to_f.nan?
            raise ArgumentError, "#{name} must be a number (dB like -6.db, or a linear gain; got #{value.inspect})"
          end
          value
        end

        # Runs the block without the "above full scale" warnings (graph
        # documents load quietly).
        def quietly
          old = Thread.current[:mb_sound_quiet_levels]
          Thread.current[:mb_sound_quiet_levels] = true
          yield
        ensure
          Thread.current[:mb_sound_quiet_levels] = old
        end

        # The library's own directory, skipped when looking for call sites.
        LIBRARY_DIR = File.expand_path('../..', __dir__) + File::SEPARATOR

        # Warns +message+ once per call site (the first caller outside
        # lib/) and +kind+.
        def warn_once(kind, message)
          site = caller_locations(2).find { |l|
            path = l.absolute_path || l.path
            !path.start_with?(LIBRARY_DIR) && !path.start_with?('<internal:')
          }
          where = site ? "#{site.path}:#{site.lineno}" : '(unknown)'
          key = [where, kind, message]
          first = @warning_lock.synchronize { @warnings[key] ? false : (@warnings[key] = true) }
          warn "#{where}: warning: #{message}" if first
        end

        private

        # A bare number as a linear gain, or [dB] for a negative number
        # read as dB in live mode (see above).
        def bare(value, name, zero:, above_one:)
          v = checked(value, name).to_f
          if v < 0
            message = "#{name}: #{value.inspect} is a linear gain, and gains can't be negative; for #{value.inspect} dB write #{value.inspect}.db"
            raise ArgumentError, message unless MB::Sound.live?

            warn_once(:live_db, "#{name}: #{value.inspect} is read as #{value.inspect} dB in live mode; write #{value.inspect}.db (bare numbers are linear gains)")
            return [v]
          end
          if v == 0 && !zero
            MB::Sound.live_error(ArgumentError.new("#{name}: 0 is a linear gain of zero (-inf dB); for 0 dB write 0.db"))
            v = 1.0
          end
          if above_one && v > LINEAR_WARN_ABOVE && !Thread.current[:mb_sound_quiet_levels]
            warn_once(:above_one, "#{name}: #{value.inspect} is a linear gain of #{MB::M.sigfigs(20.0 * Math.log10(v), 3)} dB, above full scale; did you mean #{(-value).inspect}.db?")
          end
          v
        end
      end
    end
  end
end
