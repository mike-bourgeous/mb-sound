module MB
  module Sound
    module Structure
      # One beat found by the analysis: its time in seconds from the start
      # of the audio, and its place as +bar+ (counting from 1; beats before
      # the first downbeat are a pickup in bar 0) and quarter-note +beat+
      # within the bar (counting from 1).
      Beat = Data.define(:seconds, :bar, :beat) do
        # bar:beat like Session::Stamp, e.g. "9:1".
        def to_s
          b = beat.is_a?(Rational) && beat.denominator != 1 ? beat.to_f.round(3) : beat.to_i
          "#{bar}:#{b}"
        end

        def inspect
          "#<Beat #{self} at #{format('%.3f', seconds)} s>"
        end
      end

      # One bar found by the analysis: its +number+ (counting from 1
      # through irregular bars, like Sequence::Transport#bar_at), the time
      # of its downbeat in +seconds+, its length in quarter-note +beats+ (4
      # in 4/4, 2 for a 2/4 bar; a Rational for bars like 7/8 on a
      # Transport grid), and +end_seconds+ (the next bar's downbeat, or one
      # bar length on for the last bar).
      Bar = Data.define(:number, :seconds, :beats, :end_seconds) do
        # The bar's length in whole notes (1 for 4/4, 1/2r for 2/4).
        def length
          Rational(beats) / 4
        end

        # The bar's time signature, e.g. "4/4" or "7/8".
        def meter
          Sequence::Transport.meter_label(length)
        end

        def to_s
          "bar #{number} (#{meter}) at #{format('%.3f', seconds)} s"
        end

        def inspect
          "#<Bar #{self}>"
        end
      end

      # The result of Structure.analyze (phase S1: grid and meter): the
      # tempo, every beat, the bars (including irregular ones), and the
      # meter map.  Phase S2 adds sections, labels, forms, and markers.
      class Result
        # The tempo in quarter notes per minute (the grid's tempo: the
        # Transport's for a known grid, the fitted period for tracked beats).
        attr_reader :tempo
        alias bpm tempo

        # The tempo the onset autocorrelation chose before the beat grid
        # refined it (nil when the tempo was given).
        attr_reader :tempo_estimate

        # Beats (Structure::Beat) from the first one with sound to the last.
        attr_reader :beats

        # Bars (Structure::Bar) from the first downbeat on.
        attr_reader :bars

        # The meter map like Sequence::Transport#meters: Meter(pos, bar_length,
        # bar) entries, with +pos+ in whole notes from bar 1's downbeat.
        attr_reader :meters

        # How the beats were found: :transport (a known grid), :grid (a
        # constant-tempo grid fitted to the onsets), or :dp (the dynamic
        # programming tracker).
        attr_reader :tracker

        # Length of the audio in seconds, and its sample rate.
        attr_reader :duration, :sample_rate

        # Seconds spent in each step (a Hash).
        attr_reader :timings

        # The Frames the analysis worked on (for plots and later phases).
        attr_reader :frames

        def initialize(tempo:, tempo_estimate:, beats:, bars:, meters:, tracker:, duration:, sample_rate:, timings:, frames:)
          @tempo = tempo
          @tempo_estimate = tempo_estimate
          @beats = beats.freeze
          @bars = bars.freeze
          @meters = meters.freeze
          @tracker = tracker
          @duration = duration
          @sample_rate = sample_rate
          @timings = timings.freeze
          @frames = frames
        end

        # The downbeat times in seconds (the bars' starts).
        def downbeats
          @bars.map(&:seconds)
        end

        # The usual bar length in quarter-note beats (the most common one).
        def beats_per_bar
          @bars.map(&:beats).tally.max_by(&:last)&.first || 4
        end

        # Bars whose length differs from the usual one (e.g. a 2/4 gap bar
        # in 4/4).  The last bar is never irregular: it runs off the end of
        # the audio at the usual length.
        def irregular_bars
          usual = beats_per_bar
          @bars.reject { |b| b.beats == usual }
        end

        # A new Sequence::Transport at the analyzed tempo with the analyzed
        # meter map (position 0 is bar 1's downbeat).
        def transport
          t = Sequence::Transport.new(bpm: @tempo, bar_length: @meters.first&.bar_length || 1)
          @meters.drop(1).each { |m| t.meter(m.bar_length, at: m.pos) }
          t
        end

        # The bar position (a Float counting from 1, like
        # Sequence::Transport#bar_at) of time +seconds+ in the audio,
        # interpolated within bars and extrapolated at the usual length
        # outside them.
        def bar_at(seconds)
          return nil if @bars.empty?
          i = @bars.rindex { |b| b.seconds <= seconds }
          bar = i ? @bars[i] : @bars.first
          len = bar.end_seconds - bar.seconds
          bar.number + (seconds - bar.seconds) / len
        end

        # The time in seconds of bar position +bar+ (counting from 1;
        # fractions are parts of that bar), the inverse of #bar_at.
        def seconds_at(bar)
          return nil if @bars.empty?
          b = @bars.find { |x| x.number == bar.floor } || (bar < @bars.first.number ? @bars.first : @bars.last)
          b.seconds + (bar - b.number) * (b.end_seconds - b.seconds)
        end

        # Console commands that set the analyzed meter changes on a Session
        # (see FormMethods#meter), e.g. "meter 2, 4, at: bar(33)".
        def meters_ruby
          @meters.drop(1).map { |m|
            beats = m.bar_length * 4
            beats.denominator == 1 ? "meter #{beats.to_i}, 4, at: bar(#{m.bar})" : "meter #{m.bar_length.numerator}, #{m.bar_length.denominator}, at: bar(#{m.bar})"
          }.join("\n")
        end

        def to_s
          odd = irregular_bars.map { |b| "bar #{b.number}: #{b.meter}" }
          extra = odd.empty? ? '' : " (#{odd.join(', ')})"
          format('%.2f BPM, %d bars of %s%s from %.2f s, %s', @tempo, @bars.length,
            Sequence::Transport.meter_label(Rational(beats_per_bar, 4)), extra, @bars.first&.seconds || 0, @tracker)
        end

        def inspect
          "#<#{self.class} #{self}>"
        end
      end
    end
  end
end
