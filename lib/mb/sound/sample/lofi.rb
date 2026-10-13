module MB
  module Sound
    class Sample
      # Offline character edits for samples (Sample#bits, #lofi, #stretch),
      # baked into new audio so they cost nothing per voice.
      module Lofi
        # Classic samplers' converters, roughly: sample rate (Hz), bits, an
        # input (anti-alias) filter at 45% of the rate, and an output filter
        # (Hz or nil).  Not emulations: the rates and depths of the
        # machines' usual settings, aliasing from a zero-order hold, and
        # their filters as simple lowpasses.
        PRESETS = {
          # Akai S950: 12 bits, variable rate (31.25 kHz here, a jungle
          # favourite for longer breaks), a filtered output
          s950: { rate: 31_250, bits: 12, input_filter: true, filter: 13_000 },
          # E-mu SP-1200: 12 bits at 26.04 kHz, no anti-alias filter on the
          # way in, the gritty unfiltered outputs
          sp1200: { rate: 26_040, bits: 12, input_filter: false, filter: nil },
          # Akai MPC60: 12 bits (stored nonlinearly) at 40 kHz, filtered
          mpc60: { rate: 40_000, bits: 12, input_filter: true, filter: 16_000 },
        }.freeze

        module_function

        # +data+ rounded to 2^(bits - 1) steps per unit.
        def bits(data, bits)
          raise ArgumentError, "Bits must be 1 to 24 (got #{bits.inspect})" unless bits.is_a?(Numeric) && bits >= 1 && bits <= 24
          q = 2.0**(bits - 1)
          (Numo::DFloat.cast(data) * q).round / q
        end

        # The settings for +preset+ (a PRESETS name or nil) with +options+
        # (rate:, bits:, input_filter:, filter:) changed.
        def settings(preset = nil, **options)
          base = preset ? PRESETS.fetch(preset.to_sym) { raise ArgumentError, "Unknown lofi preset #{preset.inspect} (#{PRESETS.keys.join(', ')})" } : {}
          bad = options.keys - [:rate, :bits, :input_filter, :filter]
          raise ArgumentError, "Unknown lofi options #{bad.inspect}" unless bad.empty?
          s = { rate: nil, bits: nil, input_filter: true, filter: nil }.merge(base).merge(options)
          raise ArgumentError, 'Give a lofi preset or rate:/bits:' if s[:rate].nil? && s[:bits].nil?
          s
        end

        # +data+ (a 1D NArray at +sample_rate+) through an input filter, a
        # zero-order hold at +rate+, +bits+, and an output +filter+.
        def process(data, sample_rate:, rate: nil, bits: nil, input_filter: true, filter: nil)
          x = Numo::DFloat.cast(data)
          fs = sample_rate.to_f
          if rate && rate < fs
            x = lowpass(x, fs, rate * 0.45) if input_filter
            x = hold(x, fs, rate.to_f)
          end
          x = Lofi.bits(x, bits) if bits
          x = lowpass(x, fs, filter.to_f) if filter && filter < fs / 2
          Numo::SFloat.cast(x)
        end

        # A zero-order hold: each output sample takes the input at the last
        # tick of a +rate+ Hz clock (so a 26 kHz hold aliases like a sampler
        # with no reconstruction filter).
        def hold(x, fs, rate)
          n = x.length
          i = Numo::DFloat.new(n).seq
          ticks = (i * (rate / fs) + 1e-9).floor
          idx = (ticks * (fs / rate)).ceil.clip(0, n - 1)
          x[Numo::Int64.cast(idx)]
        end

        # Two passes of a Butterworth-Q biquad lowpass at +cutoff+ (a 4-pole
        # rolloff).
        def lowpass(x, fs, cutoff)
          2.times do
            f = MB::Sound::Filter::Cookbook.new(:lowpass, fs, cutoff, quality: Math.sqrt(0.5))
            x = Numo::DFloat.cast(f.process(x))
          end
          x
        end

        # Cyclic timestretch (see Sample#stretch): output cycle k of +cycle+
        # samples plays the input from k × +cycle+ / +ratio+, each cycle
        # overlapping the next by +crossfade+ samples with linear fades.
        def stretch(data, ratio, cycle, crossfade)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          raise ArgumentError, 'The stretch cycle must be at least 16 samples' unless cycle >= 16
          x = Numo::DFloat.cast(data)
          n = x.length
          out_len = (n * ratio).round
          out = Numo::DFloat.zeros(out_len + cycle + crossfade)
          k = 0
          while k * cycle < out_len
            o = k * cycle
            src = (o / ratio).round
            break if src >= n
            len = MB::M.min(cycle + crossfade, n - src)
            seg = x[src...(src + len)].dup
            if crossfade > 0
              f = MB::M.min(crossfade, len)
              seg[0...f] *= Numo::DFloat.linspace(0, 1, f + 1)[1..] if k > 0
              seg[-f..] *= Numo::DFloat.linspace(1, 0, f + 1)[0...-1] if len > cycle
            end
            out[o...(o + len)] += seg
            k += 1
          end
          Numo::SFloat.cast(out[0...out_len])
        end
      end
    end
  end
end
