module MB
  module Sound
    module Analysis
      # Is this one sound?  A screen for energy that doesn't belong to one
      # hit or note: a second onset above 2 kHz inside a one-shot (a hat on
      # a kick's next 16th), high bands that outlast the body (an open hat
      # over a tom), energy under a steady pitch's fundamental (a kick
      # under a chopped note, the lower note of a stack), and noise between
      # a note's harmonics above 2 kHz (grit, fuzz, another part).  Each
      # flag comes with the evidence and a mask a comparison could use
      # (+{ below_hz: f }+, +{ above_hz: f, from: seconds }+).
      #
      # **A reason to look, not a verdict.**  In round 3 the rules confirmed
      # what the maintainer heard on three references, and also fired on
      # 11 of 58 clean synthetic renders (mostly fits with reverb or noise
      # layers, which really are a second source); they miss what sits
      # exactly on the body (no evidence for a closed hat he suspected in
      # a snare).  Look at the images (Analysis.look) before acting on a
      # flag.
      #
      # Method (round 3's bleed.rb):
      # 1. Octave-band envelopes (1024-point frames every 2 ms, 31 Hz-16
      #    kHz): per band its peak time, level re the loudest band, the
      #    time it takes to fall 20 dB from its peak (T20), and later
      #    onsets (a rise of 8 dB within 20 ms after falling 10 dB).
      # 2. One-shots only (the under-2-kHz envelope falls 25 dB from its
      #    peak): two or more band onsets above 2 kHz between 15 and 400 ms
      #    (later onsets, or band peaks 15 ms or more after the body's peak:
      #    analysis-lib-1's addition, for a hit with no click of its own)
      #    are a second hit; two or more bands above 2 kHz whose T20 is 2.5x
      #    the median T20 under 2 kHz (or never fall 20 dB) are a second,
      #    sustained source.
      # 3. Pitched sounds (most frames voiced, the middle half within a
      #    semitone): over 5% of the fundamental region's energy below 0.7
      #    f0 (f0 over 80 Hz) is low bleed or a lower layer; over 35% of the
      #    energy above 2 kHz between harmonics (outside ±15% of the
      #    spacing, where that region is within 30 dB of the whole) is noise
      #    or another part.
      #
      #     b = Analysis::Bleed.new(sound)
      #     b.clean?     # => false
      #     b.flags      # Flag entries with text and evidence
      #     b.masks      # => [{ above_hz: 2000.0, from: 0.111 }]
      class Bleed
        HOP = 96
        N_FFT = 1024

        # The under-2-kHz body envelope's block (5 ms).
        BODY_HOP = 240
        BANDS = DSP.octave_bands(31.25, 16000.0, 1)

        # One flag: +kind+ (:second_onset, :sustained_top, :low_energy,
        # :between_harmonics), +text+ (the evidence), +mask+ (a Hash or nil).
        Flag = Data.define(:kind, :text, :mask) do
          def to_s = text
          def inspect = "#<Bleed::Flag #{kind}: #{text}>"
        end

        # Per octave band: +band+ [lo, hi] Hz, +level+ (dB re the loudest
        # band), +peak+ (seconds from the start), +t20+ (seconds from its
        # peak until 20 dB under it; nil if it never falls that far), +plateau+ (dB from its peak to 80% of the
        # way through), +onsets+ (later onsets, seconds).
        BandStat = Data.define(:band, :level, :peak, :t20, :plateau, :onsets)

        attr_reader :signal

        # Flags (Flag), the masks they suggest, per-band statistics
        # (BandStat), the steady f0 in Hz (nil if not steadily pitched),
        # whether the sound is a one-shot, and the harmonic residual
        # ({ sub_share:, between_share:, above_2k_db: }, nil unless pitched).
        attr_reader :flags, :masks, :bands, :f0, :percussive, :residual

        # Screens +sound+ (anything Signal.from takes).
        def initialize(sound)
          @signal = Signal.from(sound)
          x = @signal.aligned
          @bands = band_stats(x).freeze
          @flags = []
          rate = Signal::RATE
          low = DSP.brickwall(x.data, rate, 2000.0)
          env = Signal.new(low).envelope_db(BODY_HOP)
          pk = env.max_index
          @percussive = env[pk..].lt(env[pk] - 25).count_true > 0

          hi = @bands.select { |s| s.band[0] >= 2000 && s.level > -45 }
          # Later onsets in the high bands, and high bands that peak well
          # after the body (a hat on a kick with no click of its own)
          body = pk * BODY_HOP / Signal::RATE.to_f
          later = hi.flat_map(&:onsets) + hi.map(&:peak).select { |t| t > body + 0.015 }
          later = later.select { |t| t > 0.015 && t < 0.4 }
          if @percussive && later.length >= 2
            t = later.sort[later.length / 2]
            @flags << Flag.new(kind: :second_onset, mask: { above_hz: 2000.0, from: (t - 0.005).round(4) }.freeze,
                               text: "second onset above 2 kHz at about #{Analysis.seconds_label(t)} (#{later.length} band onsets): another hit (a hat?)")
          end

          lows = @bands.select { |s| s.band[0] < 2000 && s.level > -40 && s.t20 }
          med_low = DSP.median(lows.map(&:t20))
          long_hi = hi.select { |s| s.t20.nil? || (med_low && s.t20 > 2.5 * med_low) }
          if @percussive && med_low && long_hi.length >= 2
            names = long_hi.map { |s| Analysis.band_label(*s.band) }.join(', ')
            times = long_hi.map { |s| s.t20 ? Analysis.seconds_label(s.t20) : 'never' }.join('/')
            @flags << Flag.new(kind: :sustained_top, mask: { above_hz: 2000.0, from: med_low.round(4) }.freeze,
                               text: "#{names} fall 20 dB in #{times} vs #{Analysis.seconds_label(med_low)} below 2 kHz: a second, sustained source (open hat, cymbal, noise layer)")
          end

          @f0 = pitched_f0(x)
          @residual = nil
          if @f0
            @residual = harmonic_residual(x, @f0)
            if @f0 > 80 && @residual[:sub_share] > 0.05
              rip = low_ripple(x)
              rtxt = rip && rip[1] > 0.3 ? "; the low envelope repeats every #{Analysis.seconds_label(rip[0])} (r #{format('%.2f', rip[1])})" : ''
              @flags << Flag.new(kind: :low_energy, mask: { below_hz: (0.7 * @f0).round(1) }.freeze,
                                 text: "#{(100 * @residual[:sub_share]).round}% of the energy around the fundamental lies below 0.7 f0 " \
                                       "(#{Analysis.hz_label(@f0)}): low energy the note doesn't explain (a kick? a lower layer?)#{rtxt}")
            end
            if @f0 > 80 && @residual[:above_2k_db] > -30 && @residual[:between_share] > 0.35
              @flags << Flag.new(kind: :between_harmonics, mask: nil,
                                 text: "#{(100 * @residual[:between_share]).round}% of the energy above 2 kHz lies between harmonics: noise, grit, or another part")
            end
          end
          @flags.freeze
          @masks = @flags.filter_map(&:mask).freeze
        end

        # True if no rule fired.
        def clean? = @flags.empty?

        def verdict = clean? ? 'clean (no bleed evidence)' : 'not a clean sample?'

        def lines
          head = "bleed screen: #{verdict}#{@f0 ? " (steady f0 #{Analysis.hz_label(@f0)})" : ''}"
          return [head] if clean?
          [head, *@flags.map { |f| "  - #{f}" }, '  (a reason to look, not a verdict: check the image)']
        end

        def to_s = lines.join("\n")

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{verdict}, #{@flags.length} flags>"

        private

        def band_stats(x)
          e = DSP.db(DSP.band_power(x.stft(N_FFT, HOP), N_FFT, BANDS, Signal::RATE), 1e-12)
          top = e.max
          frame = HOP / Signal::RATE.to_f
          rise = (0.020 / frame).round
          BANDS.each_with_index.map do |band, b|
            col = e[true, b].to_a
            pk = col.each_index.max_by { |i| col[i] }
            lvl = col[pk] - top
            t20 = (pk...col.length).find { |i| col[i] < col[pk] - 20 }
            onsets = []
            armed = false
            (pk...col.length).each do |i|
              armed = true if col[i] < col[pk] - 10
              next unless armed
              j = [i + rise, col.length - 1].min
              next unless col[j] - col[i] > 8 && col[j] > top - 50
              k = (i..j).max_by { |q| col[q] }
              onsets << (k * frame).round(3)
              armed = false
            end
            tail = col[[(col.length * 0.8).round, col.length - 1].min]
            BandStat.new(band: band, level: lvl.round(1), peak: (pk * frame).round(4), t20: t20 && ((t20 - pk) * frame).round(4),
                         plateau: (tail - col[pk]).round(1), onsets: onsets.uniq.freeze)
          end
        end

        # The f0 if most frames are voiced and the middle half of them lie
        # within a semitone (a kick's sweep puts its tail below its median),
        # else nil.
        def pitched_f0(x)
          pc = x.pitch_contour
          hz = pc.hz.to_a.reject(&:nan?)
          return nil if pc.hz.empty? || hz.length < pc.hz.length * 0.5
          hz.sort!
          q1 = hz[hz.length / 4]
          q3 = hz[hz.length * 3 / 4]
          return nil if 12 * Math.log2(q3 / q1) > 1.0
          hz[hz.length / 2]
        end

        def harmonic_residual(x, f0)
          n = 4096
          p = x.stft(n, 1024)**2
          hz = STFT.bin_freqs(n, Signal::RATE)
          sub = (hz.lt(0.7 * f0) & hz.gt(25)).cast_to(Numo::DFloat)
          fund = (hz.ge(0.7 * f0) & hz.lt(1.3 * f0)).cast_to(Numo::DFloat)
          h = hz / f0
          between = ((h - h.round).abs.gt(0.15) & hz.gt(2000)).cast_to(Numo::DFloat)
          above = hz.gt(2000).cast_to(Numo::DFloat)
          s = p.dot(sub)
          fu = p.dot(fund)
          bt = p.dot(between)
          ab = p.dot(above)
          tot = p.sum(axis: 1)
          lvl = DSP.db(tot, 1e-20)
          keep = lvl.gt(lvl.max - 30).where
          sub_share = (s[keep] / (s[keep] + fu[keep]).clip(1e-20, nil)).mean
          between_share = (bt[keep] / ab[keep].clip(1e-20, nil) * ab[keep].gt(0)).mean
          above_share = (ab[keep] / tot[keep].clip(1e-20, nil)).mean
          { sub_share: sub_share, between_share: between_share, above_2k_db: 10 * Math.log10(above_share + 1e-20) }.freeze
        end

        # The strongest repetition of the under-150 Hz envelope between 100
        # and 600 ms: [lag seconds, correlation], or nil.
        def low_ripple(x)
          e = DSP.band_power(x.stft(2048, 480), 2048, [[25.0, 150.0]], Signal::RATE)[true, 0]
          return nil if e.length < 30
          e = Numo::NMath.sqrt(e)
          e -= e.mean
          den = (e**2).sum
          return nil if den <= 0
          cs = (0..[60, e.length / 2].min).map { |lag| (e[0...(e.length - lag)] * e[lag..]).sum / den }
          best = [nil, 0.0]
          (10...(cs.length - 1)).each do |lag|
            best = [lag * 0.01, cs[lag]] if cs[lag] > best[1] && cs[lag] >= cs[lag - 1] && cs[lag] >= cs[lag + 1]
          end
          best[0] ? best : nil
        end
      end
    end
  end
end
