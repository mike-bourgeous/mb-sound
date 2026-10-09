module MB
  module Sound
    module MIDI
      class Transform
        # An unattached chain of stream transforms (like `150.hz.highpass`
        # for audio filters): made by MB::Sound#echo, #arp, #strum, and
        # #chord, extended by the same method names (`echo(1.n8, 3).strum(20.ms)`),
        # and applied to a stream with #apply (Stream#through, Clip#bake).
        #
        #     fx = echo(3.n16, 3, pitch: 7.st, velocity: 0.6).humanize(4.ms)
        #     bg :keys, midi.through(fx).synth { |v| ... }
        #     riff.loop.bake(fx)
        class Spec
          # The chain as [method name, args, kwargs, block] entries.
          attr_reader :steps

          def initialize(steps = [])
            @steps = steps.freeze
          end

          # Returns +stream+ (anything MIDI::Stream.for takes) through every
          # transform of the chain.
          def apply(stream)
            @steps.reduce(Stream.for(stream)) { |s, (name, args, kwargs, block)| s.public_send(name, *args, **kwargs, &block) }
          end
          alias call apply

          Stream::TRANSFORMS.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              Spec.new(@steps + [[name, args.freeze, kwargs.freeze, block].freeze])
            end
          end

          def to_s
            @steps.map { |name, args, kwargs, block|
              parts = args.map(&:to_s) + kwargs.map { |k, v| "#{k}: #{v.inspect}" }
              parts << '&block' if block
              "#{name}(#{parts.join(', ')})"
            }.join('.')
          end

          def inspect
            "#<#{self.class.name} #{self}>"
          end
        end
      end
    end
  end
end
