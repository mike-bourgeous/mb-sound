module MB
  module Sound
    module Analysis
      # How the sound's level moves, band by band: the envelope of each
      # octave band (125 Hz up to the sound's band, the last one partial if
      # a third of an octave or more is left; 1024-point frames every 5 ms) in dB, detrended (a decay is not modulation), and its
      # fluctuation by modulation rate.  Round 3 of the voice-match study
      # (2026-11-03) found this the strongest single predictor of the
      # maintainer's Bench picks (his pick ranked first on 14 of 24 items,
      # chance 7.5, p 0.005): candidates fitted to the same original are
      # close in spectrum and differ, to his ears, in how they move.
      #
      #     ms = Analysis::ModulationSpectrum.new(sound)
      #     ms.depths     # [octave bands, MOD_BANDS] RMS fluctuation in dB
      #     ms.peaks      # the clear modulations, merged across bands
      #     ms.distance(other)   # dB, as Comparison's modulation term
      #
      # #depths and #distance are round 3's measure (whole envelopes, the
      # modulation bands of MOD_BANDS, octave bands weighted by their
      # loudness share to the 0.3 power).  #peaks reads the strongest rate
      # in each band over the body of the sound (frames inside the sound
      # within BODY_DB of the loudest, each band's envelope floored FLOOR_DB under its own
      # peak; its spectrum's peak, refined by least-squares sinusoid fits)
      # as a rate and depth (±dB), keeps those holding at least MIN_SHARE of
      # the band's fluctuation and MIN_DEPTH, and merges
      # neighboring bands that move at the same rate (within 15%).
      class ModulationSpectrum
        # Modulation bands (Hz) of #depths and #distance.
        MOD_BANDS = [[0.25, 0.5], [0.5, 1.0], [1.0, 2.0], [2.0, 4.0], [4.0, 8.0], [8.0, 16.0], [16.0, 32.0]].map(&:freeze).freeze

        N_FFT = 1024
        HOP = 240

        # Envelope frames per second.
        FRAME_RATE = Signal::RATE / HOP.to_f

        # The lowest octave band's lower edge (Hz).
        LOWEST = 125.0

        # The rates #peaks looks at (Hz; the lower end rises for short
        # sounds so at least 1.5 cycles fit).
        RATES = 0.25..20.0

        BODY_DB = 30.0
        FLOOR_DB = 40.0
        MIN_DEPTH = 0.5
        MIN_SHARE = 0.3

        # Bands this far under the loudest band (mean power) are left out of
        # #peaks.
        QUIET_DB = 40.0

        # A clear modulation: +bands+ ([lo, hi] Hz pairs it was found in),
        # +rate+ (a Pitch: `rate.lfo` plays it), +depth+ (Decibels: the
        # envelope swings ±depth), +share+ (the part of those bands'
        # fluctuation at that rate, 0..1), +rate_error+ (Hz: about two
        # standard errors of the rate, DSP.sine_fit).
        Peak = Data.define(:bands, :rate, :depth, :share, :rate_error) do
          # The frequency range of the bands ("2-4 kHz").
          def range = Analysis.band_label(bands.first[0], bands.last[1])

          def to_h = { bands: bands, rate_hz: rate.frequency, rate_error_hz: rate_error, depth_db: depth.decibels, share: share }

          def to_s
            "AM #{Analysis.rate_label(rate.frequency)} (rate ±#{Analysis.rate_label(rate_error).sub(' Hz', '')}), " \
              "±#{format('%.1f', depth.decibels)} dB in #{range}"
          end

          def inspect = "#<ModulationSpectrum::Peak #{self}, #{(share * 100).round}% of its fluctuation>"
        end

        # The Signal measured.
        attr_reader :signal

        # The top of the bands (Hz) and the octave bands ([lo, hi] Hz).
        attr_reader :band, :bands

        # Band envelopes in dB [frames, bands], FRAME_RATE frames per second.
        attr_reader :envelopes

        # RMS fluctuation in dB [bands, MOD_BANDS]; +valid+ says which
        # modulation bands have a full period inside the sound.
        attr_reader :depths, :valid

        # Each band's weight in #distance (loudness share^0.3, summing to 1;
        # 0 for a partial top band).
        attr_reader :weights

        # The clear modulations (Peak), deepest first.
        attr_reader :peaks

        # Measures +sound+ (anything Signal.from takes) over octave bands up
        # to +band:+ Hz (default the sound's own band; comparisons use the
        # target's for both sounds).
        def initialize(sound, band: nil)
          @signal = Signal.from(sound)
          @band = (band || @signal.band).to_f
          mag = @signal.stft(N_FFT, HOP)
          @bands = DSP.octave_bands(LOWEST, @band, partial: true)
          power = DSP.band_power(mag, N_FFT, @bands, Signal::RATE)
          @envelopes = DSP.db(power, 1e-10).freeze
          @depths, @valid = depths_of(@envelopes)
          share = power.mean(axis: 0)
          # (#distance reads whole octaves, as round 3 did: a partial top
          # band weighs nothing there)
          @octaves = DSP.octave_bands(LOWEST, @band).length
          w = share**0.3
          w[@octaves..] = 0 if @octaves < @bands.length
          @weights = (w.sum > 0 ? w / w.sum : Numo::DFloat.new(@bands.length).fill(1.0 / @bands.length)).freeze
          @peaks = find_peaks(power, share).freeze
        end

        # The modulation-spectrum distance of +other+ (a ModulationSpectrum
        # over the same bands, or a sound, measured over this one's bands)
        # from this one: per band and valid modulation band the absolute
        # difference of depths (dB), weighted by this sound's band weights.
        def distance(other)
          other = ModulationSpectrum.new(other, band: @band) unless other.is_a?(ModulationSpectrum)
          raise ArgumentError, "Bands differ (#{other.band} vs #{@band} Hz): measure both over one band" unless other.bands == @bands

          tot = 0.0
          wsum = 0.0
          @valid.each_with_index do |ok, k|
            next unless ok
            tot += (@weights * (@depths[true, k] - other.depths[true, k]).abs).sum
            wsum += @weights.sum
          end
          wsum > 0 ? tot / wsum : 0.0
        end

        # Lines of text: one per Peak, or a line saying there is none.
        def lines
          return ["no clear amplitude modulation (#{Analysis.rate_label(RATES.begin)}-#{Analysis.rate_label(RATES.end)})"] if @peaks.empty?
          @peaks.map(&:to_s)
        end

        def to_s = lines.join('; ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{@bands.length} bands to #{Analysis.hz_label(@band)}: #{self}>"

        private

        def depths_of(env)
          frames, cols = env.shape
          dur = frames / FRAME_RATE
          valid = MOD_BANDS.map { |lo, _| lo * dur >= 1.0 }.freeze
          depth = Numo::DFloat.zeros(cols, MOD_BANDS.length)
          cols.times do |c|
            spec = DSP.slow_spectrum(env[true, c], FRAME_RATE)
            MOD_BANDS.each_with_index { |(lo, hi), k| depth[c, k] = DSP.band_rms(spec, lo, hi) }
          end
          [depth.freeze, valid]
        end

        # Peaks per band over the body, merged across neighboring bands.
        def find_peaks(power, share)
          total = DSP.db(power.sum(axis: 1), 1e-10)
          # (frames whose window runs past the end read the padding as a
          # fade: leave them out)
          full = [(@signal.length - N_FFT) / HOP + 1, 0].max
          total = total[0...full] if full < total.length
          return [] if total.empty?
          body = total.ge(total.max - BODY_DB).where
          return [] if body.size < 8
          span = body[0]..body[-1]
          dur = (span.size) / FRAME_RATE
          lo = [RATES.begin, 1.5 / dur].max
          return [] if lo >= RATES.end
          loud = DSP.db(share, 1e-20)

          found = @bands.each_index.filter_map do |c|
            next if loud[c] < loud.max - QUIET_DB
            e = @envelopes[span, c]
            e = e.clip(e.max - FLOOR_DB, nil)
            spec = DSP.slow_spectrum(e, FRAME_RATE)
            rate, _, part = DSP.sine_peak(spec, lo, RATES.end)
            next unless rate && part >= MIN_SHARE
            rate, depth, err = DSP.sine_fit(e, FRAME_RATE, rate)
            next unless depth >= MIN_DEPTH
            [c, rate, depth, part, err]
          end

          groups = []
          found.each do |f|
            g = groups.last
            if g && g.last[0] == f[0] - 1 && (f[1] - g.last[1]).abs <= 0.15 * [f[1], g.last[1]].max
              g << f
            else
              groups << [f]
            end
          end

          groups.map { |g|
            Peak.new(
              bands: g.map { |c, *| @bands[c] }.freeze,
              rate: (g.sum { |f| f[1] } / g.length).hz,
              depth: (g.sum { |f| f[2] } / g.length).db,
              share: g.sum { |f| f[3] } / g.length,
              rate_error: g.map { |f| f[4] }.max
            )
          }.sort_by { |p| -p.depth.decibels }
        end
      end
    end
  end
end
