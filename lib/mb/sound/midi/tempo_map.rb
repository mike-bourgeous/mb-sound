module MB
  module Sound
    module MIDI
      # A MIDI file's tempo map (midi-import-1, 2026-10-28): every tempo
      # event of every track (the conductor track, usually), so pulse
      # (tick) times become the seconds they were recorded at, rubato and
      # tempo changes included.  Exact Rationals: seconds(p) sums each
      # tempo's span (microseconds per quarter / (1e6 * ppqn) a pulse).
      # Before the first tempo event, and in files without one, the tempo
      # is 120 BPM (the MIDI default).  Several tempo events on one pulse:
      # the last one counts.
      #
      # MIDI::FileSource and MIDIFile use it by default (FileSource's
      # ConstantTempo keeps the first tempo for the whole file).
      #
      #     map = MB::Sound::MIDI::TempoMap.from_sequence(midi_file.seq)
      #     map.seconds(960 * 4)   # four quarters in, at the tempos played
      #     map.bpm_at(0)          # 120.0
      class TempoMap
        # The default tempo of MIDI files: 120 BPM.
        DEFAULT_MICROSECONDS_PER_QUARTER = 500_000

        # Pulses per quarter note.
        attr_reader :ppqn

        # [[pulse, microseconds per quarter], ...] from pulse 0.
        attr_reader :tempos

        # Reads the tempo events of every track of a midilib Sequence.
        def self.from_sequence(seq)
          list = seq.tracks.each_with_index.flat_map { |t, ti|
            t.events.each_with_index.filter_map { |e, i| [e.time_from_start, ti, i, e.tempo] if e.is_a?(::MIDI::Tempo) }
          }.sort.map { |p, _ti, _i, mpq| [p, mpq] }
          new(list, ppqn: seq.ppqn)
        end

        # +tempos+ are [[pulse, microseconds per quarter], ...] in any order.
        def initialize(tempos, ppqn:)
          raise ArgumentError, "ppqn is a positive Integer (got #{ppqn.inspect})" unless ppqn.is_a?(Integer) && ppqn > 0
          by_pulse = {}
          tempos.sort_by(&:first).each do |p, mpq|
            raise ArgumentError, "Tempo events are [pulse, microseconds per quarter] (got #{[p, mpq].inspect})" unless p.is_a?(Integer) && p >= 0 && mpq.is_a?(Integer) && mpq > 0
            by_pulse[p] = mpq
          end
          by_pulse[0] ||= DEFAULT_MICROSECONDS_PER_QUARTER
          @ppqn = ppqn
          @tempos = by_pulse.sort.map(&:freeze).freeze
          @pulses = @tempos.map(&:first).freeze
          # Seconds at the start of each tempo span
          t = 0r
          @starts = @tempos.each_with_index.map { |(p, mpq), i|
            if i > 0
              pp, pmpq = @tempos[i - 1]
              t += (p - pp) * Rational(pmpq, 1_000_000 * ppqn)
            end
            t
          }.freeze
          freeze
        end

        # True if the file changes tempo.
        def changes?
          @tempos.length > 1
        end

        # Rational seconds at +pulses+ from the start of the file.
        def seconds(pulses)
          i = span_index(pulses)
          p, mpq = @tempos[i]
          @starts[i] + (pulses - p) * Rational(mpq, 1_000_000 * @ppqn)
        end

        # The pulse (a Rational) at +seconds+ from the start.
        def pulses(seconds)
          i = (@starts.bsearch_index { |s| s > seconds } || @starts.length) - 1
          i = 0 if i < 0
          p, mpq = @tempos[i]
          p + (seconds.to_r - @starts[i]) / Rational(mpq, 1_000_000 * @ppqn)
        end

        # The tempo at +pulses+ in beats (quarter notes) per minute.
        def bpm_at(pulses)
          60_000_000.0 / @tempos[span_index(pulses)][1]
        end

        def to_s
          "TempoMap(#{@tempos.length} tempo#{'s' unless @tempos.length == 1}, #{MB::M.sigfigs(bpm_at(0), 5)} BPM first)"
        end

        private

        def span_index(pulses)
          i = (@pulses.bsearch_index { |p| p > pulses } || @pulses.length) - 1
          i < 0 ? 0 : i
        end
      end
    end
  end
end
