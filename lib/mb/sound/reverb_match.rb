module MB
  module Sound
    # Fits the algorithmic reverb (GraphNode::Reverb's room-size form) to
    # an impulse response (conv-reverb-1, 2026-11-06; the maintainer: "an
    # alternative to convolution for some of the projects would be color
    # and decay matching on the existing reverb").  Measures the impulse
    # (Analysis::ImpulseResponse: per-octave T60, onset, C80, late-tail
    # spectrum, L/R correlation), then:
    #
    # 1. room_size: the candidate in ROOM_SIZES whose C50 and C80 come
    #    closest (the build-up of early energy),
    # 2. decay, the in-loop highpass, and damping or the in-loop lowpass
    #    (the reverb takes one; both are searched and the closer kept): a
    #    Nelder-Mead search over renders of the reverb's impulse, least
    #    squares on log T60 ratios per octave band,
    # 3. predelay: the impulse's onset minus the reverb's own,
    # 4. tone: peaking EQ at the octave centers (1 octave wide) after the
    #    reverb, from the difference of the late-tail band levels (two
    #    passes, since neighbors overlap),
    # 5. width: Channels#width from the late tail's L/R correlation (the
    #    reverb's outputs are decorrelated; width w gives correlation
    #    (1 - w^2) / (1 + w^2)),
    # 6. level: the reverb's +level:+ so the wet impulse has unit energy
    #    per output, as #convolve's normalized impulses do.
    #
    #     m = reverb_match('hall.wav')     # prints the report
    #     play drums.then { |d| m.apply(d, mix: 0.3) }
    #     m.to_ruby                        # "sig.reverb(room_size: ..., ...).peq(...)"
    #     m.settings                       # the reverb's keywords
    #     m.plot('match.png')              # EDC curves and T60 by band
    #
    # The fitted reverb never matches a real room's early reflections (it
    # has no direct sound or discrete echoes; Analysis::ImpulseResponse's
    # C50 and the report show how far off the build-up is).
    class ReverbMatch
      # Room sizes tried for the build-up.
      ROOM_SIZES = [0.1, 0.3, 0.5, 0.7, 0.9].freeze

      # Search limits.
      DAMPING = 0.0..0.97
      LOWPASS = 500.0..20_000.0
      HIGHPASS = 10.0..500.0
      DECAY = 0.05..60.0

      # The fit's seed (the reverb's random delays and modulation).
      SEED = 1

      # The damping search's RMS log T60 error above which the lowpass
      # search runs too.
      LOWPASS_TRY = 0.1

      # Renders of the reverb each search (damping, lowpass) may make.
      MAX_EVALS = 60

      # The impulse's measurements (Analysis::ImpulseResponse).
      attr_reader :impulse

      # The fitted reverb's measurements.
      attr_reader :fitted

      # The reverb's keywords (room_size, decay, damping, highpass,
      # predelay, level, seed, wet, dry, extra_time).
      attr_reader :settings

      # Peaking EQ after the reverb: { Hz => dB }.
      attr_reader :eq

      # The stereo width after the reverb (1 for none; nil for one output).
      attr_reader :width

      # Output channels (1 for a mono impulse, else 2).
      attr_reader :output_channels

      # Renders of the reverb the fit made.
      attr_reader :evaluations

      # Measures +impulse+ (a path, Sample, NArray, or Array of channels;
      # see Analysis::ImpulseResponse) and fits the reverb to it.
      def initialize(impulse, sample_rate: 48000, max_evals: MAX_EVALS)
        @impulse = impulse.is_a?(Analysis::ImpulseResponse) ? impulse : Analysis::ImpulseResponse.new(impulse, sample_rate: sample_rate)
        @rate = @impulse.sample_rate
        @output_channels = @impulse.channels.length > 1 ? 2 : 1
        @max_evals = max_evals
        @evaluations = 0
        @evaluations_at = 0
        @mode = nil
        @room_size = nil
        @t60_fits = nil
        @settings = nil
        @eq = nil
        @width = nil
        @fitted = nil
        @target = @impulse.t60.compact
        raise ArgumentError, 'The impulse decays less than 15 dB in every octave band; no T60 to match' if @target.empty?

        fit
      end

      # The fitted graph on +input+ (a node or bundle): the reverb (wet
      # only), its EQ and width, and dry/wet as #convolve mixes them
      # (+mix+ equal power; default wet only).
      def apply(input, mix: nil, wet: 1, dry: nil)
        sides = GraphNode::ConvolveMethods.input_nodes(input)
        src = sides.length == 1 ? sides[0] : GraphNode::Channels.new(sides)
        w = wet_graph(src)
        wet = GraphNode::ConvolveMethods.level(wet, 'wet')
        dry = GraphNode::ConvolveMethods.level(dry.nil? ? (mix.nil? ? 0 : 1) : dry, 'dry')
        dg, wg = GraphNode::DelayMethods.mix_levels(dry, wet, mix)
        wet_sides = w.is_a?(GraphNode::Channels) ? w.outputs : [w]
        if wet_sides.length == 1
          dd = GraphNode::Chorus.scale(sides[0], dg)
          ww = GraphNode::Chorus.scale(w, wg)
          return ww || w * 0 if dd.nil?
          return dd if ww.nil?
          GraphNode::DelayMethods.ring_sum(ww, dd)
        else
          dry_sides = sides.length == 1 ? [sides[0], sides[0]] : sides
          GraphNode::StereoDelayMethods.wet_dry(dry_sides, wet_sides, dry: dg, wet: wg, mix: nil)
        end
      end

      # The fitted wet graph as Ruby, reading +input+ (a variable name).
      def to_ruby(input = 'sig')
        kw = @settings.merge(output_channels: @output_channels).map { |k, v| "#{k}: #{RubyValue.to_ruby(v)}" }.join(', ')
        code = "#{input}.reverb(#{kw})"
        unless @eq.empty?
          pairs = @eq.map { |f, g| "#{RubyValue.to_ruby(f)} => [#{RubyValue.to_ruby(g)}.db, 1]" }.join(', ')
          code << ".peq(#{pairs})"
        end
        code << ".width(#{RubyValue.to_ruby(@width)})" if @width && @width != 1
        code
      end

      # Errors of the fit: per-band T60 (fitted / impulse - 1), late-tail
      # band levels (fitted - impulse, dB) and their RMS, C50 and C80
      # differences (dB), and the onset difference (seconds).
      def errors
        t60 = @target.to_h { |b, t| f = @fitted.t60[b]; [b, f ? f / t - 1 : nil] }
        tail = tail_difference(@fitted)
        {
          t60: t60,
          t60_rms: Math.sqrt(t60.values.compact.sum { |e| Math.log(1 + e)**2 } / t60.values.compact.length),
          tail: tail,
          tail_rms: Math.sqrt(tail.values.sum { |d| d * d } / tail.length),
          c50: @fitted.c50 - @impulse.c50,
          c80: @fitted.c80 - @impulse.c80,
          onset: @fitted.onset - @impulse.onset,
        }
      end

      def to_s
        e = errors
        label = ->(b) { b >= 1000 ? "#{b / 1000}k" : b.to_s }
        rows = Analysis::ImpulseResponse::BANDS.map { |b|
          t = @impulse.t60[b]
          f = @fitted.t60[b]
          format('  %4s Hz  T60 %6s s -> %6s s (%6s)   tail %+5.1f dB',
            label.(b), t ? format('%.2f', t) : '-', f ? format('%.2f', f) : '-',
            e[:t60][b] ? format('%+.0f%%', 100 * e[:t60][b]) : '-', e[:tail][b] || 0)
        }
        [
          @impulse.to_s,
          'Fitted reverb:',
          "  #{to_ruby}",
          *rows,
          format('  T60 RMS error %.1f%%, tail spectrum RMS %.1f dB, C50 %+.1f dB, C80 %+.1f dB, onset %+.1f ms (%d renders)',
            100 * (Math.exp(e[:t60_rms]) - 1), e[:tail_rms], e[:c50], e[:c80], 1000 * e[:onset], @evaluations),
        ].join("\n")
      end

      def inspect
        "#<#{self.class.name} #{to_ruby}>"
      end

      # A figure: energy decay curves (impulse solid, fit dashed) for a low,
      # middle, and high band and broadband, and T60 by band.  With a
      # +path+ (.png or .svg), saves it there and returns the path.
      def plot(path = nil, width: 1400, height: 900)
        plot = MB::Sound::Plot
        curves = [[nil, 'broadband'], [250, '250 Hz'], [1000, '1 kHz'], [4000, '4 kHz']]
        charts = curves.map { |band, name|
          a, ta = edc_points(@impulse.edc(band))
          b, tb = edc_points(@fitted.edc(band))
          plot.chart(title: "EDC #{name}") { |c|
            c.x :linear, 0..[ta.max, tb.max].max, label: 's'
            c.y :linear, -80..0, label: 'dB'
            c.line a, x: ta, label: 'impulse'
            c.line b, x: tb, label: 'fit', dash: [6, 4]
          }
        }
        bands = @target.keys
        xs = Numo::DFloat.cast(bands)
        imp = Numo::DFloat.cast(bands.map { |b| @impulse.t60[b] })
        fit = Numo::DFloat.cast(bands.map { |b| @fitted.t60[b] || Float::NAN })
        charts << plot.chart(title: 'T60 by octave band') { |c|
          c.x :log, label: 'Hz'
          c.y :linear, label: 's'
          c.line imp, x: xs, label: 'impulse'
          c.points imp, x: xs
          c.line fit, x: xs, label: 'fit', dash: [6, 4]
          c.points fit, x: xs
        }
        tail = tail_difference(@fitted)
        charts << plot.chart(title: 'late-tail level, fit - impulse (dB)') { |c|
          c.x :log, label: 'Hz'
          c.y :linear, -12..12
          c.stems Numo::DFloat.cast(tail.values), x: Numo::DFloat.cast(tail.keys)
        }
        fig = plot.figure(*charts, columns: 3)
        return fig unless path
        fig.save(path, width: width, height: height)
        path
      end

      private

      # Renders the reverb's impulse (a delta through the wet graph) for
      # +seconds+ and measures it.
      def measure(settings, eq: {}, width: nil, seconds: nil, channels: nil)
        @evaluations += 1
        seconds ||= render_seconds(settings[:decay])
        x = Numo::SFloat.zeros((seconds * @rate).round)
        x[0] = 1
        src = MB::Sound::ArrayInput.new(data: [x], sample_rate: @rate)
        node = wet_graph(src, settings: settings.merge(extra_time: 0), eq: eq, width: width)
        outs = node.is_a?(GraphNode::Channels) ? node.outputs : [node]
        res = outs.map { [] }
        loop do
          bufs = outs.map { |o| o.sample(4800) }
          break if bufs.any?(&:nil?)
          bufs.each_with_index { |b, i| res[i] << b.dup } # (#sample reuses its buffers)
        end
        chans = res.map { |r| Numo::DFloat.cast(r[0].concatenate(*r[1..])) }
        chans = chans[0...channels] if channels
        Analysis::ImpulseResponse.new(chans, sample_rate: @rate)
      end

      def render_seconds(decay)
        longest = [@target.values.max, decay].max
        (1.5 * longest + 0.3).clamp(1.0, 30.0)
      end

      # The wet graph on +src+.
      def wet_graph(src, settings: @settings, eq: @eq, width: @width)
        node = src.reverb(**settings, output_channels: @output_channels)
        node = node.peq(eq.to_h { |f, g| [f, [g.db, 1]] }) unless eq.nil? || eq.empty?
        node = node.width(width) if width && width != 1 && @output_channels == 2
        node
      end

      # The reverb's keywords; +absorb+ is { damping: x } or { lowpass: hz }.
      def base_settings(room_size, decay, absorb, highpass)
        s = { room_size: room_size, decay: decay, **absorb }
        s[:highpass] = highpass if highpass
        s.merge(predelay: 0, wet: 1, dry: 0, seed: SEED)
      end

      def fit
        mids = [500, 1000].filter_map { |b| @target[b] }
        mids = @target.values if mids.empty?
        decay = Math.exp(mids.sum { |t| Math.log(t) } / mids.length).clamp(DECAY.begin, DECAY.end)
        high = [4000, 8000].filter_map { |b| @target[b] }
        ratio = high.empty? ? 1.0 : (high.sum / high.length) / decay
        damping = ((1 - ratio) / 0.6).clamp(0.0, 0.9)

        # 1. room size by the early build-up
        @room_size = ROOM_SIZES.min_by { |r|
          m = measure(base_settings(r, decay, { damping: damping }, nil), channels: 1)
          (m.c50 - @impulse.c50).abs + (m.c80 - @impulse.c80).abs
        }

        # 2. decay times per band, with the damping filters and with the
        # in-loop lowpass instead (a cutoff in the audio band bends T60 down
        # over more octaves: dark rooms), keeping the closer
        # (the lowpass search only when damping leaves more than
        # LOWPASS_TRY RMS error: it rarely wins and doubles the renders)
        fits = []
        { damping: [damping, 0.15], lowpass: [Math.log(6000.0), -0.7] }.each do |mode, (a0, a_step)|
          break if mode == :lowpass && Math.sqrt(fits[0][0]) < LOWPASS_TRY

          @mode = mode
          @evaluations_at = @evaluations
          v = nelder_mead([Math.log(decay), a0, Math.log(15.0)], [0.2, a_step, 1.2]) { |w| t60_error(*unpack(w)) }
          fits << [t60_error(*unpack(v)), unpack(v)]
        end
        @t60_fits = fits.map(&:first)
        decay, absorb, highpass = fits.min_by(&:first)[1]
        highpass = nil if highpass < 16

        # 3. predelay
        s = base_settings(@room_size, decay, absorb, highpass)
        m = measure(s)
        s[:predelay] = [(@impulse.onset - m.onset), 0.0].max.round(5)

        # 5. width
        c = @impulse.correlation
        @width = @output_channels == 2 ? (c ? Math.sqrt((1 - c.clamp(-0.9, 0.95)) / (1 + c.clamp(-0.9, 0.95))).round(3) : 1.0) : nil

        # 4. tone (two passes) and 6. level
        @settings = s
        @eq = {}
        2.times do
          m = measure(@settings, eq: @eq, width: @width)
          diff = tail_difference(m)
          mean = diff.values.sum / diff.length
          @eq = Analysis::ImpulseResponse::BANDS.to_h { |b| [b, ((@eq[b] || 0) - (diff[b] - mean)).clamp(-18, 18).round(2)] }
        end
        @eq.reject! { |_, g| g.abs < 0.25 }
        m = measure(@settings, eq: @eq, width: @width)
        energy = m.channels.sum { |ch| (ch**2).sum } / m.channels.length
        @settings[:level] = (1.0 / Math.sqrt(energy)).round(4) if energy > 0
        @settings[:extra_time] = (1.5 * [@target.values.max, decay].max).ceil(1)
        @fitted = measure(@settings, eq: @eq, width: @width)
      end

      # [decay, absorb, highpass] from a search vector (see #fit; @mode is
      # :damping or :lowpass).
      def unpack(v)
        absorb = @mode == :lowpass ? { lowpass: Math.exp(v[1]).clamp(LOWPASS.begin, LOWPASS.end).round(1) } : { damping: v[1].clamp(DAMPING.begin, DAMPING.end).round(4) }
        [Math.exp(v[0]).clamp(DECAY.begin, DECAY.end).round(4), absorb, Math.exp(v[2]).clamp(HIGHPASS.begin, HIGHPASS.end).round(1)]
      end

      # Mean squared log ratio of the reverb's band T60s to the impulse's.
      def t60_error(decay, absorb, highpass)
        m = measure(base_settings(@room_size, decay, absorb, highpass), channels: 1) # (outputs decay alike: half the analysis)
        t = m.t60
        errs = @target.map { |b, want| t[b] ? Math.log(t[b] / want)**2 : 4.0 }
        errs.sum / errs.length
      end

      # An EDC's points down to -80 dB, about 2000 of them, and their times.
      def edc_points(d)
        stop = (d < -80).where.to_a.first || d.length
        stop = [stop, 2].max
        step = stop / 2000 + 1
        idx = Numo::Int64.new((stop + step - 1) / step).seq * step
        [d[idx], Numo::DFloat.cast(idx) / @rate]
      end

      # Late-tail band levels of +m+ minus the impulse's (dB).
      def tail_difference(m)
        a = @impulse.tail_levels
        b = m.tail_levels
        a.keys.to_h { |k| [k, b[k] - a[k]] }
      end

      # Minimizes the block's value over vectors near +start+ (initial
      # simplex along +steps+) within @max_evals evaluations.
      def nelder_mead(start, steps)
        n = start.length
        pts = [start.dup] + (0...n).map { |i| v = start.dup; v[i] += steps[i]; v }
        vals = pts.map { |p| yield p }
        while @evaluations - (@evaluations_at || 0) < @max_evals
          order = (0..n).sort_by { |i| vals[i] }
          pts = order.map { |i| pts[i] }
          vals = order.map { |i| vals[i] }
          break if (vals[-1] - vals[0]).abs < 1e-5

          centroid = (0...n).map { |d| pts[0...n].sum { |p| p[d] } / n }
          refl = centroid.zip(pts[-1]).map { |c, w| c + (c - w) }
          fr = yield refl
          if fr < vals[0]
            exp = centroid.zip(pts[-1]).map { |c, w| c + 2 * (c - w) }
            fe = yield exp
            pts[-1], vals[-1] = fe < fr ? [exp, fe] : [refl, fr]
          elsif fr < vals[-2]
            pts[-1], vals[-1] = refl, fr
          else
            con = centroid.zip(pts[-1]).map { |c, w| c + 0.5 * (w - c) }
            fc = yield con
            if fc < vals[-1]
              pts[-1], vals[-1] = con, fc
            else
              (1..n).each do |i|
                pts[i] = pts[0].zip(pts[i]).map { |b, p| b + 0.5 * (p - b) }
                vals[i] = yield pts[i]
              end
            end
          end
        end
        pts[vals.each_with_index.min[1]]
      end
    end
  end
end
