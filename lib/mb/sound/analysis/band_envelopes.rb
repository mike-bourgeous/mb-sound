module MB
  module Sound
    module Analysis
      # Band levels over time (1024-point frames every 5 ms, dB), and how
      # the top of the sound moves: the top three octaves under its band in
      # third-octave bands, each band's level relative to the whole sound
      # (smoothed over 35 ms), and per band its spread over time (#std),
      # its 1-8 Hz fluctuation (#fluctuation, RMS dB), and its drift across
      # the sound (#slope, dB from start to end), over frames within 40 dB
      # of the loudest.
      #
      # The maintainer hears high-frequency movement the losses missed
      # (phaser and comb motion up high, descending resonant peaks); round
      # 3's HF families did not rank his Bench picks better than chance on
      # their own (they matter on a few items each), so these are readings
      # for reports and images, not Comparison terms.  SpectralMotion finds
      # the moving peaks and combs themselves.
      #
      #     be = Analysis::BandEnvelopes.new(sound)
      #     be.levels           # [frames, octave bands] dB, every 5 ms
      #     be.top_bands        # third-octave [lo, hi] pairs of the top 3 octaves
      #     be.std, be.fluctuation, be.slope   # per top band, dB
      class BandEnvelopes
        N_FFT = 1024
        HOP = 240
        FRAME_RATE = Signal::RATE / HOP.to_f

        # Octave bands from here up (Hz).
        LOWEST = 125.0

        TOP_OCTAVES = 3
        TOP_PER_OCTAVE = 3

        # Frames this far under the loudest are left out of the top-band
        # statistics.
        RANGE_DB = 40.0

        # Smoothing of the relative levels (frames either side).
        SMOOTH = 3

        # Fluctuation rates (Hz).
        FLUCTUATION = [1.0, 8.0].freeze

        # A top band "moves" when its std or fluctuation reaches this (dB).
        MOVING_DB = 3.0

        attr_reader :signal, :band

        # Octave bands ([lo, hi] Hz) and their levels in dB [frames, bands].
        attr_reader :bands, :levels

        # Frame times (seconds, frame centers).
        attr_reader :times

        # The top bands ([lo, hi] Hz) and their levels relative to the whole
        # sound (dB [frames, top bands], smoothed).
        attr_reader :top_bands, :relative

        # Per top band (Numo::DFloat, dB): spread over time, 1-8 Hz
        # fluctuation (RMS), drift from start to end.
        attr_reader :std, :fluctuation, :slope

        # Measures +sound+ (anything Signal.from takes) up to +band:+ Hz
        # (default the sound's own band).
        def initialize(sound, band: nil)
          @signal = Signal.from(sound)
          @band = (band || @signal.band).to_f
          mag = @signal.stft(N_FFT, HOP)
          rate = Signal::RATE
          @bands = DSP.octave_bands(LOWEST, @band, partial: true)
          @levels = DSP.db(DSP.band_power(mag, N_FFT, @bands, rate), 1e-10).freeze
          @times = ((Numo::DFloat.new(mag.shape[0]).seq * HOP + N_FFT / 2) / rate.to_f).freeze

          @top_bands = DSP.octave_bands(@band / 2**TOP_OCTAVES, @band, TOP_PER_OCTAVE)
          p = DSP.smooth_rows(DSP.band_power(mag, N_FFT, @top_bands, rate), SMOOTH)
          tot = DSP.smooth_rows((mag**2).sum(axis: 1).reshape(mag.shape[0], 1), SMOOTH)
          total_db = DSP.db(tot, 1e-10)
          @relative = (DSP.db(p, 1e-10) - total_db).freeze
          movement(total_db[true, 0])
        end

        # The top bands that move (std or fluctuation at least MOVING_DB),
        # as { [lo, hi] => { std:, fluctuation:, slope: } } in dB.
        def moving
          @top_bands.each_index.select { |b| @std[b] >= MOVING_DB || @fluctuation[b] >= MOVING_DB }.to_h { |b|
            [@top_bands[b], { std: @std[b], fluctuation: @fluctuation[b], slope: @slope[b] }]
          }
        end

        def lines
          return ['top octaves: too short to measure'] if @std.empty?
          range = Analysis.band_label(@top_bands.first[0], @top_bands.last[1])
          out = ["top octaves (#{range}): spread #{format('%.1f', @std.mean)} dB, 1-8 Hz fluctuation #{format('%.1f', @fluctuation.mean)} dB, " \
                 "drift #{format('%+.1f', @slope.mean)} dB across the sound"]
          m = moving
          out << "moving: #{m.map { |(lo, hi), v| "#{Analysis.band_label(lo, hi)} (spread #{format('%.1f', v[:std])}, fluctuation #{format('%.1f', v[:fluctuation])} dB)" }.join(', ')}" unless m.empty?
          out
        end

        def to_s = lines.join('; ')

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{@bands.length} bands to #{Analysis.hz_label(@band)}, #{lines.first}>"

        private

        def empty_movement
          @std = @fluctuation = @slope = Numo::DFloat[].freeze
          nil
        end

        def movement(total_db)
          # (frames whose window runs past the end are left out)
          full = [[(@signal.length - N_FFT) / HOP + 1, 0].max, total_db.length].min
          return empty_movement if full < 20
          total_db = total_db[0...full]
          keep = total_db.ge(total_db.max - RANGE_DB).where
          return empty_movement if keep.size < 20
          r = @relative[keep, true]
          @std = r.stddev(axis: 0).freeze
          cols = r.shape[1]
          @fluctuation = Numo::DFloat.cast(Array.new(cols) { |c| DSP.band_rms(DSP.slow_spectrum(r[true, c], FRAME_RATE), *FLUCTUATION) }).freeze
          @slope = Numo::DFloat.cast(Array.new(cols) { |c| DSP.slope(r[true, c]) * r.shape[0] }).freeze
        end
      end
    end
  end
end
