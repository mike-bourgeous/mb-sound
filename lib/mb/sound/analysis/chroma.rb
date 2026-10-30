module MB
  module Sound
    module Analysis
      # A chromagram: how much of each pitch class (C = 0 ... B = 11) sounds
      # in each frame of a mono signal, from STFT magnitudes folded onto the
      # octave.  The long-term fold (#fold, summed over frames) is what key
      # detection reads (Analysis::Key); Structure::Frames folds its own
      # 2048-point frames with the same map (.map) for harmony changes.
      #
      # Defaults are for keys: a 16384-point window (2.9 Hz bins at 48 kHz,
      # fine enough to tell semitones apart down to about 65 Hz, C2) every
      # 4096 samples, from 65 Hz to 5 kHz.  Each frame folds first onto 120
      # bins an octave (10 cents each); the tuning is the circular mean of
      # that fine fold (+tuning: :auto+), and the 12 pitch classes sum the
      # fine bins within half a semitone of each tuned semitone, so detuned
      # loops fold onto the right pitch classes.
      #
      #     c = Analysis::Chroma.new(mono, sample_rate: 48000)
      #     c.fold      # => 12 shares summing to 1, C first
      #     c.tuning    # => cents re A = 440 Hz, e.g. -12.0
      #     c.frames    # => frames x 12 (Numo::DFloat)
      class Chroma
        N_FFT = 16384
        HOP = 4096
        RANGE = 65.0..5000.0

        # Fine bins per octave (10 cents each) for the tuning.
        FINE = 120

        # Pitch class names (sharps), C first.
        NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

        # The fold map (bins x +bins+) for an +n_fft+-point spectrum at
        # +sample_rate+: bins in +range+ (Hz) split linearly between their
        # two nearest fold bins (+bins+ per octave, 12 for semitones; bin 0
        # is C), +tuning+ cents re A = 440 Hz.
        def self.map(n_fft, sample_rate, range, bins: 12, tuning: 0)
          f = STFT.bin_freqs(n_fft, sample_rate).to_a
          m = Numo::DFloat.zeros(f.length, bins)
          a4 = tuning == 0 ? 440.0 : 440.0 * 2**(tuning / 1200.0)
          f.each_with_index do |fr, k|
            next unless range.cover?(fr)
            midi = 69 + 12 * Math.log2(fr / a4)
            pos = bins == 12 ? midi : midi * bins / 12.0
            lo = pos.floor
            w = pos - lo
            m[k, lo % bins] += 1 - w
            m[k, (lo + 1) % bins] += w
          end
          m
        end

        # [first, last + 1] indices of the +n_fft+-point spectrum's bins
        # inside +range+ (Hz).
        def self.bin_span(n_fft, sample_rate, range)
          hz = sample_rate.to_f / n_fft
          lo = (range.begin / hz).ceil
          hi = [(range.end / hz).floor + 1, n_fft / 2 + 1].min
          [lo, [hi, lo].max]
        end

        # The tuning in cents re A = 440 Hz (-50...50) of a fine fold
        # (FINE bins an octave, bin 0 on C at A = 440 Hz): the circular mean
        # of the bins' deviations from their nearest semitone, weighted by
        # the squared fold (so the peaks count, not the floor between
        # them).  0.0 for silence.
        def self.tuning_of(fine)
          per = fine.size / 12
          x = y = 0.0
          fine.to_a.each_with_index do |v, i|
            w = v * v
            phase = 2 * Math::PI * i / per
            x += w * Math.cos(phase)
            y += w * Math.sin(phase)
          end
          return 0.0 if x.abs < 1e-30 && y.abs < 1e-30
          (Math.atan2(y, x) / (2 * Math::PI) * 100).round(1)
        end

        # Folds fine rows (frames x FINE) onto 12 pitch classes at +tuning+
        # cents: each pitch class sums the fine bins within half a semitone
        # of its tuned center (the edge bins half), read between bins for
        # a fractional shift.
        def self.fold_fine(fine, tuning)
          per = fine.shape[-1] / 12
          shift = tuning / 100.0 * per
          base = shift.floor
          frac = shift - base
          # Weights over offsets -per/2..per/2 from the center (halves at
          # the edges), spread over two bins for the fractional shift
          half = per / 2
          taps = Hash.new(0.0)
          (-half..half).each do |o|
            w = o.abs == half ? 0.5 : 1.0
            taps[o + base] += w * (1 - frac)
            taps[o + base + 1] += w * frac
          end
          rows = fine.ndim == 1 ? fine.reshape(1, fine.size) : fine
          out = Numo::DFloat.zeros(rows.shape[0], 12)
          12.times do |p|
            taps.each do |o, w|
              next if w == 0
              out[true, p] += rows[true, (p * per + o) % fine.shape[-1]] * w
            end
          end
          fine.ndim == 1 ? out[0, true] : out
        end

        # Sample rate, window, hop, frequency range, and the tuning used
        # (cents re A = 440 Hz).
        attr_reader :sample_rate, :n_fft, :hop, :range, :tuning

        # The chromagram (frames x 12, Numo::DFloat; magnitudes, not
        # normalized), and the fine fold it came from (frames x FINE).
        attr_reader :frames, :fine

        # Computes the chromagram of +mono+ (a Numo array or an Array of
        # channels, mixed down).  +tuning+ is :auto (estimated) or cents.
        def initialize(mono, sample_rate: 48000, n_fft: N_FFT, hop: HOP, range: RANGE, tuning: :auto)
          mono = Analysis.mono(mono)
          @sample_rate = sample_rate.to_f
          @n_fft = n_fft
          @hop = hop
          @range = range
          # Only the bins inside +range+ fold (a fifth of a 16384-point
          # spectrum for 65 Hz to 5 kHz)
          lo, hi = Chroma.bin_span(n_fft, @sample_rate, range)
          map = Chroma.map(n_fft, @sample_rate, range, bins: FINE)[lo...hi, true]
          @fine = Numo::DFloat.zeros(STFT.count(mono.length, hop), FINE)
          STFT.each_chunk(mono, n_fft: n_fft, hop: hop) { |rows, mag| @fine[rows, true] = mag[true, lo...hi].dot(map) }
          @tuning = tuning == :auto ? Chroma.tuning_of(@fine.sum(axis: 0)) : tuning.to_f
          @frames = Chroma.fold_fine(@fine, @tuning)
        end

        # Frames per second.
        def fps
          @sample_rate / @hop
        end

        # The long-term pitch class profile: the chromagram summed over
        # frames, as 12 shares summing to 1 (C first; zeros for silence).
        # +from+/+to+ (seconds) fold part of the signal.
        def fold(from: nil, to: nil)
          lo = from ? (from * fps).round.clamp(0, @frames.shape[0]) : 0
          hi = to ? (to * fps).round.clamp(lo, @frames.shape[0]) : @frames.shape[0]
          return Numo::DFloat.zeros(12) if hi <= lo
          v = @frames[lo...hi, true].sum(axis: 0)
          total = v.sum
          total > 0 ? v / total : v
        end

        # The pitch class profile as { "C" => share, ... }, for printing.
        def to_h
          NAMES.zip(fold.to_a.map { |v| v.round(4) }).to_h
        end

        def inspect
          top = to_h.max_by(3, &:last).map { |n, v| "#{n} #{(v * 100).round}%" }
          "#<#{self.class} #{@frames.shape[0]} frames, tuning #{format('%+.0f', @tuning)} cents, #{top.join(', ')}>"
        end
      end
    end
  end
end
