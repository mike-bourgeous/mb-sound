module MB
  module Sound
    module GraphNode
      # A CEM3379-style 4-pole resonant filter node (see
      # MB::Sound::Filter::FourPole for the sound and options), created by
      # GraphNode#lp4 (aliases #four_pole, #lowpass4) or
      # `filter(:lp4, cutoff:, resonance:)`.
      #
      # The cutoff (Hz) and resonance (0..1) are numbers or graph nodes read
      # per sample, so envelopes, LFOs, and audio-rate filter FM all work.
      # A Pitch (`800.hz`, `C5`) as the cutoff gives its frequency.  Nodes
      # that end keep their last value.
      class FourPole
        include GraphNode
        include SampleRateHelper

        # The MB::Sound::Filter::FourPole holding the state and options.
        attr_reader :filter

        # The cutoff and resonance: numbers or graph nodes.
        attr_reader :cutoff, :resonance

        # Filters +source+ with +filter+ (a MB::Sound::Filter::FourPole),
        # whose cutoff and resonance are set by +cutoff+ and +resonance+.
        def initialize(source, filter, cutoff:, resonance: 0.0)
          raise ArgumentError, "Filter must be a MB::Sound::Filter::FourPole (got #{filter.class})" unless filter.is_a?(MB::Sound::Filter::FourPole)

          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          @filter = filter
          @filter.sample_rate = @sample_rate if @filter.sample_rate != @sample_rate

          @cutoff = self.class.param(cutoff, 'Cutoff', pitch: true)
          @resonance = self.class.param(resonance, 'Resonance')
          [@cutoff, @resonance].each { |p| check_rate(p) }

          @filter.cutoff = @cutoff if @cutoff.is_a?(Numeric)
          @filter.resonance = @resonance if @resonance.is_a?(Numeric)

          @last = {}
          @buf = nil
          @node_type_name = filter.mode.to_s
        end

        # A parameter as a Float or a graph node's sampler branch.  With
        # +pitch+, a Pitch gives its frequency (a constant, or a node that
        # follows the tuning for Notes).
        def self.param(value, name, pitch: false)
          if pitch && value.is_a?(MB::Sound::Pitch) && !value.is_a?(MB::Sound::Tone)
            value = value.constant? ? value.frequency : value.freq
          end

          return value.to_f if value.is_a?(Numeric)
          raise ArgumentError, "#{name} must be a number or graph node (got #{value.inspect})" unless value.respond_to?(:sample) && !value.is_a?(Array)

          value.get_sampler
        end

        # A resonance (a number, or a node from +quality+'s node) giving the
        # gain at the cutoff of a 2-pole filter of quality +quality+ (a
        # number or node such as Notes#quality; see
        # Filter::FourPole.quality_to_resonance).
        def self.quality_resonance(quality, curve = :db)
          return MB::Sound::Filter::FourPole.quality_to_resonance(quality, curve: curve) if quality.is_a?(Numeric)
          raise ArgumentError, "Quality must be a number or graph node (got #{quality.inspect})" unless quality.respond_to?(:sample)

          quality.proc(type_name: 'Q to resonance') { |q| MB::Sound::Filter::FourPole.quality_to_resonance(q, curve: curve) }
        end

        def sources
          { input: @source, cutoff: @cutoff, resonance: @resonance }.select { |_, v| v.respond_to?(:sample) }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil? || data.empty?

          count = data.length
          data = data.real if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          cutoff = read(:cutoff, @cutoff, count)
          resonance = read(:resonance, @resonance, count)

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf[0..] = data # a copy, so shared (frozen) inputs are never written
          @filter.dynamic_process(@buf.inplace!, cutoff: cutoff, resonance: resonance).not_inplace!
        end

        # Sets the filter state as if +value+ had been the input for a long
        # time (see MB::Sound::Filter::FourPole#reset).
        def reset(value = 0)
          @filter.reset(value)
          self
        end

        # Changes the sample rate of this node, its sources, and the filter.
        def sample_rate=(new_rate)
          super
          @filter.sample_rate = @sample_rate
          self
        end
        alias at_rate sample_rate=

        def to_s
          "#{super} -- #{@filter}"
        end

        private

        # A parameter's value for this buffer: a number, or the node's
        # buffer fitted to +count+ (padded with its last value; a node that
        # ended keeps its last value).
        def read(key, value, count)
          return value if value.is_a?(Numeric)

          data = value.sample(count)
          return @last.fetch(key) { key == :cutoff ? @filter.cutoff : @filter.resonance } if data.nil? || data.empty?

          data = data.real if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
          @last[key] = data[-1].to_f

          if data.length > count
            data = data[0...count]
          elsif data.length < count
            padded = Numo::SFloat.new(count).fill(@last[key])
            padded[0...data.length] = data
            data = padded
          end

          data
        end
      end
    end
  end
end
