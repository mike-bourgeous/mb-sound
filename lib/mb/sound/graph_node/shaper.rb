module MB
  module Sound
    module GraphNode
      # A waveshaper node: soft clip, hard clip, absolute value, or quantize,
      # with antiderivative antialiasing (see MB::Sound::Shaper) unless
      # +antialias+ is false.  Created by GraphNode#softclip, #clip, #abs,
      # #quantize and their naive a* versions.
      #
      # Antialiased shapers delay the signal by half a sample.  Complex input
      # uses the plain shaper (softclip shapes the magnitude and keeps the
      # phase; abs gives the magnitude).
      class Shaper
        include GraphNode
        include SampleRateHelper

        # :softclip, :clip, :abs, or :quantize.
        attr_reader :mode

        # Shaper parameters (see MB::Sound::FastClip.shape).
        attr_reader :p1, :p2

        # Whether ADAA is used.
        attr_reader :antialias

        # Creates a shaper for +source+.  For :softclip, +p1+ is the
        # threshold and +p2+ the limit (see MB::Sound::SoftestClip); for
        # :clip, the min and max (nil for none); for :quantize, the step.
        def initialize(source, mode:, p1: 0.0, p2: 0.0, antialias: true)
          raise ArgumentError, "Unknown shaper #{mode.inspect}" unless MB::Sound::Shaper::MODES.include?(mode)

          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          @mode = mode
          @p1 = mode == :clip ? (p1 || -Float::INFINITY).to_f : p1.to_f
          @p2 = mode == :clip ? (p2 || Float::INFINITY).to_f : p2.to_f
          @antialias = !!antialias
          MB::Sound::Shaper.params(@mode, @p1, @p2) # checks the parameters
          @state = [0.0, 0.0, 0.0, 0]
          @buf = nil
          @node_type_name = "#{antialias ? '' : 'a'}#{mode}"
        end

        def sources
          { input: @source }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil?
          return complex_shape(data) if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          @buf = Numo::SFloat.zeros(data.length) if @buf.nil? || @buf.length != data.length
          @buf[0..] = data unless MB::Sound::FastArithmetic.copy(@buf, data) # no allocation for SFloat input
          MB::Sound::FastClip.shape(@buf.inplace!, @mode, @p1, @p2, @antialias, @state).not_inplace!
        end

        # Plan layer (see MB::Sound::Plan): one shaper op on this node's
        # state (real inputs; complex inputs stay unfused).
        include Plan::Describable

        def plan_describe(p)
          p.shape(self, p[@source])
        end

        # The state Array the kernels update (see FastClip.shape).
        def plan_state
          @state
        end

        def plan_snapshot
          @state.dup
        end

        def plan_restore(snapshot)
          @state.replace(snapshot)
        end

        def to_s
          args = case @mode
                 when :softclip then "#{@p1}, #{@p2}"
                 when :clip then "#{@p1}..#{@p2}"
                 when :quantize then @p1.to_s
                 else ''
                 end
          "#{super} -- #{@node_type_name}(#{args})"
        end

        private

        def complex_shape(data)
          case @mode
          when :softclip
            MB::Sound::SoftestClip.new(threshold: @p1, limit: @p2).process(data.dup)
          when :abs
            data.abs
          when :quantize
            (data / @p1).round * @p1
          else
            raise ArgumentError, "#{@mode} can't process complex data"
          end
        end
      end
    end
  end
end
