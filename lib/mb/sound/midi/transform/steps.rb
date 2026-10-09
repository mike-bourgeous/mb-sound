module MB
  module Sound
    module MIDI
      class Transform
        # A pitch step in scale degrees (user decision 4, 2026-10-09:
        # +pitch:+ is always in scale degrees; the default scale is
        # chromatic, so degrees are semitones), used by Event#transpose,
        # Stream#transpose, echo, and the arpeggiator.
        #
        # A step is a number of scale degrees (whole numbers, or any number
        # for the chromatic scale, whose degrees are semitones), an exact
        # Interval (`7.st`, `1.oct`, `50.cents`: semitones added after the
        # degrees, so `1.oct` is an octave in any scale), or an Array of
        # steps added together (`[2, 1.oct]`).
        class Steps
          # The scale degrees (an Integer).
          attr_reader :degrees

          # The semitones added after the degrees (from Intervals).
          attr_reader :semitones

          # The Scale (Scale::CHROMATIC by default).
          attr_reader :scale

          # +step+ as described in the class description; +:scale+ a Scale,
          # name, Array of offsets, or nil (chromatic), with +:root+ if
          # given (see Scale.[]).
          def initialize(step = 0, scale: nil, root: nil)
            @scale = scale.is_a?(Scale) && root.nil? ? scale : Scale[scale, root]
            @degrees = 0
            @semitones = 0
            add(step)
          end

          # Returns +note+ (a number, or a Pitch for fixed frequencies in
          # clips, which moves chromatically) moved by this step.
          def apply(note)
            unless note.is_a?(Numeric)
              raise ArgumentError, "Only note numbers move by scale degrees (got #{note.inspect})" unless @scale.chromatic? && note.respond_to?(:transpose)
              return zero? ? note : note.transpose(@degrees + @semitones)
            end

            n = @degrees == 0 ? note : @scale.transpose(note, @degrees)
            @semitones == 0 ? n : n + @semitones
          end

          # Returns a Steps of +count+ times this step.
          def *(count)
            Steps.new(0, scale: @scale).tap { |s| s.send(:set, @degrees * count, @semitones * count) }
          end

          # Returns a Steps of this step plus +other+ (a Steps in the same
          # scale, or anything the constructor takes).
          def +(other)
            other = Steps.new(other, scale: @scale) unless other.is_a?(Steps)
            Steps.new(0, scale: @scale).tap { |s| s.send(:set, @degrees + other.degrees, @semitones + other.semitones) }
          end

          def zero?
            @degrees == 0 && @semitones == 0
          end

          def to_s
            parts = []
            parts << @degrees.to_s if @degrees != 0
            parts << Interval.new(@semitones).to_s if @semitones != 0
            parts.empty? ? '0' : parts.join(' + ')
          end

          private

          def set(degrees, semitones)
            @degrees = degrees
            @semitones = semitones
          end

          def add(step)
            case step
            when Array then step.each { |s| add(s) }
            when Steps
              @degrees += step.degrees
              @semitones += step.semitones
            when Interval then @semitones += step.to_semitones
            when Numeric
              if step == step.round
                @degrees += step.round
              elsif @scale.chromatic?
                @semitones += step # chromatic degrees are semitones, fractions too
              else
                raise ArgumentError, "Scale degrees are whole numbers; use an Interval (e.g. #{step}.st or 50.cents) for other pitch steps (got #{step})"
              end
            else
              raise ArgumentError, "A pitch step is a number of scale degrees, an Interval, or an Array of them (got #{step.inspect})"
            end
          end
        end
      end
    end
  end
end
