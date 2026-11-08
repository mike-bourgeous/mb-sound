module MB
  module Sound
    module GraphNode
      class Resample
        # The :min_phase resampling mode (fix-bus-resample-1, the
        # maintainer's 2026-11-08 answer on bus latency: "Use a minimum
        # phase resampler for zero latency when live"): a polyphase
        # resampler whose lowpass prototype is the minimum-phase version of
        # a Kaiser-windowed sinc, so each output frame reads only input
        # frames at or before its own time.  It reads nothing ahead
        # (#read_ahead 0), so a chain fed by the Session (a bus or master
        # chain's MixSource, a bus tap) isn't late, and on a track it gives
        # the same samples.  The cost is phase: low frequencies come
        # through a few samples late and the top of the band later (a
        # minimum-phase filter's group delay rises toward its cutoff),
        # where the linear-phase libsamplerate modes delay every frequency
        # the same and read ahead to cancel it.
        #
        # C kernel MB::Sound::FastResample.min_phase, exact Ruby mirror
        # .run_ruby (Kernels :min_phase_resample).
        module MinPhase
          # Prototype taps (input frames) at unity scale: the stretched
          # filter reaches TAPS / scale frames when downsampling.
          TAPS = 160

          # Table entries per input frame (linear interpolation between).
          PHASES = 512

          # Kaiser window beta (images about -106 dB down).
          BETA = 10.0

          # Cutoff as a fraction of the lower sample rate (the -6 dB point;
          # a pair is flat within 0.1 dB to 22 kHz at 48 kHz).
          CUTOFF = 0.475

          # The minimum-phase prototype as a Numo::DFloat of TAPS * PHASES
          # + 1 values (the last 0), its taps summing to one per input
          # frame (unity gain at DC).  Built once (about 0.1 s) by folding
          # the real cepstrum of the linear-phase prototype.
          def self.table
            @table ||= build_table.freeze
          end

          # Builds .table (see there).
          def self.build_table
            len = TAPS * PHASES
            n = Numo::DFloat.new(len).seq - (len - 1) / 2.0
            x = n / PHASES # input frames from the center
            arg = x * (2 * CUTOFF)
            sinc = Numo::DFloat.ones(len)
            nz = arg.ne(0)
            sinc[nz] = Numo::NMath.sin(arg[nz] * Math::PI) / (arg[nz] * Math::PI)
            w = kaiser(len, BETA)
            lin = sinc * w * (2 * CUTOFF)

            # Real cepstrum, folded onto positive quefrencies
            size = 1 << (Math.log2(len * 4).ceil)
            padded = Numo::DFloat.zeros(size)
            padded[0...len] = lin
            spec = Numo::Pocketfft.fft(Numo::DComplex.cast(padded))
            mag = spec.abs
            floor = mag.max * 1e-9
            logmag = Numo::NMath.log(mag.clip(floor, nil))
            cep = Numo::Pocketfft.ifft(Numo::DComplex.cast(logmag)).real
            fold = Numo::DFloat.zeros(size)
            fold[0] = cep[0]
            fold[1...(size / 2)] = cep[1...(size / 2)] * 2
            fold[size / 2] = cep[size / 2]
            minp = Numo::Pocketfft.ifft(Numo::NMath.exp(Numo::Pocketfft.fft(Numo::DComplex.cast(fold)))).real

            t = Numo::DFloat.zeros(len + 1)
            t[0...len] = minp[0...len]
            t *= PHASES / t[0...len].sum
            t
          end
          private_class_method :build_table

          # A Kaiser window of +len+ points.
          def self.kaiser(len, beta)
            i0 = ->(v) {
              sum = 1.0
              term = 1.0
              k = 1
              loop do
                term *= (v / (2 * k))**2
                sum += term
                break if term < sum * 1e-17

                k += 1
              end
              sum
            }
            denom = i0.(beta)
            Numo::DFloat.new(len).seq.map { |i|
              r = 2.0 * i / (len - 1) - 1
              i0.(beta * Math.sqrt([1 - r * r, 0].max)) / denom
            }
          end
          private_class_method :kaiser

          # Exact Ruby mirror of MB::Sound::FastResample.min_phase (see
          # there): writes +out+'s frames and returns +out+.
          def self.run_ruby(out, input, table, phases, taps, scale, start, num, den, base)
            raise ArgumentError, 'Output must be a contiguous 1D Numo::SFloat' unless out.is_a?(Numo::SFloat) && out.ndim == 1
            raise ArgumentError, 'Input must be a contiguous 1D Numo::SFloat' unless input.is_a?(Numo::SFloat) && input.ndim == 1
            raise ArgumentError, 'Table must be a contiguous 1D Numo::DFloat' unless table.is_a?(Numo::DFloat) && table.ndim == 1
            raise ArgumentError, "Table must have phases * taps + 1 values (got #{table.length} for #{phases} * #{taps})" unless phases >= 1 && taps >= 1 && table.length == phases * taps + 1

            sc = scale.to_f
            raise ArgumentError, 'Scale must be in (0, 1], num and den positive, and start non-negative' unless sc > 0 && sc <= 1 && num >= 1 && den >= 1 && start >= 0

            reach = (taps / sc).ceil
            limit = phases * taps
            n_out = out.length
            if n_out > 0
              first = start * num / den - base
              last = (start + n_out - 1) * num / den - base
              raise ArgumentError, "Input needs #{reach - 1} frames of history before frame #{first + base}" if first - (reach - 1) < 0
              raise ArgumentError, "Input frame #{last + base} is past the #{input.length}-frame input from frame #{base}" if last >= input.length
            end

            h = table.to_a
            sp = sc * phases
            coefs = {}
            k = 0
            while k < n_out
              a = (start + k) * num
              n = a / den - base
              rem = a % den
              c = (coefs[rem] ||= begin
                f = rem.to_f / den
                list = []
                j = 0
                while j < reach
                  tau = (f + j) * sp
                  i = tau.to_i
                  break if i >= limit

                  list << h[i] + (tau - i) * (h[i + 1] - h[i])
                  j += 1
                end
                list
              end)
              acc = 0.0
              j = 0
              while j < c.length
                acc += input[n - j] * c[j]
                j += 1
              end
              out[k] = acc * sc
              k += 1
            end

            out
          end
        end

        Kernels.register :min_phase_resample, c: FastResample.method(:min_phase), ruby: MinPhase.method(:run_ruby)
      end
    end
  end
end
