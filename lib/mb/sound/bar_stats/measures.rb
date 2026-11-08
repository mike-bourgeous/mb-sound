module MB
  module Sound
    module BarStats
      # Measures audio beat by beat on a Grid and reduces them to bars,
      # sections, and the song.  Each beat keeps sums (energies, power per
      # band, chroma, peaks, onsets) so a bar or section is measured from
      # its beats' sums, the way it would be measured whole (energies add,
      # peaks take the largest, spectra add before they become dB), not by
      # averaging dB.
      #
      # The measures, in the maintainer's priority order (2026-11-08):
      # - timing: +onset_low+, +onset_mid+, +onset_high+, each band's onset
      #   offset from the beat in ms (positive: late; nil without an onset;
      #   Timing.grid_offsets), the median over a bar or section;
      # - loudness (Loudness::Analyzer, BS.1770 K-weighting): +lufs+ (the
      #   ungated mean loudness of the span), +momentary_max+ and
      #   +short_term_max+ (largest 400 ms / 3 s windows ending in it),
      #   +integrated+ (BS.1770-gated, bars and longer, nil where no 400 ms
      #   block fits), +rms+ and +peak+ (dBFS, all channels), +true_peak+
      #   (dBTP, BS.1770-4 Annex 2), +crest+ (peak minus RMS, dB), +tail+
      #   (the level of each beat's second half re the whole beat, dB: low
      #   when hits die before the next beat; a missing reverb or delay
      #   shows here);
      # - spectral (the mid channel, each beat's own spectrum): +bands+
      #   (octave band levels at Analysis::Spectrum::OCTAVE_CENTERS, dB
      #   RMS), +centroid+ (Hz), +tilt+ (dB/octave over third octaves,
      #   Spectrum.tilt_of);
      # - stereo (two or more channels; nil for mono): +correlation+ (of
      #   the first two channels), +width+ (side re mid, dB), +side_low+,
      #   +side_mid+, +side_high+ (side re mid per Bands band, dB);
      # - harmony: +chroma+ (12 shares, C first; Analysis::Chroma), and
      #   +key+ with +key_r+ (Analysis::Key) for bars and longer.
      class Measures
        # The smallest FFT of a beat's spectrum (85 ms at 48 kHz: shorter
        # beats are zero-padded to it).
        MIN_FFT = 4096

        # Third octaves this many dB under a span's loudest third are left
        # out of its tilt (as Spectrum::GATE leaves out quiet frames).
        TILT_GATE = 40.0

        # Third-octave centers of the spectral sums (Spectrum::CENTERS);
        # every three make one octave band.
        THIRDS = Analysis::Spectrum::CENTERS

        # Numbers rounded for the tables: [digits, columns].
        ROUNDING = {
          2 => %i[lufs momentary_max short_term_max integrated rms peak true_peak crest tail onset_low onset_mid onset_high
                  bands width side_low side_mid side_high],
          3 => %i[tilt correlation key_r],
          4 => %i[chroma],
          1 => %i[centroid],
          6 => %i[seconds length],
        }.flat_map { |d, names| names.map { |n| [n, d] } }.to_h.freeze

        attr_reader :grid, :sample_rate, :analyzer

        # Measures +channels+ (an Array of Numo arrays at +sample_rate+) on
        # +grid+.  +analyzer+ is a Loudness::Analyzer that already read
        # them (one is made otherwise).  +window+ goes to
        # Timing.grid_offsets.
        def initialize(channels, sample_rate, grid, analyzer: nil, window: Timing::WINDOW)
          @channels = channels.map { |c| Numo::DFloat.cast(c) }
          @sample_rate = sample_rate.to_f
          @grid = grid
          @analyzer = analyzer || Loudness::Analyzer.new(channels: @channels.length, sample_rate: @sample_rate).process(@channels)
          @length = @channels.map(&:length).min
          @mono = @channels.length == 1 ? @channels[0] : @channels.sum / @channels.length
          @spans = grid.beat_spans
          @window = window
          # (every instance variable set here, nil until used, so instances
          # keep one shape)
          @beats = @bars = @sections = @song = @maps = nil
          @lufs = @m_max = @s_max = @count = @sq = @tail_sq = @tail_count = @peak = @tp = @lr = @ll = @rr = nil
          @mid_power = @side_power = @thirds = @nthirds = @chroma = @chroma_tuning = @onsets = nil
          measure
        end

        # The beats Table.
        def beats
          @beats ||= Table.from_rows(:beats, @grid.beats.map { |b| [b.bar, b.beat] }, @spans.each_index.map { |i| reduce([i], beat: true) })
        end

        # The bars Table (bars of the grid with at least one beat).
        def bars
          @bars ||= begin
            list = @grid.bars.filter_map { |b| (idx = @grid.beats_in_bar(b.number)).empty? ? nil : [b, idx] }
            Table.from_rows(:bars, list.map { |b, _| b.number }, list.map { |b, idx| reduce(idx, span: [b.seconds, [b.end_seconds, @length / @sample_rate].min]) })
          end
        end

        # The sections Table (empty without sections).
        def sections
          @sections ||= begin
            list = @grid.sections.filter_map { |s| (idx = @grid.beats_in_section(s)).empty? ? nil : [s, idx] }
            Table.from_rows(:sections, list.map { |s, _| s.label }, list.map { |s, idx| reduce(idx, span: [s.seconds, [s.end_seconds, @length / @sample_rate].min]) })
          end
        end

        # The song Table (one row: every beat, and the whole audio for the
        # loudness maxima and integrated loudness).
        def song
          @song ||= Table.from_rows(:song, [:song], [reduce(@spans.each_index.to_a, span: [0.0, @length / @sample_rate])])
        end

        private

        # Per-beat sums.
        def measure
          n = @spans.length
          ranges = @spans.map { |a, b| [[a, 0.0].max, [b, @length / @sample_rate].min] }
          @lufs = @analyzer.mean_loudness_in(ranges)
          @m_max = @analyzer.momentary_max_in(ranges)
          @s_max = @analyzer.short_term_max_in(ranges)

          @count = Array.new(n, 0)
          @sq = Array.new(n, 0.0)     # sum over channels of squares / channels
          @tail_sq = Array.new(n, 0.0)
          @tail_count = Array.new(n, 0)
          @peak = Array.new(n, 0.0)
          @tp = Array.new(n, 0.0)
          @lr = Array.new(n, 0.0)
          @ll = Array.new(n, 0.0)
          @rr = Array.new(n, 0.0)
          stereo = @channels.length >= 2
          hist = Loudness::TruePeak::PHASES[0].length - 1

          ranges.each_with_index do |(a, b), i|
            s0 = (a * @sample_rate).round
            s1 = (b * @sample_rate).round.clamp(s0, @length)
            next if s1 <= s0
            mid = (s0 + s1) / 2
            @count[i] = s1 - s0
            @tail_count[i] = s1 - mid
            @channels.each do |c|
              seg = c[s0...s1]
              @sq[i] += (seg * seg).sum / @channels.length
              tail = c[mid...s1]
              @tail_sq[i] += (tail * tail).sum / @channels.length
              @peak[i] = [@peak[i], seg.abs.max].max
              ext = Numo::DFloat.zeros(hist + s1 - s0)
              h0 = [s0 - hist, 0].max
              ext[(hist - (s0 - h0))...hist] = c[h0...s0] if s0 > h0
              ext[hist..] = seg
              @tp[i] = [@tp[i], Loudness::TruePeak.oversampled_max(ext, s1 - s0), seg.abs.max].max
            end
            if stereo
              l = @channels[0][s0...s1]
              r = @channels[1][s0...s1]
              @lr[i] = (l * r).sum
              @ll[i] = (l * l).sum
              @rr[i] = (r * r).sum
            end
          end

          measure_spectra(ranges, stereo)
          measure_chroma(ranges)
          @onsets = Timing.grid_offsets(@mono, @sample_rate, @grid, window: @window)
        end

        # Per beat, the power spectrum of the beat's own samples (one FFT
        # of the span, zero-padded to a power of two: by Parseval its
        # power sums to the span's energy, so a hit on the beat counts in
        # its beat whole, and beats add up to their bar) summed by third
        # octave, the centroid's sums, and the mid and side power by
        # Bands band.
        def measure_spectra(ranges, stereo)
          side = stereo ? (@channels[0] - @channels[1]) * 0.5 : nil
          @mid_power = []
          @side_power = stereo ? [] : nil
          ranges.each do |a, b|
            s0 = (a * @sample_rate).round
            s1 = (b * @sample_rate).round.clamp(s0, @length)
            n = MIN_FFT
            n *= 2 while n < s1 - s0
            mid_map, lmh = spectral_maps(n)
            if s1 > s0
              @mid_power << power(@mono[s0...s1], n).dot(mid_map)
              @side_power << power(side[s0...s1], n).dot(lmh) if stereo
            else
              @mid_power << Numo::DFloat.zeros(mid_map.shape[1])
              @side_power << Numo::DFloat.zeros(3) if stereo
            end
          end
          @thirds = spectral_maps(MIN_FFT)[2]
          @nthirds = @thirds.length
        end

        # The power spectrum of +x+ zero-padded to +n+ samples.
        def power(x, n)
          Numo::Pocketfft.rfft(Bands.pad(x, n)).abs**2
        end

        # [mid map (bins x (thirds, total, f, low/mid/high)), low/mid/high
        # map, thirds kept] for +n+-point spectra (cached).
        def spectral_maps(n)
          @maps ||= {}
          @maps[n] ||= begin
            kept, map = Analysis::Spectrum.band_map(n, @sample_rate, centers: THIRDS, per_octave: 3)
            f = Analysis::STFT.bin_freqs(n, @sample_rate)
            lmh = Numo::DFloat.zeros(f.length, 3)
            lmh[f.lt(Bands::EDGES[0]).where, 0] = 1.0
            lmh[(f.ge(Bands::EDGES[0]) & f.lt(Bands::EDGES[1])).where, 1] = 1.0
            lmh[f.ge(Bands::EDGES[1]).where, 2] = 1.0
            [Numo::DFloat.hstack([map, Numo::DFloat.ones(f.length, 1), f.reshape(f.length, 1), lmh]), lmh, kept]
          end
        end

        # Rows of +cols+ summed over each [first, last) frame range.
        def sums_by(cols, ranges)
          c = Numo::DFloat.zeros(cols.shape[0] + 1, cols.shape[1])
          c[1..-1, true] = cols.cumsum(axis: 0)
          ranges.map { |fa, fb|
            fa = fa.clamp(0, cols.shape[0])
            fb = fb.clamp(fa, cols.shape[0])
            c[fb, true] - c[fa, true]
          }
        end

        # Per-beat chroma sums (Analysis::Chroma's frames centered in the
        # beat).
        def measure_chroma(ranges)
          chroma = Analysis::Chroma.new(@mono[0...@length], sample_rate: @sample_rate)
          hop = chroma.hop
          @chroma_tuning = chroma.tuning
          @chroma = sums_by(chroma.frames, ranges.map { |a, b| [(a * @sample_rate / hop).ceil, (b * @sample_rate / hop).ceil] })
        end

        # The measures of the beats at indices +idx+ (see the class
        # description); +span+ ([start, end] seconds) for bars and longer.
        def reduce(idx, beat: false, span: nil)
          first = idx.first
          start = span ? span[0] : @spans[first][0]
          stop = span ? span[1] : @spans[first][1]
          count = idx.sum { |i| @count[i] }
          sq = idx.sum { |i| @sq[i] }
          rms = count > 0 ? db(sq / count) : nil
          peak = idx.map { |i| @peak[i] }.max
          tp = idx.map { |i| @tp[i] }.max
          tail_count = idx.sum { |i| @tail_count[i] }
          tail = count > 0 && tail_count > 0 && sq > 0 ? db((idx.sum { |i| @tail_sq[i] } / tail_count) / (sq / count)) : nil

          energy = idx.sum { |i| @lufs[i] && @count[i] > 0 ? Loudness.energy(@lufs[i]) * @count[i] : 0.0 }
          lufs = count > 0 ? Loudness.lufs(energy / count) : nil
          range = [[start, 0.0].max, stop]
          m_max = span ? @analyzer.momentary_max_in([range])[0] : @m_max[first]
          s_max = span ? @analyzer.short_term_max_in([range])[0] : @s_max[first]

          row = { seconds: start, length: stop - start }
          Bands::NAMES.each do |band|
            values = idx.filter_map { |i| @onsets[band][i] }
            row[:"onset_#{band}"] = values.empty? ? nil : Analysis::DSP.median(values) * 1000
          end
          row.merge!(lufs: lufs, momentary_max: m_max, short_term_max: s_max)
          row[:integrated] = @analyzer.loudness_in([range])[0] unless beat
          row.merge!(rms: rms, peak: peak && db(peak**2), true_peak: tp && db(tp**2), crest: rms && peak && peak > 0 ? db(peak**2) - rms : nil, tail: tail)

          mid = idx.map { |i| @mid_power[i] }.sum
          total = mid[@nthirds]
          if total > 0 && rms
            thirds = (0...@nthirds).map { |k| mid[k] }
            octaves = thirds.each_slice(3).map { |t| t.sum }
            row[:bands] = octaves.map { |p| p > 0 ? rms + db(p / total) : -Float::INFINITY }
            row[:centroid] = mid[@nthirds + 1] / total
            # (thirds more than TILT_GATE under the loudest are left out: a
            # noise floor under a kick stem isn't its tilt)
            levels = @thirds.each_with_index.to_h { |c, k| [c, thirds[k] > 0 ? db(thirds[k] / total) : -Float::INFINITY] }
            top = levels.values.max
            row[:tilt] = Analysis::Spectrum.tilt_of(levels.transform_values { |v| v >= top - TILT_GATE ? v : -Float::INFINITY })
          else
            row.merge!(bands: nil, centroid: nil, tilt: nil)
          end

          if @side_power
            ll = idx.sum { |i| @ll[i] }
            rr = idx.sum { |i| @rr[i] }
            row[:correlation] = ll > 0 && rr > 0 ? idx.sum { |i| @lr[i] } / Math.sqrt(ll * rr) : nil
            side = idx.map { |i| @side_power[i] }.sum
            mids = (0...3).map { |k| mid[@nthirds + 2 + k] }
            # (-Infinity: no side at all; nil: nothing in the mid either)
            row[:width] = mids.sum > 0 ? db(side.sum / mids.sum) : nil
            # (bands holding under -60 dB of the mid are left out: their
            # ratios are noise)
            Bands::NAMES.each_with_index { |band, k| row[:"side_#{band}"] = mids[k] > mids.sum * 1e-6 ? db(side[k] / mids[k]) : nil }
          end

          ch = idx.map { |i| @chroma[i] }.sum
          row[:chroma] = ch.sum > 0 ? (ch / ch.sum).to_a : nil
          unless beat
            key = row[:chroma] && Analysis::Key.detect(row[:chroma])
            row[:key] = key&.key
            row[:key_r] = key&.correlation
          end
          round(row)
        end

        # +power+ in dB (-Infinity for 0).
        def db(power)
          power > 0 ? 10 * Math.log10(power) : -Float::INFINITY
        end

        # +row+ with numbers rounded per ROUNDING.
        def round(row)
          row.to_h { |k, v|
            d = ROUNDING[k]
            v =
              if d.nil? then v
              elsif v.is_a?(Array) then v.map { |e| e.is_a?(Float) && e.finite? ? e.round(d) : e }
              elsif v.is_a?(Float) && v.finite? then v.round(d)
              else v
              end
            [k, v]
          }
        end
      end
    end
  end
end
