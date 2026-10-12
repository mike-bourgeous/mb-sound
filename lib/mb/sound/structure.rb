require_relative 'structure/frames'
require_relative 'structure/tempo'
require_relative 'structure/beats'
require_relative 'structure/meter'
require_relative 'structure/result'

module MB
  module Sound
    # Music structure analysis: audio in, its tempo, beats, bars, and meter
    # out (phase S1; phase S2 adds sections, labels, forms, and markers).
    # Pure Ruby + Numo; a three-minute song takes about a second and a half.
    # Most code uses StructureMethods#analyze_form.
    #
    # The method (from the research spike on branch
    # research-structure-analysis, research/structure-analysis/README.md):
    # frame features (Frames), an onset envelope in three bands, the tempo
    # from a comb over the envelope's autocorrelation (Tempo), beats from a
    # constant-tempo grid (default) or Ellis's dynamic programming tracker
    # (Beats), and downbeats from a Viterbi over the position in the bar
    # that allows 2- and 3-beat bars (Meter).
    #
    # For our own renders, a known grid (a Transport or Session; see
    # +:grid+) skips the tempo and beat tracking and the meter Viterbi:
    # beats and bars come from the timeline exactly.
    #
    # Known limits: one constant tempo; 4/4 with occasional short bars
    # unless +:beats_per_bar+ says otherwise; syncopated drums with more
    # onset energy off the beat than on it (the drums_808 song's kick and
    # accented offbeat hats) put the grid half a beat late.
    module Structure
      # How much earlier than the true beat the onset envelope's peak lands
      # (seconds): a Hann window's spectral flux rises as the leading half
      # of the window takes in a transient.  Measured on generated drum
      # renders (see #analyze's +:offset+).
      ONSET_LATENCY = 0.0

      # Analyzes +data+ (an Array of channels, one Numo array, or a sound
      # filename read at +sample_rate+) and returns a Structure::Result.
      #
      # +:sample_rate+ - The audio's sample rate (files are resampled to it).
      # +:bpm+ - A tempo hint that replaces the tempo estimate; the grid
      #          still refines the period within +-+:refine+ (relative;
      #          false or 0 to use the tempo exactly).
      # +:grid+ - A Sequence::Transport, or a Session (its transport), whose
      #           timeline position 0 is at +:start+ seconds in the audio:
      #           beats and bars come from its tempo and meter map, with no
      #           tracking.  For audio we rendered ourselves.
      # +:beats+ - :grid (a constant-tempo grid, the default) or :dp
      #            (Ellis's tracker, for a moving tempo).
      # +:beats_per_bar+ - The usual bar length in beats (4).
      # +:short_bars+ - Bar lengths (in beats) allowed besides the usual one
      #                 ([2, 3]; [] for none).
      # +:downbeat_penalty+ - The Viterbi's cost of a short bar (15).
      # +:phase_weights+ - Weights of the low, mid, and high onset bands
      #                    when choosing the grid's phase ([4, 1, 1]).
      # +:offset+ - Seconds added to tracked beat times (ONSET_LATENCY).
      # +:min_bpm+, +:max_bpm+, +:center_bpm+ - The tempo search range and
      #                                         the prior's center.
      def self.analyze(data, sample_rate: 48000, bpm: nil, refine: 0.005, grid: nil, start: 0,
        beats: :grid, beats_per_bar: 4, short_bars: [2, 3], downbeat_penalty: 15.0,
        phase_weights: [4, 1, 1], tightness: 100, offset: ONSET_LATENCY,
        min_bpm: 50, max_bpm: 220, center_bpm: 120)
        raise ArgumentError, "beats: must be :grid or :dp (got #{beats.inspect})" unless [:grid, :dp].include?(beats)
        raise ArgumentError, "beats_per_bar: must be an Integer of at least 2 (got #{beats_per_bar.inspect})" unless beats_per_bar.is_a?(Integer) && beats_per_bar >= 2
        raise ArgumentError, "bpm: must be a positive number (got #{bpm.inspect})" unless bpm.nil? || (bpm.is_a?(Numeric) && bpm > 0)

        timings = {}
        timed = ->(name, &block) {
          t = MB::U.clock_now
          result = block.call
          timings[name] = (timings[name] || 0) + MB::U.clock_now - t
          result
        }

        mono = timed.(:read) { mixdown(data, sample_rate) }
        frames = timed.(:features) { Frames.new(mono, sample_rate: sample_rate) }
        fps = frames.fps
        duration = mono.size / sample_rate.to_f
        onset = timed.(:features) { frames.onset }

        transport = grid.respond_to?(:transport) ? grid.transport : grid
        if transport
          raise ArgumentError, "grid: must be a Sequence::Transport or a Session (got #{grid.class})" unless transport.is_a?(Sequence::Transport)
          beat_list, bars, meters = timed.(:beats) { transport_grid(transport, onset, fps, start, duration) }
          return Result.new(tempo: transport.bpm, tempo_estimate: nil, beats: beat_list, bars: bars, meters: meters,
            tracker: :transport, duration: duration, sample_rate: sample_rate, timings: timings, frames: frames)
        end

        estimate = nil
        unless bpm
          estimate, = timed.(:tempo) { Tempo.estimate(onset, fps, min_bpm: min_bpm, max_bpm: max_bpm, center: center_bpm) }
          bpm = estimate
        end

        if beats == :grid
          range = refine ? refine.to_f : 0
          range = 0.01 if estimate && range < 0.01 # an estimate gets the spike's +-1 % search
          beat_frames, tempo = timed.(:beats) { Beats.grid(onset, frames.phase_onset(phase_weights), bpm, fps, range: range) }
        else
          beat_frames = timed.(:beats) { Beats.dp(onset, bpm, fps, tightness: tightness) }
          period = Beats.fit_period(beat_frames)
          tempo = period ? 60 * fps / period : bpm
        end

        db = timed.(:downbeats) {
          obs = Meter.observations(frames, beat_frames)
          Meter.downbeats(obs, beats_per_bar: beats_per_bar, short_bars: short_bars, penalty: downbeat_penalty)
        }

        times = beat_frames.map { |f| f / fps + offset }
        beat_list, bars, meters = tracked_bars(times, db, beats_per_bar)
        Result.new(tempo: tempo, tempo_estimate: estimate, beats: beat_list, bars: bars, meters: meters,
          tracker: beats, duration: duration, sample_rate: sample_rate, timings: timings, frames: frames)
      end

      # A mono Numo::DFloat mix of +data+ (see .analyze).
      def self.mixdown(data, sample_rate)
        data = MB::Sound.read(data, sample_rate: sample_rate) if data.is_a?(String)
        chans = data.is_a?(Numo::NArray) ? [data] : data
        chans = [chans] if chans.is_a?(Array) && chans[0].is_a?(Numeric)
        raise ArgumentError, "Pass audio as an Array of channels, a Numo array, or a filename (got #{data.class})" unless chans.is_a?(Array) && chans.all? { |c| c.is_a?(Numo::NArray) || c.is_a?(Array) }
        raise ArgumentError, 'The audio is empty' if chans.empty? || chans[0].size == 0

        chans.map { |c| Numo::DFloat.cast(c) }.sum / chans.length
      end

      # Beats, bars, and meters from a known timeline: every quarter note
      # of +transport+'s tempo from +start+ seconds, numbered through its
      # meter map, trimmed to where +onset+ has sound.
      def self.transport_grid(transport, onset, fps, start, duration)
        spb = 60.0 / transport.bpm
        first = -(start / spb).floor
        last = ((duration - start) / spb).floor
        ks = (first..last).to_a
        frames = ks.map { |k| (start + k * spb) * fps }
        active = Beats.active(onset, frames, spb * fps)
        return [[], [], transport.meters] if active.empty?

        ks = ks[frames.index(active.first), active.length]
        beats = ks.map { |k|
          pos = Rational(k, 4)
          bar_pos = transport.bar_at(pos)
          bar = bar_pos.floor
          beat = (pos - transport.bar_position(bar)) * 4 + 1
          Beat.new(seconds: start + k * spb, bar: bar, beat: beat.denominator == 1 ? beat.to_i : beat)
        }

        seconds = ->(bar) { start + transport.bar_position(bar) * 4 * spb }
        first_bar = transport.bar_at(Rational(ks.first, 4)).ceil
        last_bar = transport.bar_at(Rational(ks.last, 4)).floor
        bars = (first_bar..last_bar).map { |n|
          len = transport.bar_length(transport.bar_position(n)) * 4
          Bar.new(number: n, seconds: seconds.(n), beats: len.denominator == 1 ? len.to_i : len, end_seconds: seconds.(n + 1))
        }
        [beats, bars, transport.meters]
      end

      # Beats, bars, and meters from tracked beat +times+ and downbeat beat
      # indices +db+.
      def self.tracked_bars(times, db, beats_per_bar)
        return [times.map { |t| Beat.new(seconds: t, bar: 0, beat: 1) }, [], [Sequence::Transport::Meter.new(pos: 0r, bar_length: Rational(beats_per_bar, 4), bar: 1)]] if db.empty?

        period = Beats.fit_period(times) || 0.5
        lengths = db.each_cons(2).map { |a, b| b - a } + [beats_per_bar]
        bar_of_beat = {}
        bars = db.each_with_index.map { |bi, n|
          len = lengths[n]
          len.times { |k| bar_of_beat[bi + k] = [n + 1, k + 1] }
          end_seconds = n + 1 < db.length ? times[db[n + 1]] : times[bi] + len * period
          Bar.new(number: n + 1, seconds: times[bi], beats: len, end_seconds: end_seconds)
        }

        pickup = db.first
        beats = times.each_with_index.map { |t, i|
          bar, beat = bar_of_beat[i] || [0, beats_per_bar - pickup + i + 1]
          Beat.new(seconds: t, bar: bar, beat: beat)
        }

        meters = []
        pos = 0r
        bars.each do |b|
          meters << Sequence::Transport::Meter.new(pos: pos, bar_length: b.length, bar: b.number) if meters.empty? || meters.last.bar_length != b.length
          pos += b.length
        end
        [beats, bars, meters]
      end
    end
  end
end
