require 'json'

module MB
  module Sound
    module SoundGuard
      # A small perceptual summary of a render (design/notes/sound_guards.md):
      # what the golden set commits instead of audio or an md5.  Everything
      # is measured on the render as a listener gets it (the mix, after the
      # master), with existing analysis code: BS.1770 loudness
      # (Loudness::Analyzer) and Structure::Frames' mel spectrogram and onset
      # envelope.
      #
      # Features (FORMAT 1):
      # +loudness+ - integrated LUFS, true peak (dBTP), loudness range (LU),
      #              sample peak (dBFS).
      # +momentary+ - momentary loudness (400 ms) every 100 ms (LUFS).
      # +mel+ - a 32-band mel spectrum (30 Hz-16 kHz, dB of mean power) per
      #         SEGMENT seconds, and +mel_mean+ over the whole render.
      # +envelope+ - frame energy in dB every ENVELOPE_HOP samples.
      # +onsets+ - [seconds, strength] at peaks of the onset envelope.
      # +centroid+ - the spectral centroid of the mean spectrum (Hz).
      # +stereo+ - side/mid energy (dB) overall, per band (<150 Hz, 150 Hz-2
      #            kHz, above), and per segment; L/R correlation.  nil for
      #            mono.
      #
      # About 1 KB per second of audio as JSON (rounded to 0.01-0.1 dB).
      # Compare two with #compare (a Comparison).
      class Fingerprint
        # Bump when features change meaning; old fingerprints then need
        # `rake golden:refingerprint` (from the approved renders).
        FORMAT = 1

        # Seconds per spectrum/width segment.
        SEGMENT = 0.5

        # Mel bands kept (pairs of Structure::Frames' 64).
        MEL_BANDS = 32

        # Envelope hop in samples (two Frames hops).
        ENVELOPE_HOP = 2 * Structure::Frames::HOP

        # Values below this (dB, LUFS) are stored as it (silence).
        FLOOR = -120.0

        # Onset peaks: local maxima of Frames#onset over +/- ONSET_RADIUS
        # frames at least ONSET_MIN high (units of the envelope's deviation).
        ONSET_RADIUS = 3
        ONSET_MIN = 1.0

        # Width bands (Hz).
        WIDTH_BANDS = [0.0...150.0, 150.0...2000.0, 2000.0..].freeze

        attr_reader :data

        # Measures +source+: a file name, or an Array of Numo channels at
        # +sample_rate+.  +meta+ is stored as-is under :source (what made the
        # render).
        def self.extract(source, sample_rate: 48000, name: nil, meta: nil)
          channels = source.is_a?(String) ? MB::Sound.read(source) : source
          channels = channels.map { |c| Numo::SFloat.cast(c) }
          Extractor.new(channels, sample_rate).fingerprint(name: name, meta: meta)
        end

        # Reads a fingerprint written by #save.
        def self.load(path)
          new(JSON.parse(File.read(path), symbolize_names: true))
        end

        def initialize(data)
          data = data.to_h
          format = data[:format]
          raise ArgumentError, "Fingerprint format #{format.inspect} is not #{FORMAT} (re-extract it: rake golden:refingerprint)" unless format == FORMAT
          @data = data
        end

        def [](key)
          @data[key]
        end

        def name = @data[:name]
        def duration = @data[:duration]

        # Compares +other+ (the new render) against this one (the approved
        # one): see Comparison.
        def compare(other, thresholds: Comparison::THRESHOLDS)
          Comparison.new(self, other, thresholds: thresholds)
        end

        # JSON with one top-level key per line and one segment per line, so
        # diffs of committed fingerprints stay readable.
        def to_json(*)
          lines = @data.map { |k, v|
            body = case v
                   when Array
                     if v.first.is_a?(Array)
                       "[\n" + v.map { |row| "    #{JSON.generate(row)}" }.join(",\n") + "\n  ]"
                     else
                       JSON.generate(v)
                     end
                   else
                     JSON.generate(v)
                   end
            "  #{JSON.generate(k.to_s)}: #{body}"
          }
          "{\n#{lines.join(",\n")}\n}\n"
        end

        def save(path)
          File.write(path, to_json)
          self
        end

        # Computes the features of one render.
        class Extractor
          def initialize(channels, sample_rate)
            raise ArgumentError, 'No audio to fingerprint' if channels.empty? || channels[0].empty?
            @channels = channels
            @sample_rate = sample_rate
            @mono = channels.length == 1 ? Numo::DFloat.cast(channels[0]) : Numo::DFloat.cast(channels.sum) / channels.length
            @momentary = nil
          end

          def fingerprint(name:, meta:)
            frames = Structure::Frames.new(@mono, sample_rate: @sample_rate)
            centers = band_centers(frames)
            mel = mel_power(frames)
            seg = segments(frames)

            data = {
              format: FORMAT,
              name: name&.to_s,
              sample_rate: @sample_rate,
              channels: @channels.length,
              duration: (@mono.length.to_f / @sample_rate).round(4),
              loudness: loudness,
              momentary: nil,
              segment_seconds: SEGMENT,
              mel_hz: centers.map { |c| c.round(1) },
              centroid: centroid(mel, centers).round(1),
              mel_mean: db(mel.mean(axis: 0)).to_a.map { |v| v.round(1) },
              segment_db: seg.map { |r| db_value(mel[r, true].sum(axis: 1).mean).round(1) },
              mel: seg.map { |r| db(mel[r, true].mean(axis: 0)).to_a.map { |v| v.round(1) } },
              envelope_hop: ENVELOPE_HOP,
              envelope: envelope(frames),
              onsets: onsets(frames),
              stereo: stereo(frames, seg),
              source: meta,
            }
            data[:momentary] = @momentary
            Fingerprint.new(data)
          end

          private

          def db_value(power)
            power > 0 ? [10 * Math.log10(power), FLOOR].max : FLOOR
          end

          def db(power)
            (10 * Numo::NMath.log10(power.clip(1e-30, nil))).clip(FLOOR, nil)
          end

          def loudness
            l = MB::Sound.loudness(@channels, sample_rate: @sample_rate)
            fix = ->(v) { v && v.finite? ? v.round(2) : FLOOR }
            @momentary = l.momentary.to_a.map { |v| v.finite? ? [v, FLOOR].max.round(1) : FLOOR }
            sample_peak = @channels.map { |c| c.abs.max }.max
            {
              integrated: fix.(l.integrated),
              true_peak: fix.(l.true_peak),
              range: fix.(l.range),
              sample_peak: db_value(sample_peak.to_f**2).round(2),
            }
          end

          # Mel power (linear) in MEL_BANDS bands per frame (frames x bands).
          def mel_power(frames)
            p = 10**(frames.logmel / 10)
            p[true, (0...Structure::Frames::N_MEL).step(2).to_a] + p[true, (1...Structure::Frames::N_MEL).step(2).to_a]
          end

          def band_centers(frames)
            c = frames.mel_centers
            (0...MEL_BANDS).map { |i| Math.sqrt(c[2 * i] * c[2 * i + 1]) }
          end

          # Frame index ranges of each SEGMENT.
          def segments(frames)
            per = SEGMENT * frames.fps
            count = (frames.count / per).ceil
            (0...count).map { |s| (s * per).round...[((s + 1) * per).round, frames.count].min }.reject { |r| r.size == 0 }
          end

          def centroid(mel, centers)
            m = mel.mean(axis: 0)
            total = m.sum
            total > 0 ? (m * Numo::DFloat.cast(centers)).sum / total : 0.0
          end

          def envelope(frames)
            e = 10**(frames.energy / 10)
            n = e.length / 2
            pairs = n > 0 ? (e[(0...(2 * n)).step(2).to_a] + e[(1...(2 * n)).step(2).to_a]) / 2 : e
            db(pairs).to_a.map { |v| v.round(1) }
          end

          def onsets(frames)
            o = frames.onset
            n = o.length
            r = ONSET_RADIUS
            list = []
            n.times do |i|
              v = o[i]
              next if v < ONSET_MIN
              lo = [i - r, 0].max
              hi = [i + r, n - 1].min
              next unless v >= o[lo..hi].max
              next if list.any? && (i - list.last[0]) <= r
              list << [i, v]
            end
            list.map { |i, v| [frames.seconds(i).round(3), v.round(2)] }
          end

          # +mid+ is the Frames of the mono mix, (l + r) / 2.
          def stereo(mid, seg)
            return nil unless @channels.length == 2
            l = Numo::DFloat.cast(@channels[0])
            r = Numo::DFloat.cast(@channels[1])
            side = Structure::Frames.new((l - r) * 0.5, sample_rate: @sample_rate)
            # Frames floors each spectrogram 80 dB under its own loudest
            # value; an exactly mono render's side is all zeros there
            mp = 10**(mid.logmel / 10)
            sp = 10**(side.logmel / 10)
            sp = sp * 0 if (r - l).abs.max == 0
            centers = mid.mel_centers
            bands = WIDTH_BANDS.map { |range|
              idx = centers.each_index.select { |i| range.cover?(centers[i]) }
              ratio_db(sp[true, idx].sum, mp[true, idx].sum)
            }
            ll = (l * l).sum
            rr = (r * r).sum
            {
              width: ratio_db(sp.sum, mp.sum),
              band_width: bands,
              correlation: ll > 0 && rr > 0 ? ((l * r).sum / Math.sqrt(ll * rr)).round(4) : 1.0,
              segment_width: seg.map { |rg| ratio_db(sp[rg, true].sum, mp[rg, true].sum) },
            }
          end

          # Side/mid in dB, clamped to -60..+20 (-60 is "mono").
          def ratio_db(side, mid)
            return -60.0 if mid <= 0 || side <= 0
            (10 * Math.log10(side / mid)).clamp(-60.0, 20.0).round(2)
          end
        end
      end
    end
  end
end
