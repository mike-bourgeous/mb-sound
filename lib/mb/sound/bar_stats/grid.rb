module MB
  module Sound
    module BarStats
      # The beats, bars, and sections that bar statistics are counted on:
      # Structure::Beat, Structure::Bar, and Structure::Section values (the
      # structure analysis's own types), in seconds from the start of the
      # audio.
      #
      # Where a grid comes from (+source+):
      # - :render, recorded while mb-sound rendered the song (Recorder):
      #   every beat lands on the frame the timeline crossed it, so tempo
      #   maps, ramps, meter changes, and render windows (`from:`) are
      #   exact, and sections are the song form's passes;
      # - :transport, a constant-tempo Transport's grid (Structure's);
      # - :tracked, beat tracking of outside audio (Structure.analyze,
      #   optionally with a +bpm:+ hint), sections from its analysis;
      # - :given, a constant grid from a user's +bpm:+ and +offset:+ (the
      #   first downbeat in seconds), for audio whose tempo is known.
      #
      #     g = BarStats::Grid.constant(bpm: 140, offset: 0.25, duration: 180)
      #     g.bars.first          # => #<Bar bar 1 (4/4) at 0.250 s>
      #     g.beat_spans          # => [[start, end], ...] seconds
      class Grid
        # Seconds of audio a constant grid's last beat needs after it.
        MIN_TAIL = 0.05

        attr_reader :beats, :bars, :sections, :source, :tempo, :duration

        # +beats+, +bars+, +sections+ as Structure values; +source+ as above;
        # +tempo+ the BPM (nil when it moved); +duration+ the audio's length
        # in seconds.
        def initialize(beats:, bars:, sections: [], source:, tempo:, duration:)
          @beats = beats.freeze
          @bars = bars.freeze
          @sections = sections.freeze
          @source = source
          @tempo = tempo
          @duration = duration.to_f
          @spans = nil
        end

        # A grid from a Structure::Result (Structure.analyze or
        # #analyze_form): its beats and bars, and with +sections+ its
        # sections (computed on first use; a few hundredths of a second
        # after the analysis).
        def self.from_structure(result, sections: true)
          new(beats: result.beats, bars: result.bars, sections: sections ? result.sections : [],
              source: result.tracker == :transport ? :transport : :tracked, tempo: result.tempo, duration: result.duration)
        end

        # A constant grid at +bpm+ with bar 1's downbeat at +offset+ seconds,
        # bars of +beats_per_bar+ quarter notes, covering +duration+
        # seconds (beats before +offset+ are a pickup in bar 0).
        def self.constant(bpm:, duration:, offset: 0, beats_per_bar: 4)
          raise ArgumentError, "bpm: must be positive (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm > 0
          raise ArgumentError, "beats_per_bar: must be a positive Integer (got #{beats_per_bar.inspect})" unless beats_per_bar.is_a?(Integer) && beats_per_bar > 0

          spb = 60.0 / bpm
          first = -(offset / spb + 1e-9).floor
          # (a beat with under MIN_TAIL seconds of audio after it is left
          # out: a song 133 bars long at 140.0001 BPM ends 8 samples into
          # bar 134)
          last = ((duration - MIN_TAIL - offset) / spb).ceil - 1
          beats = (first..last).map { |k|
            # (beats before the first downbeat are a pickup in bar 0)
            Structure::Beat.new(seconds: offset + k * spb, bar: k < 0 ? 0 : k / beats_per_bar + 1, beat: k % beats_per_bar + 1)
          }
          nbars = last < 0 ? 0 : last / beats_per_bar + 1
          bars = (1..nbars).map { |n|
            start = offset + (n - 1) * beats_per_bar * spb
            Structure::Bar.new(number: n, seconds: start, beats: beats_per_bar, end_seconds: start + beats_per_bar * spb)
          }
          new(beats: beats, bars: bars, source: :given, tempo: bpm, duration: duration)
        end

        # A grid from its Hash (#to_h; a sidecar's grid).
        def self.from_h(h)
          beats = h[:beats].map { |s, bar, beat| Structure::Beat.new(seconds: s, bar: bar, beat: beat) }
          bars = h[:bars].map { |n, s, b, e| Structure::Bar.new(number: n, seconds: s, beats: b, end_seconds: e) }
          sections = (h[:sections] || []).map { |label, first, count, s, e|
            Structure::Section.new(label: label, name: section_name(label), first_bar: first, bars: count, seconds: s, end_seconds: e,
                                   beats: bars.select { |b| b.number >= first && b.number < first + count }.sum(&:beats))
          }
          new(beats: beats, bars: bars, sections: sections, source: h[:source], tempo: h[:tempo], duration: h[:duration])
        end

        # A Symbol for a section label ("A'" => :a2 as Structure names
        # them, "drop 2" => :drop).
        def self.section_name(label)
          return Structure::Sections.name_of(label) if label.match?(/\A[A-Z]'*\z/)
          label.to_s.sub(/ \d+\z/, '').tr(' ', '_').to_sym
        end

        # The grid as plain values for a sidecar: beats as [seconds, bar,
        # beat], bars as [number, seconds, beats, end_seconds], sections as
        # [label, first_bar, bars, seconds, end_seconds].
        def to_h
          {
            source: @source, tempo: @tempo, duration: @duration,
            beats: @beats.map { |b| [b.seconds, b.bar, b.beat] },
            bars: @bars.map { |b| [b.number, b.seconds, b.beats, b.end_seconds] },
            sections: @sections.map { |s| [s.label, s.first_bar, s.bars, s.seconds, s.end_seconds] },
          }
        end

        # A copy with +sections+ (Structure::Section values) instead.
        def with_sections(sections)
          self.class.new(beats: @beats, bars: @bars, sections: sections, source: @source, tempo: @tempo, duration: @duration)
        end

        # A copy shifted +seconds+ later (beats, bars, and sections), for
        # audio that starts earlier than the audio the grid was made on.
        def shift(seconds)
          return self if seconds == 0
          beats = @beats.map { |b| b.with(seconds: b.seconds + seconds) }
          bars = @bars.map { |b| b.with(seconds: b.seconds + seconds, end_seconds: b.end_seconds + seconds) }
          sections = @sections.map { |s| s.with(seconds: s.seconds + seconds, end_seconds: s.end_seconds + seconds) }
          self.class.new(beats: beats, bars: bars, sections: sections, source: @source, tempo: @tempo, duration: @duration)
        end

        # [start, end] seconds of each beat: to the next beat, the last one
        # lasting the median beat (cut at the end of the audio).
        def beat_spans
          @spans ||= begin
            starts = @beats.map(&:seconds)
            gaps = starts.each_cons(2).map { |a, b| b - a }
            usual = gaps.empty? ? (@tempo ? 60.0 / @tempo : 0.5) : gaps.sort[gaps.length / 2]
            starts.each_with_index.map { |s, i| [s, i + 1 < starts.length ? starts[i + 1] : [s + usual, @duration].min] }.freeze
          end
        end

        # Indices of the beats in bar number +n+.
        def beats_in_bar(n)
          @beats.each_index.select { |i| @beats[i].bar == n }
        end

        # Indices of the beats starting inside +section+ (from its start to
        # its end).
        def beats_in_section(section)
          @beats.each_index.select { |i| @beats[i].seconds >= section.seconds - 1e-9 && @beats[i].seconds < section.end_seconds - 1e-9 }
        end

        # The usual beat length in seconds (the median).
        def beat_seconds
          spans = beat_spans
          return(@tempo ? 60.0 / @tempo : 0.5) if spans.empty?
          spans.map { |a, b| b - a }.sort[spans.length / 2]
        end

        def to_s
          t = @tempo ? format('%.2f BPM', @tempo) : 'a moving tempo'
          "#{@beats.length} beats, #{@bars.length} bars, #{@sections.length} sections at #{t} (#{@source})"
        end

        def inspect
          "#<BarStats::Grid #{self}>"
        end

        # Records a render's grid (render(..., bar_stats: true) attaches
        # one): a Session tap that, after each buffer, finds the quarter
        # notes the timeline crossed in it and the frame of each (exact
        # within a buffer of constant tempo; ramps change their tempo in
        # 800-frame cells, read here to a fraction of a sample), with
        # their bar and beat through the meter map, and the frames where
        # the song form's section passes start (MixReport::SectionMarks).
        # A seek (a buffer whose timeline moved more than JUMP off what its
        # tempo covers) counts the buffer as if it started where the
        # timeline would have to reach its end, so a beat in a buffer that
        # held a seek may land up to a buffer early or late.
        class Recorder
          # The share a buffer's timeline may move off its tempo's step
          # before it counts as a seek (tempo ramps move a few percent).
          JUMP = 0.1

          # The session frame where the file starts (a render window's
          # first written frame; 0 by default).
          attr_accessor :origin

          def initialize(session)
            @session = session
            @rate = session.output.sample_rate.to_f
            @origin = 0
            @marks = MixReport::SectionMarks.new(session)
            @beats = [] # [frame, Rational position]
            @pos = session.transport.position.to_r
            @frame = session.frame
            session.add_tap { |mix| note(mix.empty? || mix[0].nil? ? 0 : mix[0].length) }
          end

          # Notes the buffer of +count+ frames that just rendered.
          def note(count)
            f1 = @session.frame
            p1 = @session.transport.position.to_r
            f0 = f1 - count
            p0 = @pos
            p0 = p1 if f0 != @frame # (frames skipped: nothing to interpolate)
            # A seek in the buffer: count it from where the timeline would
            # have started the buffer to reach where it ended
            if p1 != p0 && count > 0
              step = @session.transport.whole_notes_per_frame(@rate) * count
              if ((p1 - p0) - step).abs > step * JUMP
                p0 = p1 - step
              end
            end
            @marks.note(f0, count, pos: p0)

            if p1 > p0 && count > 0
              # (each buffer counts the beats in [p0, p1): one at a buffer's
              # last position belongs to the next one)
              k = (p0 * 4).ceil
              while Rational(k, 4) < p1
                q = Rational(k, 4)
                @beats << [f0 + ((q - p0) / (p1 - p0) * count).to_f, q]
                k += 1
              end
            end
            @pos = p1
            @frame = f1
          end

          # The grid of a file of +frames+ frames written from #origin.
          def grid(frames)
            t = @session.transport
            duration = frames / @rate
            seconds = ->(f) { (f - @origin) / @rate }
            # (a beat in the file's last frame has nothing after it: a
            # render's end bar lands there, rounded up to a whole frame)
            list = @beats.select { |f, _| f - @origin >= -1e-6 && f - @origin < frames - 1 }
            beats = list.map { |f, q|
              bar = t.bar_at(q).floor
              beat = (q - t.bar_position(bar)) * 4 + 1
              Structure::Beat.new(seconds: [seconds.(f), 0.0].max, bar: bar, beat: beat.denominator == 1 ? beat.to_i : beat)
            }
            downs = beats.each_index.select { |i| beats[i].beat == 1 }
            bars = downs.each_with_index.map { |i, j|
              n = beats[i].bar
              len = t.bar_length(t.bar_position(n)) * 4
              len = len.denominator == 1 ? len.to_i : len
              stop =
                if j + 1 < downs.length
                  beats[downs[j + 1]].seconds
                else
                  last = beats.length - 1
                  step = last > i ? (beats[last].seconds - beats[i].seconds) / (last - i) : 60.0 / t.bpm
                  beats[i].seconds + len.to_f * step
                end
              Structure::Bar.new(number: n, seconds: beats[i].seconds, beats: len, end_seconds: stop)
            }

            bounds = @marks.boundaries.map { |f, label| [seconds.(f), label] }.select { |s, _| s < duration - 1e-9 }
            sections = bounds.each_with_index.filter_map { |(s, label), j|
              stop = j + 1 < bounds.length ? bounds[j + 1][0] : duration
              s = [s, 0.0].max
              inside = bars.select { |b| b.seconds >= s - 1e-6 && b.seconds < stop - 1e-6 }
              next if inside.empty?
              Structure::Section.new(label: label, name: Grid.section_name(label), first_bar: inside.first.number, bars: inside.length,
                                     seconds: s, end_seconds: stop, beats: inside.sum(&:beats))
            }

            tempos = list.each_cons(2).map { |(a, _), (b, _)| b - a }
            steady = tempos.empty? || (tempos.max - tempos.min) < 1e-6 * @rate
            Grid.new(beats: beats, bars: bars, sections: sections, source: :render,
                     tempo: steady ? (tempos.empty? ? t.bpm.to_f : 60.0 * @rate / tempos.first) : nil, duration: duration)
          end
        end
      end
    end
  end
end
