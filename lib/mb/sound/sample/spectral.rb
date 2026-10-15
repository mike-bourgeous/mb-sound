require 'numo/pocketfft'

module MB
  module Sound
    class Sample
      # Frequency-domain time-stretching for Sample#stretch (see
      # design/notes/granular.md): a phase vocoder with identity phase
      # locking and transient handling (mode: :spectral), and Paulstretch
      # (mode: :paul).  Offline, vectorized with Numo and Pocketfft; every
      # function takes and returns an Array of channels (DFloats).
      module Spectral
        # Stretch modes (Sample#stretch) and their other names.
        MODES = [:cyclic, :spectral, :paul].freeze
        MODE_ALIASES = { pv: :spectral, vocoder: :spectral, phase_vocoder: :spectral, paulstretch: :paul, lofi: :cyclic, s950: :cyclic }.freeze

        # The phase vocoder's default window (samples) and overlap.
        WINDOW = 4096
        OVERLAP = 4

        # Paulstretch's default window (seconds).
        PAUL_WINDOW = 0.25

        TWO_PI = 2 * Math::PI

        # How much a bin's magnitude must grow from one frame to the next
        # near an onset for the phase vocoder to reset its phase (2: 6 dB).
        RESET_RISE = 2.0

        module_function

        # +mode+ as a MODES name.
        def mode_name(mode)
          m = mode.to_sym
          m = MODE_ALIASES.fetch(m, m)
          raise ArgumentError, "Unknown stretch mode #{mode.inspect} (#{(MODES + MODE_ALIASES.keys).map(&:inspect).join(', ')})" unless MODES.include?(m)
          m
        end

        # Window shapes for the spectral stretches (+shape:+): :hann, and
        # :paul, Nasca Paul's (1 - x²)^1.25 from the Python Paulstretch
        # (flatter on top: frames add up over a narrower band, so random
        # phases smear each partial over about 2/3 the bandwidth of Hann's).
        SHAPES = [:hann, :paul].freeze

        # The +shape+ (SHAPES) window of +n+ samples.
        def shaped_window(shape, n)
          case shape
          when :hann then hann(n)
          when :paul then (1 - Numo::DFloat.linspace(-1, 1, n)**2)**1.25
          else raise ArgumentError, "Unknown window shape #{shape.inspect} (#{SHAPES.map(&:inspect).join(', ')})"
          end
        end

        # A periodic Hann window of +n+ samples.
        def hann(n)
          Numo::DFloat.new(n).seq.tap { |x| x.inplace * (TWO_PI / n) }.then { |x| (1 - Numo::NMath.cos(x)) * 0.5 }
        end

        # The +n+ samples of +x+ centered on +center+ (zeros outside).
        def segment(x, center, n)
          s = center - n / 2
          out = Numo::DFloat.zeros(n)
          a = [s, 0].max
          b = [s + n, x.length].min
          out[(a - s)...(b - s)] = x[a...b] if b > a
          out
        end

        # Phase vocoder stretch of +channels+ by +ratio+ (see
        # design/notes/granular.md): +shape+ (SHAPES; Hann) windows of
        # +window+ samples,
        # +overlap+ frames per window, identity phase locking around
        # spectral peaks, one phase rotation (computed on the channels'
        # mix) for every channel, and +onsets+ (sample positions; nil for
        # none) landing at +ratio+ times their time with their attacks
        # unstretched (#time_map).  +randomize+ (0..1) adds a random offset
        # of up to ± randomize × π to every output phase each frame (from
        # +seed+; the same offsets for every channel with +link+, else
        # each channel its own), so 0 is the phase-locked vocoder and 1 is
        # Paulstretch (uniformly random phases; #paul does that case);
        # attack bins near onsets stay unrandomized.
        def vocoder(channels, ratio, window: WINDOW, overlap: OVERLAP, onsets: nil, randomize: 0, seed: 0, link: true, shape: :hann)
          randomize = randomize.to_f
          raise ArgumentError, "randomize: is 0..1 (got #{randomize})" unless randomize >= 0 && randomize <= 1
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          n = Integer(window)
          raise ArgumentError, "The window must be an even number of samples, 64 or more (got #{window})" unless n >= 64 && n.even?
          hs = n / Integer(overlap)
          raise ArgumentError, 'The overlap must leave a hop of at least 8 samples' unless hs >= 8

          xs = channels.map { |c| Numo::DFloat.cast(c) }
          len = xs[0].length
          out_len = (len * ratio).round
          mix = xs.length == 1 ? xs[0] : xs.sum / xs.length
          map, resets = time_map(len, ratio, onsets, n, hs)
          w = shaped_window(shape, n)
          nb = n / 2 + 1
          omega = Numo::DFloat.new(nb).seq * (TWO_PI / n)
          hr = n / 8 # the fixed offset for instantaneous frequencies

          frames = out_len / hs + 2
          buf = Array.new(xs.length) { Numo::DFloat.zeros(frames * hs + n) }
          wsum = Numo::DFloat.zeros(frames * hs + n)
          w2 = w * w
          # Partly random frames add partly in amplitude, partly in power:
          # the mean of a frame's random phase offsets' unit vectors (its
          # coherence, sinc(randomize)), summed with the windows for #finish
          c = randomize > 0 ? Math.sin(Math::PI * randomize) / (Math::PI * randomize) : 1.0
          csum = Numo::DFloat.zeros(wsum.length) if randomize > 0
          c2sum = Numo::DFloat.zeros(wsum.length) if randomize > 0

          theta = nil
          phi_prev = nil
          mag_prev = nil
          prev_center = nil
          attack_until = nil
          ri = 0

          frames.times do |m|
            center = map.call(m * hs).round
            spec = Numo::Pocketfft.rfft(segment(mix, center, n) * w)
            phi = spec.arg
            mag = spec.abs

            while ri < resets.length && center + n / 2 > resets[ri]
              attack_until = resets[ri] + n / 2
              ri += 1
            end

            if theta.nil?
              theta = phi.dup
            else
              ha = center - prev_center
              if ha == hs
                # Unstretched frames (around transients): the exact phase
                # difference over the real hop, so the frames rebuild the
                # input
                winst_h = omega * hs + princarg(phi - phi_prev - omega * hs)
              else
                ref = Numo::Pocketfft.rfft(segment(mix, center - hr, n) * w).arg
                winst_h = (omega + princarg(phi - ref - omega * hr) / hr) * hs
              end
              theta = lock(theta + winst_h, phi, mag)
              if attack_until && center < attack_until
                # Frames holding an onset: bins whose level jumps (the
                # attack) take their analysis phases, so the attack is
                # rebuilt as it was; steady bins (a bass note ringing
                # through) keep their phases, so nothing cancels
                rising = mag.gt(mag_prev * RESET_RISE)
                theta[rising] = phi[rising] if rising.count_true > 0
              end
            end
            phi_prev = phi
            mag_prev = mag
            prev_center = center

            rot = theta - phi
            # (frames holding an attack stay unrandomized: crisp attacks
            # even in Paulstretch)
            random = randomize > 0 && !(attack_until && center < attack_until)
            rotc = nil
            pos = m * hs
            xs.each_with_index do |x, ch|
              if random && (rotc.nil? || !link)
                r = rot + (random_phases(seed, m, nb, link ? 0 : ch) - 0.5) * (TWO_PI * randomize)
                rotc = Numo::DComplex.cast(Numo::NMath.cos(r)) + Numo::NMath.sin(r) * Complex::I
              end
              rotc ||= Numo::DComplex.cast(Numo::NMath.cos(rot)) + Numo::NMath.sin(rot) * Complex::I
              cs = ch == 0 && xs.length == 1 ? spec : Numo::Pocketfft.rfft(segment(x, center, n) * w)
              y = Numo::Pocketfft.irfft(cs * rotc) * w
              buf[ch][pos...(pos + n)] += y
            end
            wsum[pos...(pos + n)] += w2
            if randomize > 0
              cm = random ? c : 1.0
              csum[pos...(pos + n)] += w2 * cm
              c2sum[pos...(pos + n)] += w2 * (cm * cm)
            end
          end

          return finish(buf, wsum, n, out_len) if randomize == 0

          finish(buf, wsum, n, out_len, power: w2.mean.to_f, coherent: csum, coherent2: c2sum)
        end

        # Identity phase locking (Laroche & Dolson 1999): peak bins keep
        # +advanced+ (their phases moved on by their frequencies); every
        # other bin takes its peak's phase plus its own analysis phase
        # offset from the peak (+phi+), regions split midway between
        # peaks of +mag+.
        def lock(advanced, phi, mag)
          nb = mag.length
          return advanced if nb < 5

          c = mag[2...(nb - 2)]
          is_peak = (c > mag[1...(nb - 3)]) & (c > mag[0...(nb - 4)]) & (c >= mag[3...(nb - 1)]) & (c >= mag[4...nb])
          peaks = is_peak.where + 2
          return advanced if peaks.empty?

          marker = Numo::Int32.zeros(nb)
          if peaks.length > 1
            bounds = ((peaks[0...-1] + peaks[1..]) / 2) + 1
            marker[bounds] = 1
          end
          owner = peaks[marker.cumsum]
          advanced[owner] + (phi - phi[owner])
        end

        # Paulstretch (Nasca Paul) of +channels+ by +ratio+: +shape+ (Hann)
        # windows of +window+ samples hopping 1 / +overlap+ window in the output, every
        # bin's magnitude kept and its phase replaced by a random one from
        # +seed+ (shared by the channels with +link+, else each channel its
        # own, like the original).
        def paul(channels, ratio, window:, overlap: OVERLAP, seed: 0, link: true, shape: :hann)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          n = Integer(window)
          n += 1 if n.odd?
          raise ArgumentError, "The window must be 64 samples or more (got #{window})" unless n >= 64
          hs = n / Integer(overlap)
          raise ArgumentError, 'The overlap must leave a hop of at least 8 samples' unless hs >= 8 && overlap >= 2

          xs = channels.map { |c| Numo::DFloat.cast(c) }
          len = xs[0].length
          out_len = (len * ratio).round
          w = shaped_window(shape, n)
          nb = n / 2 + 1
          frames = out_len / hs + 2
          buf = Array.new(xs.length) { Numo::DFloat.zeros(frames * hs + n) }
          wsum = Numo::DFloat.zeros(frames * hs + n)
          w2 = w * w

          frames.times do |m|
            center = (m * hs / ratio.to_f).round
            rot = nil
            pos = m * hs
            xs.each_with_index do |x, ch|
              if rot.nil? || !link
                ph = random_phases(seed, m, nb, link ? 0 : ch) * TWO_PI
                rot = Numo::DComplex.cast(Numo::NMath.cos(ph)) + Numo::NMath.sin(ph) * Complex::I
              end
              mag = Numo::Pocketfft.rfft(segment(x, center, n) * w).abs
              y = Numo::Pocketfft.irfft(rot * mag) * w
              buf[ch][pos...(pos + n)] += y
            end
            wsum[pos...(pos + n)] += w2
          end

          # Random-phase frames add up in power, not in amplitude
          finish(buf, wsum, n, out_len, power: (w2.mean).to_f)
        end

        # +count+ uniform numbers in 0...1 for frame +frame+: a splitmix64
        # hash of (seed, frame, bin, +stream+ (a channel)), so the phases
        # don't depend on how the work is split.
        def random_phases(seed, frame, count, stream = 0)
          base = (Integer(seed) * 0x9E3779B97F4A7C15 + frame * 0xD1B54A32D192ED03 + stream * 0x632BE59BD9B4E019) & Tone::MASK64
          z = Numo::UInt64.new(count).seq
          z.inplace * Numo::UInt64[0x9E3779B97F4A7C15]
          z.inplace + Numo::UInt64[base]
          z = (z ^ (z >> 30)) * Numo::UInt64[0xBF58476D1CE4E5B9]
          z = (z ^ (z >> 27)) * Numo::UInt64[0x94D049BB133111EB]
          z = z ^ (z >> 31)
          Numo::DFloat.cast(z >> 11) * 2.0**-53
        end

        # Phases wrapped to -pi...pi.
        def princarg(x)
          x - TWO_PI * ((x + Math::PI) / TWO_PI).floor
        end

        # The overlap-added channels, each divided by the windows' summed
        # squares and cut to +out_len+ (output sample 0 is the first
        # frame's center).  With +power+ (the window's mean square, for
        # incoherent frames), divided by sqrt(sum × power) instead, or for
        # partly coherent frames (the sums of the squared windows times
        # each frame's coherence c, the mean of its phase offsets' unit
        # vectors, in +coherent+, and times c² in +coherent2+) by
        # sqrt(coherent² + (sum - coherent2) × power).
        def finish(buf, wsum, n, out_len, power: nil, coherent: nil, coherent2: nil)
          h = n / 2
          floor = wsum.max * 1e-3
          norm = wsum[h...(h + out_len)].dup
          norm[norm < floor] = floor
          if power && coherent
            cs = coherent[h...(h + out_len)]
            norm = Numo::NMath.sqrt(cs * cs + (norm - coherent2[h...(h + out_len)]).clip(0, nil) * power)
            norm[norm < floor] = floor
          elsif power
            norm = Numo::NMath.sqrt(norm * power)
          end
          buf.map { |b| b[h...(h + out_len)] / norm }
        end

        # [a proc from output position to input position, the onsets it
        # keeps]: output / +ratio+, except that each onset lands exactly
        # at +ratio+ times its input position, with a span around it (a
        # window and a hop before it, half a window after: every frame
        # that holds the attack) played at ratio 1, and the input between
        # spans stretched to fill the time between them (so hits keep the
        # groove: each one where +ratio+ says, its attack unstretched, its
        # decay drawn out).  Where onsets are closer than a span (in the
        # input, or in the output when compressing), the spans shrink to
        # fit, leaving at least MIN_GAP hops between them; onsets closer
        # than that are left in the span before.
        def time_map(len, ratio, onsets, n, hs)
          r = ratio.to_f
          plain = ->(t) { t / r }
          return [plain, []] if onsets.nil? || onsets.empty?

          pre = n / 2 + hs
          post = n / 2
          gap_min = MIN_GAP * hs
          kept = []
          onsets.sort.uniq.each do |o|
            next if o < 0 || o >= len
            next if kept.any? && [o - kept.last, (o - kept.last) * r].min < gap_min + 2 * hs
            kept << o
          end

          # Spans [pre, post] per onset, shrunk to fit between neighbours
          spans = kept.map { [pre, post] }
          kept.each_with_index do |o, i|
            spans[i][0] = [spans[i][0], o, (o * r).floor].min if i == 0
            if i == kept.length - 1
              spans[i][1] = [spans[i][1], len - o, ((len - o) * r).floor].min
            else
              room = [kept[i + 1] - o, ((kept[i + 1] - o) * r).floor].min - gap_min
              want = spans[i][1] + spans[i + 1][0]
              if want > room
                scale = room.to_f / want
                spans[i][1] = (spans[i][1] * scale).floor
                spans[i + 1][0] = (spans[i + 1][0] * scale).floor
              end
            end
          end

          ins = [0.0]
          outs = [0.0]
          kept.each_with_index do |o, i|
            a, b = spans[i]
            [[o - a, o * r - a], [o + b, o * r + b]].each do |x, y|
              next if x <= ins.last && y <= outs.last
              ins << x.to_f
              outs << y.to_f
            end
          end
          if ins.last < len
            ins << len.to_f
            outs << len * r
          end

          k = 0
          map = ->(t) {
            k = 0 if t < outs[k]
            k += 1 while k < outs.length - 2 && t >= outs[k + 1]
            span = outs[k + 1] - outs[k]
            span > 0 ? ins[k] + (t - outs[k]) * (ins[k + 1] - ins[k]) / span : ins[k]
          }
          [map, kept]
        end

        # The fewest hops of input (and output) Spectral.time_map leaves
        # between two onsets' spans.
        MIN_GAP = 1
      end
    end
  end
end
