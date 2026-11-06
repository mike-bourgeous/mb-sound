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
        # Zero latency (the impulse's first block runs in the time domain,
        # the rest as partitioned FFT convolution) and the same output at
        # any buffer size; see GraphNode::Convolver.  The output rings on
        # for the impulse's length after the input ends.
        #
        # Options:
        # +:mix+ - A dry/wet crossfade, 0 (dry) to 1 (wet; a number or node,
        #          clamped), equal power like #delay's: dry * sqrt(1 - mix),
        #          wet * sqrt(mix).  Default nil: +:wet+ and +:dry+ as given.
        # +:wet+, +:dry+ - Levels (dB values, linear numbers, or nodes);
        #                  default wet 1 and dry 0 (only the convolution),
        #                  or dry 1 with a +:mix+.
        # +:gain+ - The impulse's gain (dB or linear) after +:normalize+.
        # +:normalize+ - true (default) scales the impulse to unit energy
        #                per output, so broadband sound comes out at about
        #                the level it went in; false keeps its own level.
        # +:predelay+ - Silence before the impulse (seconds or a Length).
        # +:length+ (alias +:trim+) - Keeps this much of the impulse
        #                (seconds or a Length), fading its end out over
        #                +:fade+ (default a quarter of the kept length).
        # +:partition+ - The block size in samples (default from the
        #                impulse's length; Convolution.partition_for).
        #
        # Examples (bin/sound.rb):
        #     play file_input('drums.flac').convolve('hall.wav', mix: 0.3)
        #     play saw(110).convolve(ir, wet: -6.db, dry: 1, length: 2.5)
        #     [l, r].channels.convolve('true_stereo.wav')     # four channels
        def convolve(impulse, mix: nil, wet: 1, dry: nil, gain: 1, normalize: true, predelay: 0, length: nil, trim: nil, fade: nil, partition: nil)
          raise ArgumentError, 'convolve takes length: or trim: (the same option), not both' if length && trim

          ConvolveMethods.build(self, impulse, mix: mix, wet: wet, dry: dry, gain: gain, normalize: normalize, predelay: predelay,
            length: length || trim, fade: fade, partition: partition)
        end

        # The #convolve graph for +node+ (a mono node or a stereo bundle).
        def self.build(node, impulse, mix:, wet:, dry:, gain:, normalize:, predelay:, length:, fade:, partition:)
          inputs = input_nodes(node)
          rate = inputs[0].sample_rate.to_f
          channels = impulse_channels(impulse, rate)

          to_samples = ->(v, name) {
            next nil if v.nil?
            s = MB::Sound::Length.samples(v, sample_rate: rate)
            raise ArgumentError, "convolve's #{name} must not be negative (got #{v.inspect})" if s < 0
            s.round
          }

          conv = Convolver.new(
            inputs: inputs,
            impulse: channels,
            sample_rate: rate,
            gain: MB::Sound::Decibels.gain_of(gain, 'convolve gain'),
            normalize: normalize,
            predelay: to_samples.(predelay, 'predelay'),
            length: to_samples.(length, 'length'),
            fade: to_samples.(fade, 'fade'),
            partition: partition
          )

          wet = level(wet, 'wet')
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
