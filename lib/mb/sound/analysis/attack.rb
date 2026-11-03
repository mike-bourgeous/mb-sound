module MB
  module Sound
    module Analysis
      # How the sound starts: the first WINDOW (50 ms) after its onset.
      # Round 3's attack window was the second predictor of the
      # maintainer's Bench picks (12 of 24 first, chance 7.5), and looking
      # at first-50-ms waveforms changed several fits (a filter attack read
      # as a pitch envelope, clean sine cycles fitted as squares).
      #
      # - +onset+: the first sample above 1% of the peak (Length::Seconds
      #   from the start of the sound); every other time is from the onset.
      # - +rise+: from the first sample reaching 10% of the attack's peak
      #   magnitude to the first reaching 90% (waveform peaks, so a low
      #   note's rise is read to within about a cycle); +peak_time+ where the
      #   attack's peak is; +attack_peak+/+peak+ (Decibels re full scale)
      #   the attack's and the whole sound's peaks.
      # - +brightness+: RMS frequencies (Hz: the power spectrum's second
      #   moment, from first differences) of 0-10, 15-25, and 40-50 ms (a
      #   filter opening or closing shows as a rising or falling
      #   centroid on steady harmonics).
      # - +clicks+: 1 ms frames whose energy above CLICK_HZ stands
      #   CLICK_DB over every frame within 10 ms (not counting its
      #   neighbors) and within CLICK_FLOOR dB of the attack's level: a
      #   broadband tick, not a waveform's periodic edges.
      # - +clip+: flat tops at the peak (Clip, or nil): runs of at least
      #   CLIP_RUN samples within CLIP_TOLERANCE of the peak magnitude.  A
      #   resampled or lossy copy of a clipped sound ripples at its flat
      #   tops and may not show it; #crest (dB) is there for those.
      # - +pitch+ and +body_pitch+: PerceivedPitch over the first 30 ms
      #   after the onset and over N_FFT samples from 50 ms on (nil when the
      #   sound ends first).
      #
      #     a = Analysis::Attack.new(sound)
      #     a.rise           # => #<MB::Sound::Length::Seconds 0.0021 s>
      #     a.clicks         # => [] or times of ticks
      #     a.distance(other)   # round 3's attack term (Comparison)
      class Attack
        WINDOW = 0.05
        PITCH_WINDOW = 0.03
        BRIGHTNESS = [[0.0, 0.01], [0.015, 0.025], [0.04, 0.05]].map(&:freeze).freeze

        CLICK_HZ = 4000.0
        CLICK_DB = 12.0
        CLICK_FLOOR = 25.0
        CLICK_FRAME = 48

        CLIP_RUN = 8
        CLIP_TOLERANCE = 1e-4

        # Flat tops: +level+ (Decibels re full scale), +runs+ (how many),
        # +share+ of the sound's samples in them, +start+ and +stop+
        # (Length::Seconds from the start of the sound: the first and last
        # run).
        Clip = Data.define(:level, :runs, :share, :start, :stop) do
          def to_h = { level_db: level.decibels, runs: runs, share: share, start: start.to_f, stop: stop.to_f }
          def to_s
            "clipped at #{format('%.1f', level.decibels)} dBFS: #{runs} flat tops (#{format('%.1f', share * 100)}% of samples) " \
              "#{Analysis.seconds_label(start.to_f)}-#{Analysis.seconds_label(stop.to_f)}"
          end
          def inspect = "#<Attack::Clip #{self}>"
        end

        attr_reader :signal, :onset, :rise, :peak_time, :attack_peak, :peak, :brightness, :clicks, :clip, :crest, :pitch, :body_pitch

        # Measures +sound+ (anything Signal.from takes).
        def initialize(sound)
          @signal = Signal.from(sound)
          x = @signal.data
          rate = Signal::RATE
          on = @signal.onset
          @onset = (on / rate.to_f).seconds
          stop = [on + (WINDOW * rate).round, x.length].min
          win = x[on...stop]
          @peak = Analysis.dbfs(@signal.peak)
          rms = @signal.rms
          @crest = rms > 0 ? 20 * Math.log10(@signal.peak / rms) : 0.0

          a = win.abs
          top = a.max
          @attack_peak = Analysis.dbfs(top)
          if top > 0
            t10 = a.ge(top * 0.1).where[0]
            t90 = a.ge(top * 0.9).where[0]
            @rise = ((t90 - t10) / rate.to_f).seconds
            @peak_time = (a.max_index / rate.to_f).seconds
          else
            @rise = 0.0.seconds
            @peak_time = 0.0.seconds
          end

          @brightness = BRIGHTNESS.map { |lo, hi| rms_frequency(x, on + (lo * rate).round, on + (hi * rate).round) }.freeze
          @clicks = find_clicks(x, on).freeze
          @clip = find_clip(x)
          p_stop = [on + (PITCH_WINDOW * rate).round, x.length].min
          @pitch = p_stop - on >= 256 ? PerceivedPitch.new(Signal.new(x[on...p_stop])) : nil
          b_start = on + (WINDOW * rate).round
          @body_pitch = x.length - b_start >= 2048 ? PerceivedPitch.new(Signal.new(x[b_start...[b_start + PerceivedPitch::N_FFT, x.length].min])) : nil
        end

        # Round 3's attack-window distance of +other+ (an Attack or a
        # sound) from this one, both sounds already aligned and cut to one
        # length (Comparison does that): the mean |difference| of 1 ms RMS
        # envelopes over the first 50 ms after sample Signal::ONSET (each
        # in dB re its own whole-sound peak, floored at -60 dB) and of
        # 256-point log spectra (hop 64, floored 50 dB under this sound's
        # peak bin), each divided by 6 dB and added.
        def distance(other)
          Attack.distance(@signal, other.is_a?(Attack) ? other.signal : Signal.from(other))
        end

        # See #distance.
        def self.distance(x, y)
          n = [(WINDOW * Signal::RATE).round + Signal::ONSET, x.length, y.length].min
          ex = Signal.new(x.data[0...n]).envelope_db(48)
          ey = Signal.new(y.data[0...n]).envelope_db(48)
          px = x.envelope_db(48).max
          py = y.envelope_db(48).max
          de = ((ex - px).clip(-60, 0) - (ey - py).clip(-60, 0)).abs.mean
          mx = Signal.new(x.data[0...n]).stft(256, 64)
          my = Signal.new(y.data[0...n]).stft(256, 64)
          fl = mx.max * 10**(-50 / 20.0)
          fl = 1e-12 if fl <= 0
          ls = (Numo::NMath.log10(mx + fl) * 20 - Numo::NMath.log10(my + fl) * 20).abs.mean
          de / 6.0 + ls / 6.0
        end

        def lines
          out = []
          out << "onset #{Analysis.seconds_label(@onset.to_f)}, rise #{Analysis.seconds_label(@rise.to_f)} (10-90%), " \
                 "attack peak #{format('%.1f', @attack_peak.decibels)} dBFS at +#{Analysis.seconds_label(@peak_time.to_f)}" \
                 "#{(@peak.decibels - @attack_peak.decibels).abs > 0.5 ? " (sound peak #{format('%.1f', @peak.decibels)})" : ''}"
          b = @brightness.map { |c| c ? Analysis.hz_label(c) : '-' }
          out << "brightness (RMS frequency) #{b.join(' -> ')} over 0-10, 15-25, 40-50 ms#{brightness_trend}"
          out << (@clicks.empty? ? 'no clicks' : "clicks at #{@clicks.map { |t| "+#{Analysis.seconds_label(t.to_f)}" }.join(', ')}")
          out << (@clip ? @clip.to_s : "no flat tops (crest #{format('%.1f', @crest)} dB)")
          if @pitch
            out << "perceived pitch: attack #{@pitch}" + (@body_pitch ? ", body #{@body_pitch}" : '')
          end
          out
        end

        def to_s = lines.join('; ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{lines.first}>"

        private

        def brightness_trend
          a, _, c = @brightness
          return '' unless a && c && a > 0
          r = c / a
          return ' (darkening: a closing filter?)' if r < 0.7
          return ' (brightening: an opening filter?)' if r > 1.4
          ''
        end

        # The RMS frequency of samples a...b, (rate / 2 pi) * sqrt(sum of
        # squared first differences / sum of squares): the spectrum's power-
        # weighted second moment, read in the time domain so a window
        # shorter than a few cycles doesn't bias it (a centroid of a 10 ms
        # FFT frame of a 110 Hz tone read half its steady value); nil if
        # silent.
        def rms_frequency(x, a, b)
          b = [b, x.length].min
          return nil if b - a < 32
          seg = x[a...b]
          e = (seg**2).sum
          return nil if e <= 0
          d = seg[1..-1] - seg[0...-1]
          Signal::RATE / (2 * Math::PI) * Math.sqrt((d**2).sum / e)
        end

        def find_clicks(x, on)
          rate = Signal::RATE
          a = [on - CLICK_FRAME, 0].max
          b = [on + (WINDOW * rate).round + 12 * CLICK_FRAME, x.length].min
          seg = x[a...b]
          return [] if seg.length < 4 * CLICK_FRAME
          hp = DSP.brickwall(seg, rate, nil, low: CLICK_HZ)
          frames = seg.length / CLICK_FRAME
          e = (hp[0...(frames * CLICK_FRAME)]**2).reshape(frames, CLICK_FRAME).sum(axis: 1)
          hf = DSP.db(e, 1e-20)
          lvl = DSP.db((seg[0...(frames * CLICK_FRAME)]**2).reshape(frames, CLICK_FRAME).sum(axis: 1), 1e-20)
          ref = lvl.max
          last = ((on + WINDOW * rate - a) / CLICK_FRAME).floor
          out = []
          (0...[frames, last + 1].min).each do |f|
            next if hf[f] < ref - CLICK_FLOOR
            near = ((f - 10)..(f + 10)).select { |g| g >= 0 && g < frames && (g - f).abs >= 2 }
            next if near.empty?
            next unless hf[f] - near.map { |g| hf[g] }.max >= CLICK_DB
            t = ((a + f * CLICK_FRAME - on) / rate.to_f).clamp(0.0, nil)
            out << t.round(4).seconds unless out.any? { |s| (s.to_f - t).abs < 0.0025 }
          end
          out
        end

        def find_clip(x)
          top = @signal.peak
          return nil if top <= 0
          near = x.abs.ge(top * (1 - CLIP_TOLERANCE))
          idx = near.where.to_a
          return nil if idx.length < 2 * CLIP_RUN
          runs = []
          start = prev = idx.first
          idx.drop(1).each do |i|
            if i == prev + 1 && (x[i] > 0) == (x[prev] > 0)
              prev = i
              next
            end
            runs << [start, prev] if prev - start + 1 >= CLIP_RUN
            start = prev = i
          end
          runs << [start, prev] if prev - start + 1 >= CLIP_RUN
          return nil if runs.length < 2
          rate = Signal::RATE.to_f
          Clip.new(level: Analysis.dbfs(top), runs: runs.length, share: runs.sum { |s, e| e - s + 1 } / x.length.to_f,
                   start: (runs.first[0] / rate).seconds, stop: (runs.last[1] / rate).seconds)
        end
      end
    end
  end
end
