module MB
  module Sound
    module Plot
      # Ready-made charts for sound: waveforms, spectra, spectrograms,
      # envelopes.  Each returns a Chart (render it with #show, #to_s,
      # #save, ...).  +data+ is a Numo::NArray, an Array of channels, or a
      # Hash of names to channels.
      module Presets
        # Default spectrum and spectrogram floor in dB.
        FLOOR = -100

        module_function

        # A Hash of names to Numo::DFloats from one array, an Array of
        # channels, or a Hash.
        def channels(data, prefix: nil)
          case data
          when Hash
            data.to_h { |k, v| [k.to_s, Mark.array(v)] }
          when Array
            if data.empty? || data[0].is_a?(Numeric)
              { (prefix || '0') => Mark.array(data) }
            else
              data.each_with_index.to_h { |d, i| [prefix ? "#{prefix} #{i}" : i.to_s, Mark.array(d)] }
            end
          when Numo::NArray
            if data.ndim == 2
              data.shape[0].times.to_h { |i| [i.to_s, Mark.array(data[i, true])] }
            else
              { (prefix || '0') => Mark.array(data) }
            end
          else
            { '0' => Mark.array(data) }
          end
        end

        # Time-domain waveform: one line per channel over time (min/max
        # decimated for long signals), on a symmetric amplitude scale.
        def waveform(data, sample_rate: 48000, title: 'waveform', range: nil, fill: false)
          chans = channels(data)
          Plot.chart(title: title) { |c|
            c.x :time, sample_rate: sample_rate
            c.y range ? Scale::Linear.new(range, label: 'amplitude') : Scale::Symmetric.new(label: 'amplitude')
            chans.each do |name, d|
              fill ? c.area(d, label: name, base: 0.0) : c.line(d, label: name)
            end
          }
        end

        # Magnitude spectrum in dB over log frequency (with note names),
        # Hann-windowed and scaled so a full-scale sine reads 0 dB.
        def spectrum(data, sample_rate: 48000, title: 'spectrum', floor: FLOOR, notes: true, range: nil, min_freq: 20.0)
          chans = channels(data)
          Plot.chart(title: title) { |c|
            nyquist = sample_rate / 2.0
            c.x :frequency, min_freq..nyquist, notes: notes
            curves = chans.map { |name, d|
              f, db = spectrum_db(d, sample_rate, floor)
              [name, f, db]
            }
            top = curves.map { |_, _, db| db.max }.max || 0
            c.y Scale::DB.new(range || (floor..[(top / 10.0).ceil * 10, 0].max))
            curves.each do |name, f, db|
              c.line db, x: f, label: name
            end
          }
        end

        # [frequencies, dB] of +d+ (bins from 1).
        def spectrum_db(d, sample_rate, floor)
          n = d.length
          n -= 1 if n.odd?
          d = d[0...n]
          w = hann(n)
          mag = Numo::DFloat.cast(Numo::Pocketfft.rfft(d * w).abs) * (2.0 / w.sum)
          db = 20 * Numo::NMath.log10(mag.clip(10**(floor / 20.0), nil))
          f = Numo::DFloat.new(db.length).seq * (sample_rate.to_f / n)
          [f[1..], db[1..]]
        end

        # A short-time Fourier transform heatmap: time across, frequency up
        # (log with note names, or linear with +log: false+), levels in dB
        # through +colormap+ (default the theme's).  +fft+ is the window
        # length and +hop+ the step in samples.  Multiple channels are
        # mixed.
        def spectrogram(data, sample_rate: 48000, title: 'spectrogram', fft: 2048, hop: nil, floor: -90, log: true, colormap: nil, notes: true, min_freq: 30.0)
          chans = channels(data)
          d = chans.values.reduce { |a, b| a + b }
          hop ||= fft / 4
          z, top = stft_db(d, fft, hop, floor)
          rows = z.shape[0]
          df = sample_rate.to_f / fft
          nyquist = sample_rate / 2.0
          seconds = d.length / sample_rate.to_f
          frames = z.shape[1]

          Plot.chart(title: title) { |c|
            c.x :time
            if log
              c.y :frequency, min_freq..nyquist, notes: notes
            else
              c.y Scale::Linear.new(0..nyquist, label: 'frequency', unit: 'Hz')
            end
            c.heatmap z, x: 0.0..(frames * hop / sample_rate.to_f).clamp(0, seconds + fft / sample_rate.to_f),
              y: (0.5 * df)..((rows + 0.5) * df),
              z_scale: Scale::DB.new((top + floor)..top, label: 'level'), colormap: colormap
          }
        end

        # [rows (bins 1..n/2) x frames of dB, top level in dB]
        def stft_db(d, fft, hop, floor)
          w = hann(fft)
          frames = [((d.length - fft) / hop.to_f).floor + 1, 1].max
          pad = (frames - 1) * hop + fft - d.length
          d = d.concatenate(Numo::DFloat.zeros(pad)) if pad > 0
          z = Numo::DFloat.zeros(fft / 2, frames)
          scale = 2.0 / w.sum
          frames.times do |i|
            seg = d[(i * hop)...(i * hop + fft)] * w
            mag = Numo::DFloat.cast(Numo::Pocketfft.rfft(seg).abs)[1..(fft / 2)] * scale
            z[true, i] = mag
          end
          db = 20 * Numo::NMath.log10(z.clip(1e-12, nil))
          top = (db.max / 6.0).ceil * 6
          [db.clip(top + floor - 1, nil), top]
        end

        # An envelope over time as a filled area (linear, or dB with +db+
        # as the range, e.g. 60).
        def envelope(data, sample_rate: 48000, title: 'envelope', db: nil)
          chans = channels(data)
          Plot.chart(title: title) { |c|
            c.x :time, sample_rate: sample_rate
            if db
              c.y Scale::DB.new(-db..0)
              chans.each { |name, d| c.area 20 * Numo::NMath.log10(d.abs.clip(10**(-db / 20.0), nil)), label: name, base: -db }
            else
              c.y Scale::Linear.new(label: 'level')
              chans.each { |name, d| c.area d, label: name, base: 0.0 }
            end
          }
        end

        # A Hann window of +n+ samples.
        def hann(n)
          @hann ||= {}
          @hann[n] ||= (0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(n).seq * (2 * Math::PI / n))).freeze
        end
      end

      class << self
        # See Presets.waveform.
        def waveform(data, **kwargs) = Presets.waveform(data, **kwargs)

        # See Presets.spectrum.
        def spectrum(data, **kwargs) = Presets.spectrum(data, **kwargs)

        # See Presets.spectrogram.
        def spectrogram(data, **kwargs) = Presets.spectrogram(data, **kwargs)

        # See Presets.envelope.
        def envelope(data, **kwargs) = Presets.envelope(data, **kwargs)
      end
    end
  end
end
