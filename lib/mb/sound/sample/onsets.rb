module MB
  module Sound
    class Sample
      # Transient (onset) detection for Sample#slices(:onsets) and
      # Sample#onsets: a high-frequency energy envelope (the energy of the
      # first difference, so drums' attacks stand out) in frames of +window+
      # samples every +hop+, onsets where it rises by more than +threshold+
      # dB from one frame to the next while within +floor+ dB of the loudest
      # frame, at least +min_gap+ (seconds or a Length) apart, each placed on
      # the first sample of its frame's attack that reaches a fifth of the
      # attack's peak (then back to the last quieter sample before it).
      # +threshold+ and +floor+ are written in dB (`9.db`, `-45.db`; bare
      # numbers are linear gains, see Decibels.db_of).  Pure Ruby and Numo; returns sample positions from the region start
      # in play order.
      module Onsets
        module_function

        def detect(sample, threshold: 9.db, floor: -45.db, min_gap: 0.04, hop: 64, window: 256)
          threshold = Decibels.db_of(threshold, 'threshold')
          floor = Decibels.db_of(floor, 'floor', zero: true)
          x = sample.to_a.sum / sample.channel_count
          x = Numo::DFloat.cast(x)
          n = x.length
          return [0] if n < window * 2

          d = Numo::DFloat.zeros(n)
          d[1..] = x[1..] - x[0...-1]
          c = Numo::DFloat.zeros(n + 1)
          c[1..] = (d * d).cumsum

          frames = (n - window) / hop + 1
          starts = Numo::Int64.new(frames).seq * hop
          e = c[starts + window] - c[starts]
          db = 10 * Numo::NMath.log10(e + 1e-20)
          top = db.max
          gap = sample.position(min_gap).round

          # The rise over one window (a new attack fills the window over
          # window / hop frames), peaks of it above the threshold
          lag = MB::M.max(window / hop, 1)
          rise = Numo::DFloat.zeros(frames)
          rise[lag..] = db[lag..] - db[0...-lag] if frames > lag
          found = []
          found << 0 if db[0] > top + floor # a sound that starts loud
          (lag...frames).each do |k|
            r = rise[k]
            next unless r > threshold && db[k] > top + floor
            next unless r >= rise[k - 1] && (k + 1 >= frames || r > rise[k + 1])

            pos = attack(x, MB::M.max((k - lag) * hop + window - hop, 0), window * 2)
            next if found.any? && pos - found.last < gap
            found << pos
          end
          found
        end

        # The onset sample of an attack in the +window+ samples from
        # +from+: the first sample whose change from the last (the attack's
        # high frequencies; low ringing from earlier hits changes slowly)
        # reaches a quarter of the largest change in the window.
        def attack(x, from, window)
          to = MB::M.min(from + window, x.length)
          return from if to - from < 2
          d = (x[(from + 1)...to] - x[from...(to - 1)]).abs
          peak = d.max
          return from if peak <= 0
          from + 1 + (d >= peak * 0.25).where[0]
        end
      end
    end
  end
end
