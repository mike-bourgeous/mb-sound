module MB
  module Sound
    module Analysis
      # Everything the sound-matching analyzers read from one sound, as one
      # report an agent or a person can read (Analysis.analyze, console
      # `analyze`): level, pitch contour, attack window and perceived
      # pitch, amplitude modulation by band, top-octave movement, moving
      # resonances and combs, and the bleed screen.  Each part is its
      # analyzer's object, so the numbers behind a line are one call away.
      #
      #     r = Analysis.analyze('sounds/pluck.flac')
      #     puts r                       # the report
      #     r.pitch.vibrato              # => Vibrato rate 5.5.hz, depth 18.cents
      #     r.attack.clicks              # => []
      #     r.to_h                       # plain numbers
      class Report
        attr_reader :signal, :pitch, :attack, :modulation, :bands, :motion, :bleed

        # Analyzes +sound+ (anything Signal.from takes).
        def initialize(sound)
          @signal = Signal.from(sound)
          @pitch = @signal.pitch_contour
          @attack = Attack.new(@signal)
          @modulation = ModulationSpectrum.new(@signal)
          @bands = BandEnvelopes.new(@signal)
          @motion = SpectralMotion.new(@signal)
          @bleed = Bleed.new(@signal)
        end

        # The report's lines (headings and indented readings).
        def lines
          s = @signal
          head = "#{s.name ? "#{s.name}: " : ''}#{format('%.3f', s.seconds)} s, peak #{format('%.1f', Analysis.dbfs(s.peak).decibels)} dBFS, " \
                 "RMS #{format('%.1f', Analysis.dbfs(s.rms).decibels)} dBFS, band to #{Analysis.hz_label(s.band)}"
          head += " (graph cut at #{Signal::GRAPH_SECONDS} s; pass seconds:)" if s.truncated
          out = [head]
          out << 'pitch:'
          out.concat(@pitch.lines.map { |l| "  #{l}" })
          out << 'attack (first 50 ms):'
          out.concat(@attack.lines.map { |l| "  #{l}" })
          out << 'modulation:'
          out.concat(@modulation.lines.map { |l| "  #{l}" })
          out << 'movement:'
          out.concat((@bands.lines + @motion.lines).map { |l| "  #{l}" })
          out.concat(@bleed.lines)
          out
        end

        def to_s = lines.join("\n")

        def inspect
          "#<#{self.class.name.sub('MB::Sound::', '')} #{@signal.name ? "#{@signal.name.inspect} " : ''}#{format('%.3f', @signal.seconds)} s, " \
            "#{@pitch.median ? @pitch.note_label : 'unpitched'}, #{@modulation.peaks.length} AM peaks, #{@bleed.verdict}>"
        end

        # Pry and IRB show the whole report for a returned Report.
        def pretty_print(q) = q.text(to_s)

        # The readings as plain values (numbers, Strings, Arrays, Hashes),
        # for JSON or an agent's notes.
        def to_h
          {
            name: @signal.name, seconds: @signal.seconds, peak_db: Analysis.dbfs(@signal.peak).decibels, rms_db: Analysis.dbfs(@signal.rms).decibels,
            band_hz: @signal.band, truncated: @signal.truncated,
            pitch: {
              median_hz: @pitch.median&.frequency, note: @pitch.note_label, voiced: @pitch.voiced,
              vibrato: @pitch.vibrato&.to_h, sweep: @pitch.sweep&.to_h,
            },
            attack: {
              onset: @attack.onset.to_f, rise: @attack.rise.to_f, peak_time: @attack.peak_time.to_f,
              attack_peak_db: @attack.attack_peak.decibels, brightness_hz: @attack.brightness, clicks: @attack.clicks.map(&:to_f),
              clip: @attack.clip&.to_h, crest_db: @attack.crest, pitch: @attack.pitch&.note_label, body_pitch: @attack.body_pitch&.note_label,
            },
            modulation: @modulation.peaks.map(&:to_h),
            top_octaves: @bands.std.empty? ? nil : { std_db: @bands.std.mean, fluctuation_db: @bands.fluctuation.mean, slope_db: @bands.slope.mean },
            resonance: @motion.resonance&.to_h, comb: @motion.comb&.to_h,
            bleed: { clean: @bleed.clean?, flags: @bleed.flags.map { |f| { kind: f.kind, text: f.text } }, masks: @bleed.masks },
          }
        end
      end

      class << self
        # A Report of +sound+ (a file, Sample, audio data at +sample_rate:+,
        # or a graph rendered for +seconds:+ or until it ends).
        def analyze(sound, seconds: nil, sample_rate: Signal::RATE)
          Report.new(Signal.from(sound, seconds: seconds, sample_rate: sample_rate))
        end

        # A Comparison of +candidate+ with +target+ (L3 and its terms).
        def compare(target, candidate, seconds: nil, weights: Comparison::WEIGHTS)
          Comparison.new(Signal.from(target, seconds: seconds), Signal.from(candidate, seconds: seconds), weights: weights)
        end

        # A Ranking of +candidates+ (a Hash of labels to sounds, or an Array:
        # labeled by their names or positions) by their distance from
        # +target+, closest first.  +by:+ a term, :total (L3; the default),
        # or :timbre.
        def rank(target, candidates, by: :total, seconds: nil, weights: Comparison::WEIGHTS)
          t = Signal.from(target, seconds: seconds)
          list = candidates.is_a?(Hash) ? candidates.to_a : candidates.each_with_index.map { |c, i| [nil, c, i] }
          entries = list.each_with_index.map { |(label, c), i|
            sig = Signal.from(c, seconds: seconds)
            cmp = Comparison.new(t, sig, weights: weights)
            Ranking::Entry.new(label: label || sig.name || (i + 1).to_s, comparison: cmp, score: cmp[by])
          }
          Ranking.new(entries, by: by)
        end

        # Writes Look's image of +sounds+ to +path+ and returns the path.
        def look(sounds, path:, seconds: nil, **options)
          Look.save(path, sounds, seconds: seconds, **options)
        end

        # +linear+ magnitude as Decibels re full scale (-200 dB for 0).
        def dbfs(linear)
          linear > 0 ? (20 * Math.log10(linear)).db : -200.db
        end

        # "125 Hz", "2 kHz", "2.5 kHz", "12 kHz".
        def hz_label(hz)
          hz = hz.to_f
          return "#{hz.round} Hz" if hz < 1000
          k = hz / 1000
          k >= 10 ? "#{k.round} kHz" : "#{format('%.1f', k).sub(/\.0\z/, '')} kHz"
        end

        # "2-4 kHz", "500 Hz-1 kHz".
        def band_label(lo, hi)
          a = hz_label(lo)
          b = hz_label(hi)
          a.end_with?(' kHz') && b.end_with?(' kHz') ? "#{a.sub(' kHz', '')}-#{b}" : "#{a}-#{b}"
        end

        # A modulation rate: "0.60 Hz", "5.5 Hz", "12 Hz".
        def rate_label(hz)
          hz = hz.to_f
          return format('%.2f Hz', hz) if hz < 1
          return format('%.1f Hz', hz) if hz < 10
          "#{hz.round} Hz"
        end

        # "35 ms", "1.2 ms", "1.25 s".
        def seconds_label(s)
          s = s.to_f
          return "#{format('%.2f', s)} s" if s >= 1
          ms = s * 1000
          ms >= 10 ? "#{ms.round} ms" : "#{format('%.1f', ms)} ms"
        end

        # A note name with cents ("A3", "A3 +12 cents") for +hz+.
        def note_label(hz)
          midi = 69 + 12 * Math.log2(hz.to_f / 440.0)
          n = midi.round
          cents = ((midi - n) * 100).round
          name = MB::Sound::Note.new(n).name
          cents == 0 ? name : format('%s %+d cents', name, cents)
        end
      end
    end
  end
end
