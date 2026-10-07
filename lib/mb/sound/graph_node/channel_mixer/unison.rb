module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Mixes the detuned copies of a unison oscillator (see Pitch#unison)
        # into one channel, or spreads them across a stereo field.
        #
        # Each input has a pan slot from -1 (left) to 1 (right) (+slots:+;
        # see MB::Sound::Unison.pan_slots), scaled by +spread+ (0..1, a
        # number or a graph node): input i goes to position slot[i] × spread
        # with the equal-power pan law, times sqrt(2), so a copy at the
        # center plays at full level in both channels and each channel keeps
        # the mono mix's power (mono and spread versions sound about as loud
        # on two speakers).  With +stereo: false+ there is one output.
        #
        # +normalize+ scales the sum: :power (default) by 1/sqrt(n), which
        # keeps the loudness of uncorrelated (detuned) copies about the same
        # for any n (peaks can pass 1: the copies line up now and then);
        # :peak by 1/n, so the mix never exceeds the copies' peak (it gets
        # quieter as n grows); or a number (1 for a plain sum).
        #
        # +mix+ (0..1, a number or a graph node; default 1) is the level of
        # the side copies relative to the center ones (+centers:+, input
        # indices; see MB::Sound::Unison.center_copies): center copies play
        # at weight 1, side copies at weight +mix+, like a supersaw's mix
        # knob.  The normalization follows the weights w: :power scales by
        # 1/sqrt(sum of w²) and :peak by 1/(sum of w), so the loudness stays
        # about the same while +mix+ moves (mix 0 with one center copy is
        # that copy at full level); a number scales the weighted sum.  At
        # mix 1 every weight is 1 and the gains are exactly those without a
        # mix.  Node values are clipped to 0..1.
        #
        #     ChannelMixer::Unison.new([a, b, c], slots: [0, -1, 1], spread: 0.5)
        #     ChannelMixer::Unison.new([a, b, c], centers: [1], mix: 0.3)
        class Unison < ChannelMixer
          channels :any => :any
          param :spread, default: 0, range: 0..1
          param :mix, default: 1, range: 0..1

          # The gain for every input before panning (see the class
          # description).
          attr_reader :gain

          # The pan slot of every input (-1..1).
          attr_reader :slots

          # The detune offset of every input in semitones, if given (for
          # display; see MB::Sound::Unison.offsets).
          attr_reader :offsets

          # The indices of the center inputs (weight 1 at any +mix+; see the
          # class description).
          attr_reader :centers

          # Creates a unison mixer for +inputs+ (see the class description).
          # Without +centers:+ every input is a center input (+mix+ changes
          # nothing).
          def initialize(inputs, slots: nil, spread: 0, mix: 1, centers: nil, stereo: true, normalize: :power, offsets: nil, sample_rate: nil)
            super(inputs, sample_rate: sample_rate, slots: slots, spread: spread, mix: mix, centers: centers, stereo: stereo, normalize: normalize, offsets: offsets)
          end

          # True if the mixer has two outputs.
          def stereo?
            @stereo
          end

          def gains_for(spread:, mix: 1)
            # Mix 1 keeps the plain gains (bit-identical to a mixer without mix)
            return plain_gains(spread) if mix.is_a?(Numeric) && mix == 1

            mix = mix.is_a?(Numeric) ? mix.to_f.clamp(0.0, 1.0) : mix.clip(0.0, 1.0)
            gain = weighted_gain(mix)
            weights = Array.new(@slots.length) { |i| @center_set[i] ? gain : gain * mix }

            unless @stereo
              return [weights]
            end

            pairs = @slots.each_with_index.map { |s, i|
              left, right = PanLaws.gains(:equal_power, s * spread)
              w = weights[i] * Math.sqrt(2)
              [left * w, right * w]
            }
            [pairs.map(&:first), pairs.map(&:last)]
          end

          def to_s
            mix = params[:mix]
            "Unison #{@slots.length}x (#{@stereo ? 'stereo' : 'mono'}, gain #{MB::M.sigfigs(@gain, 3)}" +
              (mix == 1 ? '' : ", mix #{mix.is_a?(Numeric) ? MB::M.sigfigs(mix, 3) : mix}") +
              (@stereo ? ", spread #{params[:spread].is_a?(Numeric) ? MB::M.sigfigs(params[:spread], 3) : params[:spread]})" : ')')
          end

          private

          # The gains without a mix (every input at @gain).
          def plain_gains(spread)
            unless @stereo
              return [Array.new(@slots.length, @gain)]
            end

            pairs = @slots.map { |s|
              left, right = PanLaws.gains(:equal_power, s * spread)
              [left * @pan_gain, right * @pan_gain]
            }
            [pairs.map(&:first), pairs.map(&:last)]
          end

          # The normalization gain for center weights 1 and side weights
          # +mix+ (a number or NArray; see the class description).
          def weighted_gain(mix)
            centers = @center_set.count(true)
            sides = @slots.length - centers
            case @normalize
            when :power
              total = mix * mix * sides + centers
              total.is_a?(Numeric) ? 1.0 / Math.sqrt(total) : 1.0 / Numo::NMath.sqrt(total)
            when :peak
              1.0 / (mix * sides + centers)
            else
              @gain
            end
          end

          def setup(inputs, settings)
            n = inputs.length
            slots = settings.delete(:slots) || Array.new(n, 0)
            raise ArgumentError, "Unison needs one pan slot per input (#{n}; got #{slots.length})" unless slots.length == n
            raise ArgumentError, 'Unison pan slots must be numbers in -1..1' unless slots.all? { |s| s.is_a?(Numeric) && (-1..1).cover?(s) }
            @slots = slots.map(&:to_f).freeze

            @stereo = !!settings.delete(:stereo)
            @offsets = settings.delete(:offsets)&.map(&:to_f)&.freeze

            centers = settings.delete(:centers)
            centers ||= (0...n).to_a
            raise ArgumentError, 'Unison center copies must be input indices' unless centers.all? { |c| c.is_a?(Integer) && (0...n).cover?(c) }
            raise ArgumentError, 'Unison needs at least one center copy' if centers.empty? && n > 0
            @centers = centers.uniq.sort.freeze
            @center_set = Array.new(n) { |i| @centers.include?(i) }.freeze

            normalize = settings.delete(:normalize)
            @normalize = normalize
            @gain = case normalize
                    when :power then 1.0 / Math.sqrt(n)
                    when :peak then 1.0 / n
                    when Numeric then normalize.to_f
                    else raise ArgumentError, "normalize must be :power, :peak, or a number (got #{normalize.inspect})"
                    end
            @pan_gain = @gain * Math.sqrt(2)
          end

          def output_channels
            @stereo ? 2 : 1
          end
        end
      end
    end
  end
end
