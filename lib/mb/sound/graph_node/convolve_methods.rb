module MB
  module Sound
    module GraphNode
      # The #convolve DSL method, included in GraphNode and Channels.  Not
      # run per channel (see ChannelDispatch::EXCLUDED): a stereo input goes
      # through one convolver, so true-stereo impulses can cross the sides.
      module ConvolveMethods
        # Convolves this signal with an impulse response (convolution reverb).
        #
        # +impulse+ is a Sample, a sound file's path (read as a Sample, so
        # graph documents may only name files beside them), an NArray (1D,
        # or 2D as [channels, samples]), or an Array of channel NArrays: one
        # channel (every input through it), two (a mono input becomes stereo;
        # a stereo input runs left through the first, right through the
        # second), or four (true stereo: left to left, left to right, right
        # to left, right to right).  An impulse at another sample rate is
        # resampled.
        #
        # Zero latency (the impulse's first 128 samples run in the time
        # domain, the rest as non-uniformly partitioned FFT convolution) and the same output at
        # any buffer size; see GraphNode::Convolver.  The output rings on
        # for the impulse's length after the input ends.
        #
        # Options:
        # +:mix+ - A dry/wet crossfade, 0 (dry) to 1 (wet; a number or node,
        #          clamped), equal power like #delay's: dry * sqrt(1 - mix),
        #          wet * sqrt(mix).  Default nil: +:wet+ and +:dry+ as given.
        # +:wet+, +:dry+ - Levels (dB values, linear numbers, or nodes);
        #                  default wet -10 dB (DEFAULT_WET) and dry 0, the
        #                  convolution alone, about 10 dB under its input
        #                  (maintainer, 2026-11-06); with a +:mix+, wet 1
        #                  and dry 1 crossfaded.
        # +:gain+ - The impulse's gain (dB or linear) after +:normalize+.
        # +:normalize+ - true (default) scales the impulse to unit energy
        #                per output, so broadband sound comes out at about
        #                the level it went in; false keeps its own level.
        # +:predelay+ - Silence before the impulse (seconds or a Length).
        # +:length+ (alias +:trim+) - Keeps this much of the impulse
        #                (seconds or a Length), fading its end out over
        #                +:fade+ (default a quarter of the kept length).
        # +:stretch+ - Resamples the impulse to this many times its length
        #              (STRETCH_RANGE; 1.5 is a room half again as long and
        #              a fifth lower, 0.5 half as long and an octave up),
        #              before +:length+ counts.
        # +:reverse+ - true plays the impulse backwards (reverse reverb),
        #              after +:length+ keeps its start.
        # +:attack+ - Fades the impulse's start in over this long (seconds
        #             or a Length), from +:attack_level+ (dB or linear,
        #             default 0: silence) up to full level: softens the
        #             direct sound and early reflections.
        # +:attack_curve+ - How the attack rises: :linear (default; straight
        #                   in amplitude), :db (evenly in dB from
        #                   +:attack_level+, which must then be above 0, as
        #                   convolution reverb plug-ins draw it), or any
        #                   Curve (a name like :smooth, a Curve, a Proc).
        # +:impulse_width+ - The stereo width of a two- or four-channel
        #                    impulse (1, the default: as recorded; 0: both
        #                    sides the same; above 1 wider): the impulse's
        #                    side (L - R) / 2 scaled before the convolution,
        #                    after +:normalize+ (so narrowing turns the side
        #                    down rather than renormalizing).  Unlike #width
        #                    after the convolution, it keeps a stereo
        #                    input's own image.  No effect on a one-channel
        #                    impulse.
        # +:decay+ - An extra exponential decay: the level the impulse's
        #            end is turned down to (dB or a linear gain under 1,
        #            e.g. -40.db), falling evenly in dB from its start
        #            across the kept length.  Shortens a room without
        #            cutting it off.
        # +:partition+ - A uniform block size in samples (default nil: the
        #                non-uniform plan, a 128-tap head, then 128, 1024,
        #                and 8192-sample partitions; Convolution.plan).
        #
        # Examples (bin/sound.rb):
        #     play file_input('drums.flac').convolve('hall.wav', mix: 0.3)
        #     play file_input('drums.flac').ir('hall.wav')        # wet only, -10 dB
        #     play saw(110).convolve(ir, wet: -6.db, dry: 1, length: 2.5)
        #     [l, r].channels.convolve('true_stereo.wav')     # four channels
        #     play saw(110).ir('hall.wav', stretch: 1.5, decay: -30.db)   # longer and darker, tighter tail
        #     play file_input('drums.flac').ir('hall.wav', length: 1.5, reverse: true, mix: 0.4)
        #     play saw(110).ir('hall.wav', attack: 80.ms, attack_level: -40.db, attack_curve: :db, impulse_width: 0.5)
        def convolve(impulse, mix: nil, wet: nil, dry: nil, gain: 1, normalize: true, predelay: 0, length: nil, trim: nil, fade: nil,
                     stretch: 1, reverse: false, attack: 0, attack_level: 0, attack_curve: :linear, decay: nil, impulse_width: 1,
                     partition: nil)
          raise ArgumentError, 'convolve takes length: or trim: (the same option), not both' if length && trim

          ConvolveMethods.build(self, impulse, mix: mix, wet: wet, dry: dry, gain: gain, normalize: normalize, predelay: predelay,
            length: length || trim, fade: fade, stretch: stretch, reverse: reverse, attack: attack, attack_level: attack_level,
            attack_curve: attack_curve, decay: decay, impulse_width: impulse_width, partition: partition)
        end

        alias ir convolve

        # The default wet level without a +:mix+ (maintainer, 2026-11-06:
        # "wet -10dB normalized, dry 0").
        DEFAULT_WET = -10.db

        # The +:stretch+ ratios #convolve takes.
        STRETCH_RANGE = (0.125..8.0).freeze

        # The #convolve graph for +node+ (a mono node or a stereo bundle).
        def self.build(node, impulse, mix:, wet:, dry:, gain:, normalize:, predelay:, length:, fade:, partition:,
                       stretch: 1, reverse: false, attack: 0, attack_level: 0, attack_curve: :linear, decay: nil, impulse_width: 1)
          inputs = input_nodes(node)
          rate = inputs[0].sample_rate.to_f
          channels = impulse_channels(impulse, rate)

          stretch = Float(stretch)
          unless STRETCH_RANGE.cover?(stretch)
            raise ArgumentError, "convolve's stretch is a ratio from #{STRETCH_RANGE.begin} to #{STRETCH_RANGE.end} (got #{stretch})"
          end
          # (resampled as if the impulse had been recorded at rate / stretch)
          channels = channels.map { |c| Analysis::DSP.resample(c, rate, rate * stretch) } if stretch != 1

          to_samples = ->(v, name) {
            next nil if v.nil?
            s = MB::Sound::Length.samples(v, sample_rate: rate)
            raise ArgumentError, "convolve's #{name} must not be negative (got #{v.inspect})" if s < 0
            s.round
          }

          attack_level = MB::Sound::Decibels.gain_of(attack_level, 'convolve attack_level', zero: true, above_one: false)
          width = Float(impulse_width)
          raise ArgumentError, "convolve's impulse_width is 0 or more (got #{impulse_width.inspect})" unless width >= 0 && width.finite?

          conv = Convolver.new(
            inputs: inputs,
            impulse: channels,
            sample_rate: rate,
            gain: MB::Sound::Decibels.gain_of(gain, 'convolve gain'),
            normalize: normalize,
            predelay: to_samples.(predelay, 'predelay'),
            length: to_samples.(length, 'length'),
            fade: to_samples.(fade, 'fade'),
            reverse: reverse ? true : false,
            attack: to_samples.(attack, 'attack'),
            attack_level: attack_level,
            attack_curve: attack_curve(attack_curve, attack_level),
            decay: decay.nil? ? nil : MB::Sound::Decibels.gain_of(decay, 'convolve decay', above_one: false),
            impulse_width: width,
            partition: partition
          )

          wet = level(wet.nil? ? (mix.nil? ? DEFAULT_WET : 1) : wet, 'wet')
          dry = level(dry.nil? ? (mix.nil? ? 0 : 1) : dry, 'dry')
          dg, wg = DelayMethods.mix_levels(dry, wet, mix)

          wet_sides = conv.outputs
          if wet_sides.length == 1
            dd = Chorus.scale(inputs[0], dg)
            ww = Chorus.scale(wet_sides[0], wg)
            return ww ? (ww.equal?(conv) ? conv : ww) : conv * 0 if dd.nil?
            return dd if ww.nil?
            DelayMethods.ring_sum(ww, dd)
          else
            dry_sides = inputs.length == 1 ? [inputs[0], inputs[0]] : inputs
            StereoDelayMethods.wet_dry(dry_sides, wet_sides, dry: dg, wet: wg, mix: nil)
          end
        end

        # The Curve for #convolve's +:attack_curve+ (nil for the plain
        # linear fade): :db rises evenly in dB from +level+ (a linear gain
        # above 0), which is Curve.db of that level in dB.
        def self.attack_curve(value, level)
          return nil if value.nil? || value == :linear
          if value == :db
            unless level > 0
              raise ArgumentError, "convolve's attack_curve: :db rises evenly in dB from attack_level:, which must be above 0 (e.g. -60.db)"
            end
            return MB::Sound::Curve.db(20 * Math.log10(level))
          end
          MB::Sound::Curve.from(value)
        rescue ArgumentError => e
          raise if value == :db
          raise ArgumentError, "convolve's attack_curve is :linear, :db, or a Curve (#{e.message})"
        end

        # The input nodes of +node+: one or two.
        def self.input_nodes(node)
          outs = node.is_a?(Channels) ? node.outputs : (node.respond_to?(:outputs) && node.channel_count > 1 ? node.outputs : [node])
          raise ArgumentError, "convolve takes a mono or stereo input (got #{outs.length} channels)" unless [1, 2].include?(outs.length)
          outs
        end

        # A level: a node, or a dB value or linear number as a Float.
        def self.level(v, name)
          return v if v.respond_to?(:sample)
          MB::Sound::Decibels.gain_of(v, "convolve #{name}", zero: true, above_one: false)
        end

        # The impulse's channels as DFloats at +rate+ (see #convolve).
        def self.impulse_channels(impulse, rate)
          impulse = Sample[impulse.respond_to?(:to_path) ? impulse.to_path : impulse] if impulse.is_a?(String) || impulse.respond_to?(:to_path)
          from = rate
          chans = case impulse
                  when Sample
                    from = impulse.sample_rate.to_f
                    impulse.to_a
                  when Numo::NArray
                    case impulse.ndim
                    when 1 then [impulse]
                    when 2 then Array.new(impulse.shape[0]) { |c| impulse[c, true] }
                    else raise ArgumentError, "An impulse array is 1D or 2D as [channels, samples] (got #{impulse.ndim} dimensions)"
                    end
                  when Array
                    raise ArgumentError, 'An impulse Array holds one NArray per channel' unless impulse.all? { |c| c.is_a?(Numo::NArray) && c.ndim == 1 }
                    impulse
                  else
                    raise ArgumentError, "An impulse is a Sample, a file path, or NArray channels (got #{impulse.class})"
                  end
          chans = chans.map { |c| Numo::DFloat.cast(c.is_a?(Numo::SComplex) || c.is_a?(Numo::DComplex) ? c.real : c) }
          chans = chans.map { |c| Analysis::DSP.resample(c, from, rate) } if from != rate
          chans
        end
      end
    end
  end
end
