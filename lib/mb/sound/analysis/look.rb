require 'tmpdir'

module MB
  module Sound
    module Analysis
      # Pictures for looking at sounds (round 3's look.rb): one PNG with a
      # column per sound (the target first) and four rows, drawn by
      # MB::Sound::Plot (pure Ruby, no process):
      #
      # 1. the whole waveform (clipping shows as flat tops, swells and
      #    fades, a second hit, beating),
      # 2. the first 50 ms (cycle shapes, clicks, a first cycle unlike the
      #    rest, a filter opening),
      # 3. a log-frequency spectrogram (sweeps, moving resonant peaks,
      #    noise bands, low energy under a note, loop seams),
      # 4. a linear spectrogram of the top three octaves under the first
      #    sound's band (comb teeth sliding, phaser notches, HF movement).
      #
      # Axes are labeled in seconds and Hz, so notes can name positions
      # ("at 0.35 s, 3 kHz").  Round 3 read these images (about 1.7k tokens
      # each at 1400 x 920 with the Read tool) before fitting, and they
      # changed decisions on 8 samples; write down what you see, row by
      # row, before choosing what to change.  Sounds are onset-aligned
      # (Signal#aligned) and share one amplitude scale.
      #
      #     Analysis::Look.save('look.png', 'original' => target, 'fit' => render)
      #     Analysis::Look.figure([a, b]).show   # in a terminal
      module Look
        # Image size per column and row (pixels).
        COLUMN_WIDTH = 700
        ROW_HEIGHT = 230
        ROWS = 4

        # The attack row's length (seconds after the start of the aligned
        # sound).
        ATTACK = 0.05

        module_function

        # A Plot::Figure of +sounds+ (a Hash of labels to sounds, an Array,
        # or one sound; anything Signal.from takes), each cut to +seconds:+
        # if given.  +band:+ sets the top-octave rows' band (default the
        # first sound's).
        def figure(sounds, seconds: nil, band: nil)
          signals = signals(sounds, seconds)
          band ||= signals.values.first.band
          peak = signals.values.map(&:peak).max
          peak = 1.0 if peak <= 0
          range = -peak..peak
          plot = MB::Sound::Plot
          charts = []
          signals.each do |name, s|
            charts << plot.waveform({ name => s.data }, title: "#{name}: waveform (#{format('%.3f', s.seconds)} s)", range: range)
          end
          signals.each do |name, s|
            a = s.data[0...[(ATTACK * Signal::RATE).round + Signal::ONSET, s.length].min]
            charts << plot.waveform({ name => a }, title: "#{name}: first 50 ms", range: range)
          end
          signals.each do |name, s|
            fft = s.length > Signal::RATE * 0.5 ? 2048 : 1024
            charts << plot.spectrogram(s.data, title: "#{name}: spectrogram", fft: fft, hop: [fft / 8, (s.length / 300.0).ceil].max,
                                               floor: -80, notes: false, min_freq: 40.0)
          end
          signals.each do |name, s|
            charts << top_octaves(s, band, "#{name}: top 3 octaves (#{Analysis.band_label(band / 8, band)})")
          end
          plot.figure(*charts, columns: signals.length)
        end

        # Writes the figure of +sounds+ (see .figure) to +path+ (.png, or
        # .svg) and returns +path+.  +width:+ and +height:+ default to
        # COLUMN_WIDTH per sound and ROW_HEIGHT per row.
        def save(path, sounds, seconds: nil, band: nil, width: nil, height: nil)
          sig = signals(sounds, seconds)
          figure(sig, band: band).save(path, width: width || COLUMN_WIDTH * sig.length, height: height || ROW_HEIGHT * ROWS)
          path
        end

        # A new PNG path in the temp directory.
        def temp_path
          @count = (@count || 0) + 1
          File.join(Dir.tmpdir, "mb_sound_look_#{Process.pid}_#{@count}.png")
        end

        # A Hash of labels to aligned Signals.
        def signals(sounds, seconds = nil)
          list =
            case sounds
            when Hash then sounds.to_a
            when Array then sounds.each_with_index.map { |s, i| [nil, s, i] }
            else [[nil, sounds]]
            end
          out = {}
          list.each_with_index do |(label, s), i|
            sig = Signal.from(s, seconds: seconds)
            label = (label || sig.name || (i == 0 ? 'target' : "sound #{i + 1}")).to_s
            label = "#{label} (#{i + 1})" if out.key?(label)
            out[label] = sig.aligned
          end
          raise ArgumentError, 'Pass at least one sound' if out.empty?
          out
        end

        # A linear-frequency spectrogram of band / 8 to +band+, dB re the
        # strongest bin there, 60 dB deep.
        def top_octaves(s, band, title)
          plot = MB::Sound::Plot
          n = 2048
          hop = [n / 8, (s.length / 300.0).ceil].max
          z, = plot::Presets.stft_db(s.data, n, hop, -80)
          rate = Signal::RATE
          lo = (band / 8 * n / rate).floor
          hi = [(band * n / rate).ceil, z.shape[0] - 1].min
          zz = z[lo..hi, true]
          top = zz.max
          zz = zz.clip(top - 60, top)
          df = rate.to_f / n
          frames = zz.shape[1]
          plot.chart(title: title) { |c|
            c.x :time
            c.y plot::Scale::Linear.new((lo * df)..(hi * df), label: 'frequency', unit: 'Hz')
            c.heatmap zz, x: 0.0..(frames * hop / rate.to_f), y: (lo * df)..(hi * df), z_scale: plot::Scale::DB.new((top - 60)..top, label: 'level')
          }
        end
      end
    end
  end
end
