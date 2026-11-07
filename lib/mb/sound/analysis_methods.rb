module MB
  module Sound
    # Methods related to analyzing sound signals to find things like
    # cross-correlation, peak autocorrelation/estimated frequency, etc.
    module AnalysisMethods
      # Returns the cross correlation array of the two given arrays using
      # FFT-based convolution.
      #
      # The middle value of the output is the zero-shift correlation amount,
      # values to the left are negative shifts, and values to the right are
      # positive shifts.
      def crosscorrelate(a, b)
        Numo::Pocketfft.fftconvolve(Numo::NArray.cast(a), Numo::NArray.cast(b).reverse.conj)
      end

      # Returns the shift of b relative to a that yields the highest
      # cross-correlation value from #crosscorrelate.
      #
      # In other words, for a periodic signal, MB::M.ror(b, peak_correlation(a,
      # b)) will be the closest rotation to approximating a.
      def peak_correlation(a, b)
        v = crosscorrelate(a, b)
        v.max_index - v.length / 2
      end

      # Returns the positive-time-shift section of the cross-correlation of
      # +data+ with itself.
      def autocorrelate(data)
        q = crosscorrelate(data, data)
        mid = q.length / 2
        q[mid..]
      end

      # Returns an estimate in Hz of the fundamental frequency of the given
      # audio +data+.  If +:range+ is a Range, then the peak frequency within
      # that range will be returned.
      def freq_estimate(data, sample_rate: 48000, range: nil, cepstrum: false)
        data = data.sample(48000) if data.is_a?(GraphNode)

        # TODO: decide what method(s) to use.  autocorrelation gives better
        # values for some files (e.g. sounds/piano0.flac), while cepstrum gives
        # better values for others (e.g. sounds/transient_synth.flac).
        #
        # Why does the cepstrum return very bad estimates for
        # piano_120hz_b2.flac while the plot looks very good?
        if cepstrum
          q = ifft(fft(data).map { |v| Math.log(v.abs) }).abs
          #q = ifft(fft(data).map { |v| CMath.log(v ** 2) }).real
          mid = q.length / 2
          q = q[0...mid]
          q[0] = 0
        else
          q = autocorrelate(data)
        end

        plist = peaks(q, 2)
          .reject { |idx, v, sign| sign == -1 || idx == 0 }
          .sort_by { |idx, v, sign| -v }

        plist = plist.select { |idx, _, _| range.cover?(sample_rate / idx.to_f) } if range

        idx = plist[0]&.[](0)

        idx ? sample_rate / idx.to_f : nil
      end

      # Finds all points in the given +narray+ that are larger or smaller than
      # at least +min_distance+ of their neighbors on either side.
      def peaks(narray, min_distance)
        peaks = []
        narray = narray.abs if narray[0].is_a?(Complex)
        narray.each_with_index do |v, idx|
          neighbors = MB::M.fetch_clamp(narray, (idx - min_distance)..(idx + min_distance))

          if neighbors.all? { |n| n == v }
            next
          elsif neighbors.all? { |n| n <= v }
            peaks << [idx, v, 1]
          elsif neighbors.all? { |n| n >= v }
            peaks << [idx, v, -1]
          end
        end
        peaks
      end

      # Analyzes +sound+ for matching it by ear and by eye (see
      # Analysis::Report, design/notes/analysis.md): pitch contour and
      # vibrato, the attack window (onset, rise, brightness, clicks, flat
      # tops, perceived pitch over the attack and the body), amplitude
      # modulation by band, top-octave movement, moving resonant peaks and
      # comb teeth, and the bleed screen.  Prints the report in the console
      # and returns the Analysis::Report.
      #
      # +sound+ is a filename, a Sample, audio data (a Numo array or an
      # Array of channels at +:sample_rate+), or anything `play` takes (a
      # graph renders for +:seconds+, or until it ends, at most
      # Analysis::Signal::GRAPH_SECONDS; rendering advances it).
      #
      # Examples:
      #     analyze 'sounds/pluck.flac'
      #     r = analyze(123.hz.saw.filter(:lowpass, cutoff: 800), seconds: 1)
      #     r.pitch.vibrato         # => nil or Vibrato(rate, depth)
      #     r.to_h                  # plain numbers
      def analyze(sound, seconds: nil, sample_rate: 48000)
        report = Analysis.analyze(sound, seconds: seconds, sample_rate: sample_rate)
        puts report if MB::Sound.live?
        report
      end
      alias analyze_sound analyze

      # Compares +candidate+ with +target+ (any sounds #analyze takes) by
      # round 3's L3 distance (Analysis::Comparison: round 2's spectral
      # loss + 2 x the modulation-spectrum distance + 0.3 x the attack
      # window; lower is closer), term by term.  With a Hash or Array of
      # candidates, ranks them (Analysis.rank) closest first.  Prints the
      # result in the console and returns it.
      #
      # Examples:
      #     compare 'original.wav', 'fit.wav'
      #     compare 'original.wav', 'a' => fit_a, 'b' => fit_b
      def compare(target, candidate = nil, seconds: nil, **candidates)
        list = candidate.is_a?(Hash) || candidate.is_a?(Array) ? candidate : candidates
        result =
          if candidate.nil? || list.equal?(candidate)
            raise ArgumentError, 'Pass a candidate sound, or several as a Hash or Array' if list.empty?
            Analysis.rank(target, list, seconds: seconds)
          else
            raise ArgumentError, 'Pass one candidate or a Hash of them, not both' unless candidates.empty?
            Analysis.compare(target, candidate, seconds: seconds)
          end
        puts result if MB::Sound.live?
        result
      end
      alias compare_sounds compare

      # Fits the algorithmic reverb (#reverb's room-size form) to an impulse
      # response (MB::Sound::ReverbMatch): per-octave decay times, predelay,
      # early build-up, late-tail tone (peaking EQ after the reverb), and
      # stereo width.  Prints the report (T60 per band, impulse vs fit, tail
      # level errors) in the console and returns the ReverbMatch, whose
      # #apply builds the graph on a signal and #to_ruby prints it.  The
      # same impulse plays exactly through #convolve; the match is the
      # cheaper, tweakable cousin (decay, damping, and modulation stay
      # knobs).  +impulse+ is a file path, a Sample, or NArray channels.
      #
      # Examples:
      #     m = reverb_match('hall.wav')
      #     play m.apply(file_input('drums.flac'), mix: 0.3)
      #     m.plot('match.png')            # EDC curves and T60 by band
      #     ruby m.to_ruby
      def reverb_match(impulse, sample_rate: 48000)
        m = ReverbMatch.new(impulse, sample_rate: sample_rate)
        puts m if MB::Sound.live?
        m
      end

      # Writes a PNG for looking at +sounds+ (Analysis::Look: per sound the
      # waveform, the first 50 ms, a spectrogram, and the top three
      # octaves, axes in seconds and Hz) to +path:+ (default a new file in
      # the temp directory), prints the path in the console, and returns
      # it.  Read the image and write down what you see before changing a
      # sound.  A Hash labels the sounds; the first is the target.
      #
      # Examples:
      #     look 'original.wav'
      #     look 'original.wav', fit, path: 'compare.png'
      #     look 'original' => 'orig.wav', 'fit' => fit
      def look(*sounds, path: nil, seconds: nil, **labeled)
        sounds = sounds.first if sounds.length == 1 && sounds.first.is_a?(Hash)
        sounds = labeled if sounds.empty?
        raise ArgumentError, 'Pass one or more sounds' if sounds.empty?
        path ||= Analysis::Look.temp_path
        Analysis.look(sounds, path: path, seconds: seconds)
        puts path if MB::Sound.live?
        path
      end
      alias look_at look

      # Measures loudness per ITU-R BS.1770-4 / EBU R 128 (see
      # MB::Sound::Loudness), returning a Loudness::Result: gated integrated
      # loudness in LUFS (#integrated, alias #lufs), momentary (400 ms) and
      # short-term (3 s) series every 100 ms with their maxima, loudness
      # range in LU (#range, alias #lra; EBU Tech 3342), and true peak in
      # dBTP (4x oversampled; #true_peak, per channel #true_peaks).
      #
      # +data+ is a filename (read in 10 s chunks at the file's own sample
      # rate, so +:sample_rate+ is ignored), an Array of channels (Numo
      # arrays or Arrays), or one Numo array (mono).  Channel weights default
      # by channel count in ffmpeg/SMPTE order (Loudness.default_weights);
      # pass +:weights+ for other layouts.  +:true_peak+ picks the true-peak
      # filter (:annex2, BS.1770-4's example, also for true; :accurate, a
      # 32-tap Kaiser design; see Loudness::TruePeak) or skips it (false,
      # about half the time).
      #
      # Windows before the start count as silence, so short audio still gets
      # momentary, short-term, and integrated values, and the loudness range
      # follows EBU Tech 3342 literally (see Loudness::Analyzer#result and
      # Loudness.range).  See Loudness::TARGETS and #gain_to for
      # normalization targets.
      #
      # Examples:
      #     loudness('sounds/drums.flac').lufs           # => -18.3
      #     loudness([l, r], sample_rate: 44100).true_peak
      #     r = loudness(file); r.gain_to(-14)           # dB to reach -14 LUFS
      def loudness(data, sample_rate: 48000, weights: nil, true_peak: true)
        if data.is_a?(String)
          input = FFMPEGInput.new(data)
          begin
            analyzer = Loudness::Analyzer.new(channels: input.channels, sample_rate: input.sample_rate, weights: weights, true_peak: true_peak)
            chunk = (input.sample_rate * 10).round
            loop do
              buf = input.read(chunk)
              break if buf.nil? || buf[0].nil? || buf[0].empty?
              analyzer.process(buf)
            end
            return analyzer.result
          ensure
            input.close # (ffmpeg's status and pipe now, not at the GC)
          end
        end

        if data.is_a?(GraphNode) || data.is_a?(GraphNode::Channels)
          raise ArgumentError, 'Measure graphs by rendering them to a file first, or use GraphNode#loudness_meter'
        end

        channels = data.is_a?(Numo::NArray) ? [data] : data
        channels = [channels] if channels.is_a?(Array) && channels[0].is_a?(Numeric)
        analyzer = Loudness::Analyzer.new(channels: channels.length, sample_rate: sample_rate, weights: weights, true_peak: true_peak)
        analyzer.process(channels).result
      ensure
        input&.close
      end
    end
  end
end
