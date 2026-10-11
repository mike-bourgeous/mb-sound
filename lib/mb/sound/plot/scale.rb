module MB
  module Sound
    module Plot
      # Scales map data values to positions from 0 to 1 and make ticks with
      # labels.  A scale made without a domain is fit to its chart's data
      # (Scale::Base#fit); one made with a domain keeps it.
      #
      #     Scale::Linear.new(-1..1)
      #     Scale::Frequency.new(20..20000, notes: true)
      #     Scale::Time.new(sample_rate: 48000)  # data in samples, labels in s/ms
      #     Scale::DB.new(-80..0)
      #
      # Scales are immutable: #fit and #with_domain return copies.
      module Scale
        # Shared behavior of every scale.
        class Base
          # The domain's ends (Floats; nil before the scale is fit).
          attr_reader :lo, :hi

          # The axis title, without the unit (see #title).
          attr_reader :label

          # The unit shown after the axis title, or nil.
          attr_reader :unit

          # +domain+ is a Range or two-element Array of data values, or nil
          # to fit the chart's data.  With +nice+, a fitted domain grows to
          # the nearest ticks.  +reverse+ maps the domain backward.
          def initialize(domain = nil, label: nil, unit: nil, nice: nil, reverse: false)
            @label = label
            @unit = unit
            @nice = nice.nil? ? default_nice : nice
            @reverse = reverse
            @fixed = !domain.nil?
            set_domain(*domain_ends(domain)) if domain
          end

          # True if the domain was given rather than fit to data.
          def fixed?
            @fixed
          end

          # True once the scale has a domain.
          def ready?
            !@lo.nil?
          end

          # A copy fit to data from +lo+ to +hi+ (unless the domain was
          # given), widened when the data is flat.
          def fit(lo, hi)
            return self if fixed?

            lo, hi = default_domain if lo.nil? || hi.nil? || !lo.finite? || !hi.finite?
            lo, hi = widen(lo.to_f, hi.to_f)
            lo, hi = nice_domain(lo, hi) if @nice
            copy { |s| s.send(:set_domain, lo, hi) }
          end

          # A copy with the domain from +lo+ to +hi+.
          def with_domain(lo, hi)
            copy { |s|
              s.instance_variable_set(:@fixed, true)
              s.send(:set_domain, lo.to_f, hi.to_f)
            }
          end

          # A copy with another axis title.
          def with_label(label)
            copy { |s| s.instance_variable_set(:@label, label) }
          end

          # Maps +v+ (Numeric or Numo::NArray) to 0..1 over the domain (values
          # outside the domain map outside 0..1).
          def map(v)
            u = forward(v)
            @reverse ? 1 - u : u
          end

          # Inverse of #map.
          def invert(u)
            u = 1 - u if @reverse
            backward(u)
          end

          # The data values that are valid for this scale (all finite values;
          # positive values for log scales), as a Numo::Bit mask.
          def valid(v)
            v.isfinite
          end

          # The axis title with its unit, e.g. "frequency (Hz)".
          def title
            return @label if @unit.nil? || @unit.to_s.empty?
            return "(#{@unit})" if @label.nil? || @label.to_s.empty?

            "#{@label} (#{@unit})"
          end

          # Ticks for about +count+ intervals.
          def ticks(count = 5)
            step = Format.nice_step(@hi - @lo, count)
            values = Format.steps(@lo, @hi, step)
            labels = Format.labels(values, step, si: :up)
            values.zip(labels).map { |v, l| Tick.new(value: v, label: l) }
          end

          # True if equal steps of data are equal steps on the axis.
          def linear?
            true
          end

          # Extra labeled ticks drawn on a second row (note names for
          # Frequency scales), or an empty Array.
          def secondary_ticks(count = 5)
            []
          end

          def inspect
            "#<#{self.class.name.split('::').last(2).join('::')} #{@lo.inspect}..#{@hi.inspect}#{" #{title.inspect}" if title}>"
          end

          private

          def default_nice
            false
          end

          def default_domain
            [0.0, 1.0]
          end

          def domain_ends(domain)
            case domain
            when Range then [domain.begin.to_f, domain.end.to_f]
            when Array then [domain[0].to_f, domain[1].to_f]
            else raise ArgumentError, "Scale domains are Ranges or [lo, hi] Arrays, not #{domain.inspect}"
            end
          end

          def set_domain(lo, hi)
            @lo = lo
            @hi = hi
          end

          def copy
            c = dup
            yield c
            c.freeze
          end

          def widen(lo, hi)
            if hi < lo
              lo, hi = hi, lo
            end
            if hi == lo
              d = lo == 0 ? 1.0 : lo.abs * 0.5
              return [lo - d, hi + d]
            end
            [lo, hi]
          end

          def nice_domain(lo, hi)
            step = Format.nice_step(hi - lo, 5)
            [(lo / step + 1e-9).floor * step, (hi / step - 1e-9).ceil * step]
          end

          def forward(v)
            (v - @lo) / (@hi - @lo)
          end

          def backward(u)
            u * (@hi - @lo) + @lo
          end
        end

        # A plain linear scale (nice domains by default when fit to data).
        class Linear < Base
          private def default_nice
            true
          end
        end

        # A linear scale centered on zero (waveforms): the domain is
        # -m..m for the largest magnitude m, rounded up to a nice value.
        class Symmetric < Linear
          def fit(lo, hi)
            return self if fixed?

            m = [lo.to_f.abs, hi.to_f.abs].max
            m = 1.0 if m == 0 || !m.finite?
            step = Format.nice_step(m, 2)
            m = (m / step - 1e-9).ceil * step if @nice
            copy { |s| s.send(:set_domain, -m, m) }
          end
        end

        # Decibels: a linear scale titled with dB, with a +floor+ so
        # silence (-Infinity) maps to the bottom.
        class DB < Linear
          # The lowest value a fitted domain reaches.
          attr_reader :floor

          def initialize(domain = nil, label: 'level', unit: 'dB', floor: -120, **kwargs)
            @floor = floor
            super(domain, label: label, unit: unit, **kwargs)
          end

          def fit(lo, hi)
            lo = @floor if lo && (lo < @floor || !lo.finite?)
            hi = @floor + 1 if hi && !hi.finite?
            super(lo, hi)
          end

          private def nice_domain(lo, hi)
            nlo, nhi = super
            [[nlo, @floor].max, nhi]
          end

          def ticks(count = 5)
            step = Format.nice_step(@hi - @lo, count)
            step = (step / 3.0).ceil * 3 if step >= 3 && step < 10 # 3 or 6 dB grids read well
            values = Format.steps(@lo, @hi, step)
            values.zip(Format.labels(values, step)).map { |v, l| Tick.new(value: v, label: l) }
          end
        end

        # A base-10 logarithmic scale (positive data only).
        class Log < Base
          def linear?
            false
          end

          def valid(v)
            v.isfinite & (v > 0)
          end

          def ticks(count = 5)
            llo = Math.log10(@lo)
            lhi = Math.log10(@hi)
            decades = lhi - llo
            return linear_ticks(count) if decades < 0.6

            mantissas =
              if decades >= 3
                [1]
              elsif decades >= 1.4
                [1, 2, 5]
              else
                [1, 2, 3, 5]
              end

            ticks = []
            (llo.floor..lhi.ceil).each do |k|
              (1..9).each do |m|
                v = m * 10.0**k
                next if v < @lo * 0.9999 || v > @hi * 1.0001

                labeled = mantissas.include?(m)
                ticks << Tick.new(value: v, label: labeled ? log_label(v) : nil, major: labeled)
              end
            end
            ticks
          end

          private

          def log_label(v)
            Format.labels([v], v, si: :up)[0]
          end

          def linear_ticks(count)
            step = Format.nice_step(@hi - @lo, count)
            values = Format.steps(@lo, @hi, step)
            values.zip(Format.labels(values, step, si: :up)).map { |v, l| Tick.new(value: v, label: l) }
          end

          def default_domain
            [1.0, 10.0]
          end

          def widen(lo, hi)
            lo, hi = hi, lo if hi < lo
            lo = hi / 1000.0 if lo <= 0
            lo, hi = 1.0, 10.0 if hi <= 0
            return [lo / 2, hi * 2] if lo == hi

            [lo, hi]
          end

          def nice_domain(lo, hi)
            [10.0**Math.log10(lo).floor, 10.0**Math.log10(hi).ceil]
          end

          def set_domain(lo, hi)
            raise ArgumentError, "Log scale domains must be positive (got #{lo}..#{hi})" if lo <= 0 || hi <= 0

            @lo = lo
            @hi = hi
            @llo = Math.log10(lo)
            @lspan = Math.log10(hi) - @llo
          end

          def forward(v)
            if v.is_a?(Numo::NArray)
              v = Numo::DFloat.cast(v)
              v[v <= 0] = Float::NAN
              (Numo::NMath.log10(v) - @llo) / @lspan
            else
              v > 0 ? (Math.log10(v) - @llo) / @lspan : Float::NAN
            end
          end

          def backward(u)
            if u.is_a?(Numo::NArray)
              10.0**(u * @lspan + @llo)
            else
              10.0**(u * @lspan + @llo)
            end
          end
        end

        # Logarithmic frequency in Hz (labels 100, 1k, 10k), optionally with
        # note names of every C (every other C over more than 9 octaves, or
        # every +notes+ semitones when it's an Integer) as secondary ticks.
        class Frequency < Log
          NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

          # +notes+ adds note-name ticks (C2, C3, ...); +a4+ is their tuning.
          def initialize(domain = nil, label: 'frequency', unit: 'Hz', notes: false, a4: 440.0, **kwargs)
            @notes = notes
            @a4 = a4.to_f
            super(domain, label: label, unit: unit, **kwargs)
          end

          # True if note-name ticks are drawn.
          def notes?
            !!@notes
          end

          def secondary_ticks(count = 5)
            return [] unless @notes

            first = (69 + 12 * Math.log2(@lo / @a4)).ceil
            last = (69 + 12 * Math.log2(@hi / @a4)).floor
            octaves = (last - first) / 12.0
            step = @notes.is_a?(Integer) ? @notes : (octaves > 9 ? 24 : 12)
            (first..last).select { |n| n % step == 0 }.map { |n|
              Tick.new(value: @a4 * 2**((n - 69) / 12.0), label: "#{NOTE_NAMES[n % 12]}#{n / 12 - 1}")
            }
          end

          private

          def default_domain
            [20.0, 20000.0]
          end

          def nice_domain(lo, hi)
            [lo, hi]
          end
        end

        # Time: data in seconds (or in samples with +sample_rate+, or in
        # bars with +unit: :bars+), labeled in s, ms, or µs as fits the
        # domain, or in samples (+unit: :samples+).
        class Time < Base
          # +sample_rate+: data values are sample indexes (labels still in
          # seconds unless +unit+ is :samples).  +unit+ is :seconds
          # (default, with ms/µs as fits), :samples, or :bars (data in
          # bars from 0; labeled from bar 1, +beats+ per bar).
          def initialize(domain = nil, label: 'time', sample_rate: nil, unit: :seconds, beats: 4, **kwargs)
            @sample_rate = sample_rate&.to_f
            @time_unit = unit
            @beats = beats
            super(domain, label: label, **kwargs)
          end

          def title
            return "#{@label} (samples)" if @time_unit == :samples
            return 'bar' if @time_unit == :bars

            "#{@label} (#{display_unit[0]})"
          end

          def ticks(count = 5)
            case @time_unit
            when :samples
              return super
            when :bars
              return bar_ticks(count)
            end

            _, factor = display_unit
            lo = seconds(@lo) * factor
            hi = seconds(@hi) * factor
            step = Format.nice_step(hi - lo, count)
            values = Format.steps(lo, hi, step)
            labels = Format.labels(values, step)
            values.zip(labels).map { |v, l| Tick.new(value: data_value(v / factor), label: l) }
          end

          private

          def bar_ticks(count)
            bars = @hi - @lo
            step = bars <= count / 2.0 ? 1.0 / @beats : Format.nice_step(bars, count).clamp(1.0, nil)
            Format.steps(@lo, @hi, step).map { |v|
              bar = v.floor
              beat = ((v - bar) * @beats).round
              Tick.new(value: v, label: beat == 0 ? (bar + 1).to_s : "#{bar + 1}.#{beat + 1}", major: beat == 0)
            }
          end

          # [unit name, factor from seconds] for the domain's largest value
          def display_unit
            big = [seconds(@lo).abs, seconds(@hi).abs].max
            if big < 2e-3 && big > 0
              ['µs', 1e6]
            elsif big < 2
              ['ms', 1e3]
            else
              ['s', 1.0]
            end
          end

          def seconds(v)
            @sample_rate ? v / @sample_rate : v
          end

          def data_value(s)
            @sample_rate ? s * @sample_rate : s
          end
        end

        # Named categories at evenly spaced bands: data values are indexes
        # (0...names.length); ticks are the names.
        class Categorical < Base
          # The category names.
          attr_reader :names

          def initialize(names, label: nil, **kwargs)
            @names = names.map(&:to_s).freeze
            super(-0.5..(names.length - 0.5), label: label, **kwargs)
          end

          def ticks(count = nil)
            @names.each_with_index.map { |n, i| Tick.new(value: i.to_f, label: n) }
          end
        end

        # Makes a scale from a builder argument: a Scale (returned as is), a
        # Range (linear domain), a Symbol kind (:linear, :log, :frequency,
        # :freq, :db, :time, :symmetric, :categorical), or nil (linear).
        def self.build(spec = nil, domain = nil, **kwargs)
          case spec
          when Base
            spec
          when Range, Array
            Linear.new(spec, **kwargs)
          when nil, :linear
            Linear.new(domain, **kwargs)
          when :log
            Log.new(domain, **kwargs)
          when :frequency, :freq, :hz
            Frequency.new(domain, **kwargs)
          when :db, :decibels
            DB.new(domain, **kwargs)
          when :time, :seconds
            Time.new(domain, **kwargs)
          when :samples
            Time.new(domain, unit: :samples, **kwargs)
          when :bars
            Time.new(domain, unit: :bars, **kwargs)
          when :symmetric, :wave
            Symmetric.new(domain, **kwargs)
          when :categorical, :names
            Categorical.new(domain || kwargs.delete(:names), **kwargs)
          else
            raise ArgumentError, "Unknown scale #{spec.inspect} (try :linear, :log, :frequency, :db, :time, :samples, :bars, :symmetric, :categorical, a Range, or a Scale)"
          end
        end
      end
    end
  end
end
