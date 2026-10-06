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
        #     ChannelMixer::Unison.new([a, b, c], slots: [0, -1, 1], spread: 0.5)
        class Unison < ChannelMixer
          channels :any => :any
          param :spread, default: 0, range: 0..1

          # The gain for every input before panning (see the class
          # description).
          attr_reader :gain

          # The pan slot of every input (-1..1).
          attr_reader :slots

          # The detune offset of every input in semitones, if given (for
          # display; see MB::Sound::Unison.offsets).
          attr_reader :offsets

          # Creates a unison mixer for +inputs+ (see the class description).
          def initialize(inputs, slots: nil, spread: 0, stereo: true, normalize: :power, offsets: nil, sample_rate: nil)
            super(inputs, sample_rate: sample_rate, slots: slots, spread: spread, stereo: stereo, normalize: normalize, offsets: offsets)
          end

          # True if the mixer has two outputs.
          def stereo?
            @stereo
          end

          def gains_for(spread:)
            unless @stereo
              return [Array.new(@slots.length, @gain)]
            end

            pairs = @slots.map { |s|
              left, right = PanLaws.gains(:equal_power, s * spread)
              [left * @pan_gain, right * @pan_gain]
            }
            [pairs.map(&:first), pairs.map(&:last)]
          end

          def to_s
            "Unison #{@slots.length}x (#{@stereo ? 'stereo' : 'mono'}, gain #{MB::M.sigfigs(@gain, 3)}" +
              (@stereo ? ", spread #{params[:spread].is_a?(Numeric) ? MB::M.sigfigs(params[:spread], 3) : params[:spread]})" : ')')
          end

          private

          def setup(inputs, settings)
            n = inputs.length
            slots = settings.delete(:slots) || Array.new(n, 0)
            raise ArgumentError, "Unison needs one pan slot per input (#{n}; got #{slots.length})" unless slots.length == n
            raise ArgumentError, 'Unison pan slots must be numbers in -1..1' unless slots.all? { |s| s.is_a?(Numeric) && (-1..1).cover?(s) }
            @slots = slots.map(&:to_f).freeze

            @stereo = !!settings.delete(:stereo)
            @offsets = settings.delete(:offsets)&.map(&:to_f)&.freeze

            normalize = settings.delete(:normalize)
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
