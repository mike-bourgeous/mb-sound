module MB
  module Sound
    module Mastering
      # What a mastering chain did to the music, for the mastering report
      # (omnibus19; Kez, persona panel 3: the report said "trim +40 dB into
      # the chain, 7 chain runs", and she wrote her own meter to find the
      # limiter ducking the sub 4-6 dB under every snare): the chain's gain
      # change over the render (its output against its input times the
      # trim, in WINDOW-second windows), typical and at most, the bars it
      # took the most off, and how far the gain below +low_hz+ swings within
      # a bar (the low end ducking under the hits of other parts: pumping).
      #
      # Measured on the mid (L + R) / 2; windows quieter than GATE_DB under
      # the loudest window are left out, as are low-band windows with no
      # low end.  The chain's lookahead (a few milliseconds) is small
      # against the window, so it is not aligned out.
      ChainEffect = Data.define(:typical, :most, :bars, :low_swing, :low_bar, :low_bar_swing, :low_hz) do
        # The report line (see Targeting::Result#to_s).
        def to_s
          most_bars = bars.empty? ? '' : " (#{bars.length == 1 ? 'bar' : 'bars'} #{bars.join(', ')})"
          text = format('what the chain did: %+.1f dB typical, at most %+.1f dB%s', typical, most, most_bars)
          if low_swing
            text += format('; below %d Hz the gain swings %.1f dB within a bar (median', low_hz, low_swing)
            text += low_bar ? format(', %.1f dB in bar %s)', low_bar_swing, low_bar) : ')'
            text += ': the low end ducks under the hits (pumping)' if low_swing >= ChainEffect::PUMPING_DB
          end
          text
        end
      end

      class ChainEffect
        # Window length (seconds).
        WINDOW = 0.05

        # Windows this far under the loudest one (dB) are left out.
        GATE_DB = 40

        # A median low-band swing within a bar this large (dB) reads as
        # pumping.
        PUMPING_DB = 3.0

        # Bars named for the most reduction.
        BARS_NAMED = 3

        # Measures +output+ (channels) against +input+ (channels, the chain's
        # input) at +trim+ (dB: a number, or a DFloat per frame), over
        # +bars+ ([[start, end] seconds], with +labels+ for them, e.g. the
        # song's bar numbers), at +sample_rate+, with the low band below
        # +low_hz+.  Returns a ChainEffect, or nil for silence.
        def self.measure(input, output, trim, sample_rate:, bars:, labels:, low_hz: 120)
          w = (WINDOW * sample_rate).round
          n = [input[0].length, output[0].length].min
          count = n / w
          return nil if count < 1

          mid = ->(chs) {
            m = Numo::DFloat.cast(chs[0][0...(count * w)])
            chs[1..].each { |c| m.inplace + Numo::DFloat.cast(c[0...(count * w)]) }
            m / chs.length
          }
          x = mid.(input)
          y = mid.(output)
          power = ->(s) { (s**2).reshape(count, w).mean(axis: 1) }
          low = ->(s) {
            f = Numo::Pocketfft.rfft(s)
            bin = (low_hz.to_f * s.length / sample_rate).floor + 1
            f[bin..] = 0 if bin < f.length
            Numo::Pocketfft.irfft(f)[0...s.length] # (an even length: count * w, w even at 48 kHz)
          }
          trim_db = trim.is_a?(Numo::NArray) ? Numo::DFloat.cast(trim[0...(count * w)]).reshape(count, w).mean(axis: 1) : Numo::DFloat.new(count).fill(trim.to_f)

          gr = ->(px, py) {
            top = px.max
            return [nil, nil] unless top > 0

            keep = (px > top * 10**(-GATE_DB / 10.0)) & (py > 0)
            g = Numo::DFloat.new(count).fill(Float::NAN)
            idx = keep.where
            g[idx] = Numo::NMath.log10(py[idx] / px[idx]) * 10 - trim_db[idx] unless idx.empty?
            [g, keep]
          }
          full, keep = gr.(power.(x), power.(y))
          return nil if full.nil? || keep.count_true == 0

          vals = full[keep.where].to_a.sort
          typical = vals[vals.length / 2]

          per_bar = bars.each_with_index.filter_map { |(a, b), i|
            idx = window_range(a, b, count)
            v = idx.map { |k| full[k] }.reject(&:nan?)
            v.empty? ? nil : [labels[i], v]
          }
          worst = per_bar.map { |label, v| [label, v.min] }
          most = worst.empty? ? vals.first : worst.map(&:last).min
          named = worst.sort_by(&:last).first(BARS_NAMED).select { |_, v| v < typical - 1.0 }.map(&:first)

          lfull, lkeep = gr.(power.(low.(x)), power.(low.(y)))
          low_swing = low_bar = low_bar_swing = nil
          if lfull && lkeep.count_true > 0
            swings = bars.each_with_index.filter_map { |(a, b), i|
              v = window_range(a, b, count).map { |k| lfull[k] }.reject(&:nan?)
              v.length < 2 ? nil : [labels[i], v.max - v.min]
            }
            unless swings.empty?
              s = swings.map(&:last).sort
              low_swing = s[s.length / 2]
              low_bar, low_bar_swing = swings.max_by(&:last)
            end
          end

          new(typical: typical.round(2), most: most.round(2), bars: named, low_swing: low_swing&.round(2), low_bar: low_bar,
            low_bar_swing: low_bar_swing&.round(2), low_hz: low_hz)
        end

        # The window indices (of +count+) inside [+a+, +b+) seconds.
        def self.window_range(a, b, count)
          ((a / WINDOW).ceil...[(b / WINDOW).floor, count].min)
        end
      end
    end
  end
end
