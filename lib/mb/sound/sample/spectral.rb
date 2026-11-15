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
        # attack bins near onsets stay unrandomized.  +span+ (0..1) is how
        # much of each onset's surroundings stays unstretched (#time_map).
        # +wrap+ is for audio
        # that loops (its end flows into its start): the stretch reads it
        # as an endless stream and its own end flows into its start
        # (#looped with one pass).
        def vocoder(channels, ratio, window: WINDOW, overlap: OVERLAP, onsets: nil, randomize: 0, seed: 0, link: true, shape: :hann, wrap: false, span: 1.0, noise: 0)
          return looped(channels, ratio, window: window, overlap: overlap, onsets: onsets, randomize: randomize, seed: seed, link: link, shape: shape, span: span, noise: noise) if wrap

          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          voc = Vocoder.new(channels, window: window, overlap: overlap, randomize: randomize, seed: seed, link: link, shape: shape, noise: noise)
          n = voc.window
          hs = voc.hop
          len = voc.length
          out_len = (len * ratio).round
          map, resets = time_map(len, ratio, onsets, n, hs, span)

          frames = out_len / hs + 2
          sums = Sums.new(voc.channels, frames * hs + n, voc.frames_random?)
          attack_until = nil
          ri = 0

          frames.times do |m|
            center = map.call(m * hs).round
            while ri < resets.length && center + n / 2 > resets[ri]
              attack_until = resets[ri] + n / 2
              ri += 1
            end
            attack = !attack_until.nil? && center < attack_until
            sums.add(m * hs, voc.frame(m, center, attack: attack), voc, attack)
          end

          sums.finish(n / 2, out_len, voc)
        end

        # The phase vocoder for audio that loops: +channels+ are read as
        # an endless stream (every frame wraps around the ends, so no
        # frame sees an edge), stretched by +ratio+, and the output is
        # overlap-added in a circle, so its own end flows into its
        # start with the same sound on both sides (no unstretched join, no
        # crossfade).  Options as #vocoder; +onsets+ are those of one
        # pass, an onset at the start being an attack only if the level
        # rises across the wrap (Sample::Onsets, wrap: true).
        #
        # A stretch's partials don't come round to their starting phases
        # by themselves (a partial of f Hz turns f × the output's length
        # times, rarely a whole number), so a first pass over the loop
        # measures how far every bin's phase is from closing (after the
        # last frame, back at the first frame's content), and the second
        # adds that, spread evenly over the frames, to each frame's phase
        # advance before locking: every partial is moved by less than
        # half a cycle per loop length (0.3 Hz for a 1.6 s loop) and ends
        # on its starting phase.  Phases that an onset resets close by
        # themselves.  What the spreading leaves (bins whose peaks moved)
        # is in +report+ (a Hash, if given): :closure, the magnitude-
        # weighted mean of |phase error| at the wrap in cycles, before
        # and after.  +passes+ stretches that many passes of the loop as
        # one piece (for measuring: any one of them alone does not loop,
        # which is why the phases are closed; a single closed pass sounds
        # the same at the wrap, so Sample#stretch makes one).
        def looped(channels, ratio, passes: 1, window: WINDOW, overlap: OVERLAP, onsets: nil, randomize: 0, seed: 0, link: true, shape: :hann, report: nil, span: 1.0, noise: 0)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          passes = Integer(passes)
          raise ArgumentError, "passes: is 1 or more (got #{passes})" unless passes >= 1

          voc = Vocoder.new(channels, window: window, overlap: overlap, randomize: randomize, seed: seed, link: link, shape: shape, wrap: true, noise: noise)
          n = voc.window
          hs = voc.hop
          len = voc.length
          pass_len = (len * ratio).round
          out_len = pass_len * passes
          raise ArgumentError, 'The stretched loop must be at least one sample long' unless out_len >= 1

          # The time map of the middle of three passes (the passes before
          # and after are its neighbours across the wrap)
          on3 = onsets && !onsets.empty? ? (0...3).flat_map { |k| onsets.map { |o| o + k * len } } : nil
          map3, resets3 = time_map(3 * len, ratio, on3, n, hs, span)
          centers = []
          t = 0
          while t < out_len
            pass, rem = t.divmod(pass_len)
            centers << [t, map3.call(rem + len * ratio.to_f).round - len + pass * len]
            t += hs
          end
          # (the frame after the last is the first again, a loop later)
          centers << [out_len, centers[0][1] + passes * len]
          resets = (-1..passes).flat_map { |k| resets3.select { |o| o >= len && o < 2 * len }.map { |o| o - len + k * len } }

          run = ->(extra, sums) {
            voc.restart
            attack_until = nil
            ri = 0
            last = nil
            centers.each_with_index do |(pos, center), m|
              while ri < resets.length && center + n / 2 > resets[ri]
                attack_until = resets[ri] + n / 2
                ri += 1
              end
              attack = !attack_until.nil? && center < attack_until
              hop = m.zero? ? hs : pos - centers[m - 1][0]
              closing = m == centers.length - 1
              ys = voc.frame(m, center, attack: attack, hop: hop, extra: extra && m > 0 ? extra * (hop.to_f / out_len) : nil, synth: !sums.nil? && !closing)
              sums.add_wrapped(pos, ys, voc, attack) if sums && !closing
              last = voc.rotation if closing
            end
            last
          }

          sums = Sums.new(voc.channels, out_len, voc.frames_random?)
          if voc.randomize >= 1
            # (every phase random: nothing to close)
            run.call(nil, sums)
          else
            error = run.call(nil, nil)
            weights = voc.magnitudes
            before = (error.abs * weights).sum / (TWO_PI * weights.sum + 1e-300)
            left = run.call(-error, sums)
            report[:closure] = [before, (left.abs * weights).sum / (TWO_PI * weights.sum + 1e-300)] if report
          end
          sums.finish(0, out_len, voc)
        end

        # A phase vocoder's running state (see Spectral.vocoder): the
        # windows, the input, and the phases the last frame reached.
        # #frame makes the next frame from wherever its center is, so
        # Spectral.vocoder (a whole sample at once), Spectral.looped (a
        # loop, read in a circle), and Spectral::Stream (a loop followed
        # live) are one vocoder.
        class Vocoder
          attr_reader :window, :hop, :length, :channels, :randomize, :squares, :coherence

          # +channels+ as Spectral.vocoder takes them.  With +wrap+ the
          # frames read the input in a circle (a loop); without, zeros
          # outside it.
          def initialize(channels, window: WINDOW, overlap: OVERLAP, randomize: 0, seed: 0, link: true, shape: :hann, wrap: false, noise: 0)
            @randomize = randomize.to_f
            raise ArgumentError, "randomize: is 0..1 (got #{@randomize})" unless @randomize >= 0 && @randomize <= 1
            @noise = noise.to_f
            raise ArgumentError, "noise: is 0..1 (got #{@noise})" unless @noise >= 0 && @noise <= 1
            @window = Integer(window)
            raise ArgumentError, "The window must be an even number of samples, 64 or more (got #{window})" unless @window >= 64 && @window.even?
            @hop = @window / Integer(overlap)
            raise ArgumentError, 'The overlap must leave a hop of at least 8 samples' unless @hop >= 8

            @xs = channels.map { |c| Numo::DFloat.cast(c) }
            @channels = @xs.length
            @length = @xs[0].length
            @mix = @xs.length == 1 ? @xs[0] : @xs.sum / @xs.length
            @wrap = wrap
            @seed = seed
            @link = link
            @w = Spectral.shaped_window(shape, @window)
            @squares = @w * @w
            @bins = @window / 2 + 1
            @omega = Numo::DFloat.new(@bins).seq * (TWO_PI / @window)
            @reference = @window / 8 # the fixed offset for instantaneous frequencies
            @base = Numo::Int64.new(@window).seq - @window / 2
            # Partly random frames add partly in amplitude, partly in
            # power: the mean of a frame's random phase offsets' unit
            # vectors (its coherence, sinc(randomize)), summed with the
            # windows for Sums#finish
            @coherence = @randomize > 0 ? Math.sin(Math::PI * @randomize) / (Math::PI * @randomize) : 1.0
            # (for #noisiness: each bin's neighbourhood, and how much
            # quieter frames with unrelated phases add up than frames in
            # step: a frame with random phases spreads its power over the
            # whole window, so overlapped and normalized it comes out at
            # hop / window of the power, -6 dB at four frames a window)
            reach = MB::M.max(8, @bins / 85)
            idx = Numo::Int64.new(@bins).seq
            @floor_lo = (idx - reach).clip(0, @bins)
            @floor_hi = (idx + reach + 1).clip(0, @bins)
            @floor_count = Numo::DFloat.cast(@floor_hi - @floor_lo)
            @power = @hop.to_f / @window
            restart
          end

          # Sets how much the bins that are no partial get random phases
          # (0..1) from the next frame on.
          def noise=(amount)
            @noise = MB::M.clamp(amount.to_f, 0.0, 1.0)
          end

          # True if whole frames get random phases (randomize: alone): the
          # sums then normalize by the frames' coherence.  With noise: the
          # frames make up for it bin by bin themselves.
          def frames_random? = @randomize > 0 && @noise <= 0

          # How much like noise each bin of +mag+ is, 0 (a partial) to 1:
          # by how far the peak its region belongs to (Spectral.regions)
          # stands above the level around it (the mean of the log
          # magnitudes a few dozen bins either side): NOISE_BELOW dB or
          # less is noise, TONE_ABOVE dB or more a partial.  Peaks of
          # noise under a Hann window stand 3 to 8 dB above their
          # surroundings; a partial 20 dB above the noise it sits in, 20.
          def noisiness(mag)
            owner = Spectral.regions(mag)
            return Numo::DFloat.ones(@bins) if owner.nil?

            lg = Numo::NMath.log(mag + 1e-30)
            c = Numo::DFloat.zeros(@bins + 1)
            c[1..] = lg.cumsum
            prominence = (lg - (c[@floor_hi] - c[@floor_lo]) / @floor_count)[owner] * (20 / Math.log(10))
            1 - ((prominence - NOISE_BELOW) / (TONE_ABOVE - NOISE_BELOW)).clip(0, 1)
          end

          # Forgets the phases: the next frame starts with its input's.
          def restart
            @theta = nil
            @phi = nil
            @mag = nil
            @center = nil
          end

          # The last frame's phase rotation (output phase minus input
          # phase per bin, -pi...pi) and its magnitudes.
          def rotation = Spectral.princarg(@theta - @phi)
          def magnitudes = @mag

          # The +window+ samples of +x+ centered on +center+.
          def read(x, center)
            return Spectral.segment(x, center, @window) unless @wrap

            x[(@base + center) % @length]
          end

          # The next frame, centered on input sample +center+ and +hop+
          # output samples after the last: each channel's windowed output
          # (to overlap-add; nil without +synth+, when only the phases
          # are wanted).  +attack+ says the frame holds an onset: bins
          # whose level jumps (the attack) take their input phases, so
          # the attack is rebuilt as it was; steady bins (a bass note
          # ringing through) keep theirs, so nothing cancels; and the
          # frame is not randomized.  +extra+ (radians per bin) is added
          # to the phase advance before locking (Spectral.looped's
          # closing).  +index+ numbers the frame for the random phases.
          def frame(index, center, attack: false, hop: @hop, extra: nil, synth: true)
            spec = Numo::Pocketfft.rfft(read(@mix, center) * @w)
            phi = spec.arg
            mag = spec.abs

            if @theta.nil?
              @theta = phi.dup
            else
              ha = center - @center
              if ha == hop
                # Unstretched frames (around transients): the exact phase
                # difference over the real hop, so the frames rebuild the
                # input
                winst_h = @omega * hop + Spectral.princarg(phi - @phi - @omega * hop)
              else
                ref = Numo::Pocketfft.rfft(read(@mix, center - @reference) * @w).arg
                winst_h = (@omega + Spectral.princarg(phi - ref - @omega * @reference) / @reference) * hop
              end
              winst_h += extra if extra
              @theta = Spectral.lock(@theta + winst_h, phi, mag)
              if attack
                rising = mag.gt(@mag * RESET_RISE)
                @theta[rising] = phi[rising] if rising.count_true > 0
              end
            end
            @phi = phi
            @mag = mag
            @center = center
            return nil unless synth

            rot = @theta - phi
            # (frames holding an attack stay unrandomized: crisp attacks
            # even in Paulstretch)
            random = @randomize > 0 && !attack
            amount = nil
            if @noise > 0 && !attack
              # Noise as noise: each bin's phase gets a random offset of
              # up to ± noise × its noisiness × π (at least randomize's),
              # and the gain that keeps its level when frames with
              # unrelated phases overlap (they add in power)
              amount = noisiness(mag) * @noise
              amount = amount.clip(@randomize, nil) if @randomize > 0
              turn = amount * Math::PI
              coherence = Numo::NMath.sin(turn) / turn.clip(1e-9, nil)
              coherence[turn < 1e-9] = 1.0
              gain = 1 / Numo::NMath.sqrt(coherence**2 + (1 - coherence**2) * @power)
              random = false
            end
            rotc = nil
            @xs.each_with_index.map do |x, ch|
              if amount && (rotc.nil? || !@link)
                r = rot + (Spectral.random_phases(@seed, index, @bins, @link ? 0 : ch) - 0.5) * (amount * TWO_PI)
                rotc = (Numo::DComplex.cast(Numo::NMath.cos(r)) + Numo::NMath.sin(r) * Complex::I) * gain
              elsif random && (rotc.nil? || !@link)
                r = rot + (Spectral.random_phases(@seed, index, @bins, @link ? 0 : ch) - 0.5) * (TWO_PI * @randomize)
                rotc = Numo::DComplex.cast(Numo::NMath.cos(r)) + Numo::NMath.sin(r) * Complex::I
              end
              rotc ||= Numo::DComplex.cast(Numo::NMath.cos(rot)) + Numo::NMath.sin(rot) * Complex::I
              cs = ch == 0 && @xs.length == 1 ? spec : Numo::Pocketfft.rfft(read(x, center) * @w)
              Numo::Pocketfft.irfft(cs * rotc) * @w
            end
          end
        end

        # The overlap-added frames of a Vocoder and the sums of their
        # squared windows (and, with random phases, of the windows times
        # each frame's coherence and its square): #add in a line (a frame
        # at +pos+ fills +pos+...+pos+ + window), #add_wrapped in a circle
        # (a frame centered on +pos+, wrapping around the ends).
        class Sums
          def initialize(channels, length, random)
            @length = length
            @buf = Array.new(channels) { Numo::DFloat.zeros(length) }
            @wsum = Numo::DFloat.zeros(length)
            @csum = random ? Numo::DFloat.zeros(length) : nil
            @c2sum = random ? Numo::DFloat.zeros(length) : nil
          end

          def add(pos, frames, voc, attack)
            n = voc.window
            frames.each_with_index { |y, ch| @buf[ch][pos...(pos + n)] += y }
            @wsum[pos...(pos + n)] += voc.squares
            return unless @csum

            cm = attack ? 1.0 : voc.coherence
            @csum[pos...(pos + n)] += voc.squares * cm
            @c2sum[pos...(pos + n)] += voc.squares * (cm * cm)
          end

          def add_wrapped(pos, frames, voc, attack)
            n = voc.window
            cm = attack ? 1.0 : voc.coherence
            from = 0
            at = (pos - n / 2) % @length
            while from < n
              k = MB::M.min(n - from, @length - at)
              frames.each_with_index { |y, ch| @buf[ch][at...(at + k)] += y[from...(from + k)] }
              w2 = voc.squares[from...(from + k)]
              @wsum[at...(at + k)] += w2
              if @csum
                @csum[at...(at + k)] += w2 * cm
                @c2sum[at...(at + k)] += w2 * (cm * cm)
              end
              from += k
              at = 0
            end
          end

          # The +out_len+ output samples from +offset+ on, normalized
          # (Spectral.finish).
          def finish(offset, out_len, voc)
            if @csum
              Spectral.finish(@buf, @wsum, 2 * offset, out_len, power: voc.squares.mean.to_f, coherent: @csum, coherent2: @c2sum)
            else
              Spectral.finish(@buf, @wsum, 2 * offset, out_len)
            end
          end
        end

        # The phase vocoder following a loop live: #pull gives the next
        # output samples for the loop positions asked (a phase per
        # sample, as a tempo-following player counts them), each frame
        # read from the loop wherever the positions have got to, so the
        # stretch follows any tempo, and tempo changes, as one endless
        # stream: no pass has an end, and nothing is restretched.  At a
        # steady tempo the frames are Spectral.looped's (the same time
        # map around +onsets+, the same Vocoder), without the closing:
        # a stream never comes back to its start.
        #
        # Frames are a hop apart on the stream's own sample count,
        # whatever the buffer sizes; a frame is centered up to half a
        # window ahead of the samples it helps make, so the positions
        # that far ahead are those the current speed leads to (a tempo
        # change is heard within half a window, 43 ms).  A jump in the
        # positions (a seek, a relaunch) starts the phases again.
        class Stream
          attr_reader :channels

          def initialize(channels, onsets: nil, window: WINDOW, overlap: OVERLAP, shape: :hann, link: true, span: 1.0, noise: nil, seed: 0)
            # (noise: nil: by the ratio the loop is playing at, Spectral.noise_for)
            @auto_noise = noise.nil?
            @voc = Vocoder.new(channels, window: window, overlap: overlap, shape: shape, link: link, wrap: true, noise: noise || 0, seed: seed)
            @channels = @voc.channels
            @n = @voc.window
            @hs = @voc.hop
            @len = @voc.length
            @onsets = onsets && !onsets.empty? ? onsets.sort.freeze : nil
            @span = span
            @size = 1 << Math.log2(4 * @n).ceil
            @ring = Array.new(@channels) { Numo::DFloat.zeros(@size) }
            @wring = Numo::DFloat.zeros(@size)
            @floor = @voc.squares.sum / @hs * 1e-3
            @time = 0        # output samples made
            @frames = 0      # frames made (frame k is centered on output sample k × hop)
            @line = nil      # the last frame's place on the loop, unwrapped (samples)
            @phase = nil     # and its phase
            @ratio = nil
            @map = nil
            @resets = nil
            @block = nil
            @block_start = nil
            @reads = Array.new(@channels, 0)
          end

          # The next +phases+.length output samples of channel +channel+,
          # for loop positions +phases+ (0...1, one per sample) moving on
          # by +step+ per sample after the last.  Channels are read side
          # by side: the first to ask for a stretch of time makes it for
          # all of them.
          def pull(channel, phases, step)
            count = phases.length
            if @reads[channel] == @block_start && @block && @block[0].length == count
              @reads[channel] += count
              return @block[channel]
            end

            grow(count) if count + 2 * @n > @size
            stop = @time + count
            while @frames * @hs < stop + @n / 2
              at = @frames * @hs
              phase = at < stop ? phases[at - @time] : phases[count - 1] + (at - stop + 1) * step
              make_frame(at, phase, step)
            end

            idx = (Numo::Int64.new(count).seq + @time) % @size
            w = @wring[idx]
            w[w < @floor] = @floor
            @block = @ring.map { |r| o = r[idx] / w; r[idx] = 0; o }
            @wring[idx] = 0
            @block_start = @time
            @time = stop
            @reads[channel] = stop
            @block[channel]
          end

          private

          # Frame centered on output sample +at+, the loop at +phase+
          def make_frame(at, phase, step)
            move = step * @len * @hs
            if @line.nil?
              @line = phase * @len
            else
              d = phase - @phase
              d -= d.round
              # (a jump: not where the speed leads, by more than a window)
              if (d * @len - move).abs > @n
                @voc.restart
                @line = phase * @len
              else
                @line += d * @len
              end
            end
            @phase = phase

            center = @line.round
            attack = false
            @voc.noise = Spectral.noise_for(@hs / move) if @auto_noise && move > 0
            if @onsets && move > 0
              ratio = (@hs / move).round(4)
              if ratio != @ratio
                @ratio = ratio
                on3 = (0...3).flat_map { |k| @onsets.map { |o| o + k * @len } }
                @map, kept = Spectral.time_map(3 * @len, ratio, on3, @n, @hs, @span)
                @resets = kept.select { |o| o >= @len && o < 2 * @len }.map { |o| o - @len }
              end
              pass, rem = @line.divmod(@len)
              center = @map.call((rem + @len) * @ratio).round - @len + pass * @len
              in_loop = center % @len
              attack = @resets.any? { |o| (((in_loop - o + @len / 2) % @len) - @len / 2).abs < @n / 2 }
            end

            ys = @voc.frame(@frames, center, attack: attack)
            # (what would land before the samples still to come is left out)
            from = MB::M.max(0, @time - (at - @n / 2))
            pos = (at - @n / 2 + from) % @size
            while from < @n
              k = MB::M.min(@n - from, @size - pos)
              ys.each_with_index { |y, ch| @ring[ch][pos...(pos + k)] += y[from...(from + k)] }
              @wring[pos...(pos + k)] += @voc.squares[from...(from + k)]
              from += k
              pos = 0
            end
            @frames += 1
          end

          # A ring big enough for buffers of +count+ samples.
          def grow(count)
            size = 1 << Math.log2(count + 2 * @n).ceil
            old = (Numo::Int64.new(@size).seq + @time) % @size
            new = (Numo::Int64.new(@size).seq + @time) % size
            @ring = @ring.map { |r| Numo::DFloat.zeros(size).tap { |b| b[new] = r[old] } }
            @wring = Numo::DFloat.zeros(size).tap { |b| b[new] = @wring[old] }
            @size = size
          end
        end

        # The default noise: of the spectral stretches by +ratio+: 0 up
        # to NOISE_FROM (1.5x), 1 from NOISE_FULL (2x) on, a straight line
        # between.  The vocoder's window is heard in what is no partial
        # the more the longer the stretch (self-similarity one window
        # later 0.02 at 2x, 0.2 at 8x on a tonal drum loop with a
        # shaker); the maintainer picked noise: 1 at 2x and 8x, and the
        # plain vocoder on drums at 1.18x and 1.25x.
        def noise_for(ratio)
          MB::M.clamp((ratio.to_f - NOISE_FROM) / (NOISE_FULL - NOISE_FROM), 0.0, 1.0)
        end

        NOISE_FROM = 1.5
        NOISE_FULL = 2.0

        # For Vocoder#noisiness (noise: of the spectral stretches): a
        # region whose peak stands this many dB or less above its
        # surroundings is noise, this many or more a partial.
        NOISE_BELOW = 8.0
        TONE_ABOVE = 16.0

        # The peak each bin of +mag+ belongs to (peaks are bins above
        # their two neighbours on each side; regions split midway between
        # peaks, as #lock has them), or nil without peaks.
        def regions(mag)
          nb = mag.length
          return nil if nb < 5

          c = mag[2...(nb - 2)]
          is_peak = (c > mag[1...(nb - 3)]) & (c > mag[0...(nb - 4)]) & (c >= mag[3...(nb - 1)]) & (c >= mag[4...nb])
          peaks = is_peak.where + 2
          return nil if peaks.empty?

          marker = Numo::Int32.zeros(nb)
          if peaks.length > 1
            bounds = ((peaks[0...-1] + peaks[1..]) / 2) + 1
            marker[bounds] = 1
          end
          peaks[marker.cumsum]
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
        # than that are left in the span before.  +span+ (0..1) scales the
        # spans: less of each attack's surroundings at ratio 1, a more
        # even stretch between attacks (at long ratios full spans can
        # hold half the input).
        def time_map(len, ratio, onsets, n, hs, span = 1.0)
          r = ratio.to_f
          plain = ->(t) { t / r }
          return [plain, []] if onsets.nil? || onsets.empty?

          pre = ((n / 2 + hs) * span).round
          post = (n / 2 * span).round
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
