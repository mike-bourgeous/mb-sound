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

      # The result of Structure.analyze: the tempo, every beat, the bars
      # (including irregular ones), and the meter map (phase S1); the
      # sections with letter labels, the song as a Form, :analysis markers,
      # and a comparison with the form that played (phase S2).
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
          @section_analysis = nil
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

        # The song's sections (phase S2; Structure::Sections): an Array of
        # Structure::Section with letter labels ("A", "B", "A'") and flow
        # names (:a, :b, :a2), from the first bar to the last.  With
        # +options+ (Sections.find's: +cost:+ per boundary, +same:+ and
        # +variant:+ label similarities, ...), a new segmentation; without,
        # the default one (computed once).
        #
        #     s.sections.map(&:to_s)   # => ["A    bar 1, 8 bars at 0:00.00", ...]
        #     s.sections(cost: 0.2)    # fewer, longer sections
        def sections(**options)
          return Sections.find(self, **options)[0] unless options.empty?
          section_analysis[0]
        end

        # The default segmentation's workings: { features:, ssm:, novelty:,
        # boundaries: } (see Sections.find), for plots.
        def section_details
          section_analysis[1]
        end

        # The sections' labels in order ("A", "B", "A'", ...).
        def labels
          sections.map(&:label)
        end

        # The sections as a linear MB::Sound::Form (a flow): one section per
        # flow name, each lasting its bars, played in order (a section
        # repeated right away plays with times:; one coming back at another
        # length plays with its own length).  `form.to_ruby` prints the
        # `flow do ... end` block; #flow_ruby prints one with comments.
        def form(sections = self.sections)
          defs = {}
          order = Result.runs(sections).map { |s, count|
            defs[s.name] ||= Form::Section.new(name: s.name, length: s.bars)
            own = defs[s.name].length == s.bars ? nil : s.bars
            Form::Play.new(name: s.name, times: count > 1 ? count : nil, length: own)
          }
          Form.new(sections: defs, order: order)
        end

        # [[section, count], ...]: runs of the same section at the same
        # length (one flow line each).
        def self.runs(sections)
          sections.chunk_while { |a, b| a.name == b.name && a.bars == b.bars }.map { |r| [r.first, r.length] }
        end

        # Ruby for the analyzed song: a `bpm` line, the meter changes
        # (#meters_ruby), and the flow (#form) with each line's label,
        # first bar, and start time as comments.
        def flow_ruby
          secs = sections
          lines = form(secs).to_ruby.lines.map(&:chomp)
          width = lines[1...-1].map(&:length).max || 0
          body = lines[1...-1].zip(Result.runs(secs)).map { |line, (s, _)|
            "#{line.ljust(width)}  # #{s.label.ljust(4)} bar #{s.first_bar}, #{Structure.clock(s.seconds)}"
          }
          meters = meters_ruby
          ["bpm #{format('%.2f', @tempo).sub(/\.?0+\z/, '')}", (meters unless meters.empty?), lines.first, *body, lines.last].compact.join("\n")
        end

        # The marker names #markers! sets, in section order:
        # :"analysis/a_1", :"analysis/b_1", :"analysis/a_2", ... (+prefix+
        # first; numbers keep a name's passes apart).
        def marker_names(prefix: :analysis)
          count = Hash.new(0)
          sections.map { |s| :"#{prefix}/#{s.name}_#{count[s.name] += 1}" }
        end

        # Puts the sections into +session+'s marker table as :analysis
        # markers (see #marker_names), each where its first downbeat plays
        # when the audio starts at session bar +at+ (1 by default): on our
        # renders (the render's grid) the bar's exact position, else its
        # time in the audio at the analyzed tempo.  Earlier markers with
        # the same prefix are removed first, so analyzing again replaces
        # them.  `seek :"analysis/b_1"`, `at_marker`, and `render(from:)`
        # work on them.  Warns when the session's tempo differs from the
        # analysis' (the markers then don't line up with the audio).
        # Returns the Session::Markers::Marker entries set.
        def markers!(session: Session.current, at: 1, prefix: :analysis)
          if (session.transport.bpm - @tempo).abs > @tempo * 0.005
            warn "markers!: the session plays at #{format('%.2f', session.transport.bpm)} BPM, the analysis found #{format('%.2f', @tempo)} " \
                 "(`bpm #{format('%.2f', @tempo).sub(/\.?0+\z/, '')}` lines the markers up with the audio)"
          end
          table = session.markers
          table.to_h.each_key { |k| table.delete(k) if k.to_s.start_with?("#{prefix}/") }
          origin = session.transport.bar_position(at)
          grid = transport if @tracker == :transport
          sections.zip(marker_names(prefix: prefix)).map { |s, name|
            pos = grid ? grid.bar_position(s.first_bar) : Rational((s.seconds * @tempo / 240 * 3840).round, 3840)
            table.set(name, kind: :analysis, pos: origin + pos)
          }
        end

        # Compares the sections with +expected+, a Form (`take.form`, the
        # flow a render played) or an Array of [name, bars] pairs, whose
        # first section starts at bar +from+: a Structure::Comparison of
        # the boundaries (within +tolerance+ bars) and the labels.
        #
        #     analyze_form(bars: 40) { ...; flow { ... } }.compare(take.form)
        def compare(expected, from: 1, tolerance: 1)
          Comparison.of(self, expected, from: from, tolerance: tolerance)
        end

        def to_s
          odd = irregular_bars.map { |b| "bar #{b.number}: #{b.meter}" }
          extra = odd.empty? ? '' : " (#{odd.join(', ')})"
          secs = @section_analysis ? ", #{labels.join(' ')}" : ''
          format('%.2f BPM, %d bars of %s%s from %.2f s, %s%s', @tempo, @bars.length,
            Sequence::Transport.meter_label(Rational(beats_per_bar, 4)), extra, @bars.first&.seconds || 0, @tracker, secs)
        end

        private

        def section_analysis
          @section_analysis ||= Sections.find(self)
        end

        public

        def inspect
          "#<#{self.class} #{self}>"
        end
      end
    end
  end
end
