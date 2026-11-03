module MB
  module Sound
    module Analysis
      # A mono sound at 48 kHz for the sound-matching analyzers, with its
      # STFTs, envelopes, and pitch contour computed once and kept (the
      # analyzers of one Report share them).  Build one with Signal.from
      # from anything the analyzers take:
      #
      # - a filename (read with MB::Sound.read, resampled to 48 kHz),
      # - an MB::Sound::Sample (its region in play order, at its level),
      # - audio data (a Numo array, an Array of channels or of numbers) at
      #   +sample_rate:+,
      # - anything `play` takes (a GraphNode, a Channels bundle, a Pitch,
      #   ...), rendered the way MB::Sound.write renders it (no master
      #   gain) for +seconds:+, or until it ends, at most GRAPH_SECONDS.
      #   Rendering advances the graph: analyze a fresh one before playing.
      #
      # Channels are averaged.  Sounds at other rates are resampled to RATE
      # (band-limited, in the FFT domain), so every analysis reads the same
      # frame sizes and the numbers don't depend on the source's rate.
      #
      #     s = Analysis::Signal.from('sounds/piano0.flac', seconds: 1)
      #     s.seconds   # => 1.0
      #     s.stft(1024, 240)   # [frames, 513] magnitudes, kept
      class Signal
        # The analysis rate (Hz).
        RATE = 48000

        # Graphs that don't end render for at most this many seconds when
        # no +seconds:+ is given.
        GRAPH_SECONDS = 4

        # #aligned puts the onset (the first sample above ONSET_LEVEL of
        # the peak) at this sample, as round 3's comparisons did.
        ONSET = 10
        ONSET_LEVEL = 0.01

        # The samples (a frozen Numo::DFloat at RATE).
        attr_reader :data

        # A label for reports and images (a file's basename, a Sample's
        # name, or nil).
        attr_reader :name

        # The rate the sound came at (it was resampled to RATE if
        # different).
        attr_reader :source_rate

        # True if a graph rendered for GRAPH_SECONDS without ending (its
        # analysis covers only that much).
        attr_reader :truncated

        # The Signal of +source+ (see the class description), cut to
        # +seconds:+ (a number or a Length) if given.  +name:+ labels it.
        def self.from(source, seconds: nil, sample_rate: RATE, name: nil)
          limit = seconds && Length.seconds(seconds, sample_rate: RATE)
          raise ArgumentError, "seconds: must be positive (got #{seconds.inspect})" if limit && limit <= 0

          if source.is_a?(Signal)
            return source if limit.nil? && name.nil?
            return new(source.data[0...[(limit * RATE).round, source.length].min], name: name || source.name, source_rate: source.source_rate) if limit
            return new(source.data, name: name, source_rate: source.source_rate, truncated: source.truncated)
          end

          truncated = false
          data, rate, label =
            case source
            when String
              raise ArgumentError, "No such file: #{source}" unless File.exist?(source)
              frames = limit && (limit * RATE).ceil
              [Analysis.mono(MB::Sound.read(source, sample_rate: RATE, max_frames: frames)), RATE, File.basename(source, '.*')]
            when MB::Sound::Sample
              [Analysis.mono(source.to_a), source.sample_rate, source.name&.to_s]
            else
              if Playable.audio_data?(source)
                [Analysis.mono(source), sample_rate, nil]
              else
                d, truncated = render(source, limit)
                [d, RATE, nil]
              end
            end

          data = DSP.resample(data, rate, RATE) if rate.to_f != RATE
          data = data[0...[(limit * RATE).round, data.length].min] if limit
          new(data, name: name || label, source_rate: rate, truncated: truncated)
        end

        # Renders +sound+ (anything `play` takes) as MB::Sound.write does,
        # without the master gain, for +seconds+ or until it ends (at most
        # GRAPH_SECONDS).  Returns [mono DFloat, truncated?].
        def self.render(sound, seconds)
          nodes = Playable.nodes(sound, sample_rate: RATE)
          frames = ((seconds || GRAPH_SECONDS) * RATE).round
          input = nodes.as_input
          out = Numo::DFloat.zeros(frames)
          pos = 0
          ended = false
          while pos < frames
            buf = input.read([800, frames - pos].min)
            if buf.nil? || buf.empty? || buf.any? { |d| d.nil? || d.empty? }
              ended = true
              break
            end
            n = buf[0].length
            out[pos...(pos + n)] = buf.map { |d| Numo::DFloat.cast(d) }.sum / buf.length
            pos += n
          end
          [out[0...pos].dup, seconds.nil? && !ended]
        end

        # +data+ mono at RATE (see Signal.from for other sources).
        def initialize(data, name: nil, source_rate: RATE, truncated: false)
          d = Numo::DFloat.cast(data)
          raise ArgumentError, 'A Signal needs mono (1D) audio' unless d.ndim == 1
          raise ArgumentError, 'A Signal needs at least one sample' if d.length < 1
          d = d.dup if d.equal?(data)
          @data = d.freeze
          @name = name
          @source_rate = source_rate.to_f
          @truncated = truncated
          @cache = {}
        end

        # The length in samples.
        def length = @data.length

        # The length in seconds.
        def seconds = @data.length / RATE.to_f

        # The sample rate (always RATE).
        def sample_rate = RATE

        # The peak magnitude (linear).
        def peak = (@cache[:peak] ||= @data.abs.max)

        # The RMS level (linear).
        def rms = (@cache[:rms] ||= Math.sqrt((@data**2).mean))

        # A Signal of samples +from+...+to+ (seconds; Lengths work too),
        # sharing nothing with this one.
        def slice(from, to = nil)
          a = (Length.seconds(from, sample_rate: RATE) * RATE).round.clamp(0, length)
          b = to ? (Length.seconds(to, sample_rate: RATE) * RATE).round.clamp(a, length) : length
          raise ArgumentError, "Empty slice #{from.inspect}...#{to.inspect}" if b <= a
          Signal.new(@data[a...b], name: @name, source_rate: @source_rate)
        end

        # The first sample above ONSET_LEVEL of the peak (0 for silence).
        def onset
          @cache[:onset] ||= begin
            th = peak * ONSET_LEVEL
            idx = peak > 0 ? @data.abs.gt(th).where : []
            idx.size > 0 ? idx[0] : 0
          end
        end

        # This sound with its onset moved to sample ONSET (cut or
        # zero-padded at the start), as round 3 compared sounds.
        def aligned
          @cache[:aligned] ||= begin
            on = onset
            d = if on >= ONSET
                  @data[(on - ONSET)..]
                else
                  Numo::DFloat.zeros(ONSET - on).concatenate(@data)
                end
            Signal.new(d, name: @name, source_rate: @source_rate, truncated: @truncated)
          end
        end

        # Magnitude STFT [frames, n_fft / 2 + 1] (Analysis::STFT framing:
        # frame i centered on sample i * hop), kept for later calls.
        def stft(n_fft, hop)
          @cache[[:stft, n_fft, hop]] ||= begin
            rows = STFT.count(length, hop)
            out = Numo::DFloat.zeros(rows, n_fft / 2 + 1)
            STFT.each_chunk(@data, n_fft: n_fft, hop: hop) { |r, mag| out[r, true] = mag }
            out.freeze
          end
        end

        # The RMS envelope in dB (floor -100 dB) of consecutive +hop+-sample
        # blocks (the last one partial), kept.
        def envelope_db(hop)
          @cache[[:env, hop]] ||= begin
            frames = (length / hop.to_f).ceil
            padded = Numo::DFloat.zeros(frames * hop)
            padded[0...length] = @data
            sq = (padded**2).reshape(frames, hop).sum(axis: 1)
            counts = Numo::DFloat.new(frames).fill(hop)
            counts[-1] = length - (frames - 1) * hop
            (Numo::NMath.log10((sq / counts).clip(1e-10, nil)) * 10).freeze
          end
        end

        # The highest frequency the sound holds: the top of its long-term
        # spectrum (4096-point frames) within 70 dB of its peak bin,
        # between 2 kHz and 16 kHz (round 3's choice: hearing is weak above
        # 16 kHz, and the MP3s it compared stop there).
        def band
          @cache[:band] ||= begin
            m = stft(4096, 2048)
            p = (m**2).mean(axis: 0)
            top = p.max
            idx = top > 0 ? p.gt(top * 1e-7).where : []
            hz = idx.size > 0 ? idx[-1] * RATE / 4096.0 : 16000.0
            hz.clamp(2000.0, 16000.0)
          end
        end

        # The pitch contour (PitchContour), computed once.
        def pitch_contour
          @cache[:pitch_contour] ||= PitchContour.new(self)
        end

        # A value kept with this Signal under +key+ (the block computes it
        # the first time); for analyzers that share intermediate results.
        def memo(key)
          @cache.fetch(key) { @cache[key] = yield }
        end

        def inspect
          "#<#{self.class.name.sub('MB::Sound::', '')}#{@name ? " #{@name.inspect}" : ''} #{format('%.3f', seconds)} s#{@truncated ? ' (graph cut)' : ''}>"
        end
        alias to_s inspect
      end
    end
  end
end
