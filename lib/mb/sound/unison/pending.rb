module MB
  module Sound
    module Unison
      # Oscillator methods for a unison given without a block (see
      # Pitch#unison): each makes the unison of that oscillator on every
      # copy, the same as the block form with the same seed, so
      # `110.hz.unison(5).saw` is `110.hz.unison(5) { |p| p.saw }` and
      # `v.hz.unison(7, spread: 1).square.pwm(0.3).at(0.5)` is
      # `v.hz.unison(7, spread: 1) { |p| p.square.pwm(0.3).at(0.5) }` (bit
      # for bit).  The calls chain (each returns a new pending unison with
      # the call added) until the unison is used as a signal; then it is
      # built once with the whole chain.
      module Shapes
        # The wave shapes (Pitch's), each a unison of that shape.
        WAVES = [
          :sine, :sin, :triangle, :square, :ramp, :saw, :sawtooth, :drumramp, :envramp, :gauss, :parabola,
          :atriangle, :asquare, :aramp, :asaw, :asawtooth,
          :complex_sine, :complex_square, :complex_triangle, :complex_ramp, :complex_saw,
          :acomplex_square, :acomplex_triangle, :acomplex_ramp, :acomplex_saw,
        ].freeze

        # Pitch's other oscillator shortcuts and Tone settings, each added
        # to every copy's oscillator.
        OSCILLATORS = [
          :pulse, :apulse, :pwm, :skew, :fm, :log_fm, :pm, :fm_feedback, :fm_fb, :fmfb, :sync, :softsync,
          :with_phase, :reset, :free, :random_phase, :rnd, :noise, :wavetable, :harmonics, :additive,
        ].freeze

        # The methods are defined on each including class itself (as its
        # own methods), so the recipe recorder wraps them like the DSL
        # surface of Pitch and Tone (see GraphNode::Recipe::Surface): a
        # graph prints as it was written, `110.hz.unison(5).saw`.
        def self.included(klass)
          (WAVES + OSCILLATORS).each do |name|
            # Tone's aliases stay aliases (ramp is saw), so recipes print
            # the official name (Recipe.official_name)
            official = Tone.method_defined?(name) ? Tone.instance_method(name).original_name : name
            if official != name && (WAVES + OSCILLATORS).include?(official)
              next # (aliased below, after the official one is defined)
            end
            klass.define_method(name) do |*args, **kwargs, &block|
              @pending.then_call(name, args, kwargs, block)
            end
          end
          (WAVES + OSCILLATORS).each do |name|
            official = Tone.method_defined?(name) ? Tone.instance_method(name).original_name : name
            klass.send(:alias_method, name, official) if official != name && (WAVES + OSCILLATORS).include?(official)
          end

          # After an oscillator method: the copies' level (Tone#at, so the
          # unison matches the block form bit for bit).  Without one: the
          # level of the unison of saws (GraphNode#at).
          klass.define_method(:at) do |amplitude|
            return super(amplitude) if @pending.chain.empty?
            @pending.then_call(:at, [amplitude], {}, nil)
          end

          # After an oscillator method: the copies' Tone#gain.  Without
          # one: the gain of the unison of saws.
          klass.define_method(:gain) do |gain|
            return super(gain) if @pending.chain.empty?
            @pending.then_call(:gain, [gain], {}, nil)
          end
        end

        # The pitch the unison was made from.
        def unison_pitch
          @pending.pitch
        end
      end

      # What a blockless Pitch#unison was given, built on first use (see
      # Pitch#unison): saws (no +chain+), or the oscillator calls of
      # Shapes in +chain+ on every copy.  Nothing is built for a pending
      # unison that only leads to another (`unison(5).square` before
      # `.pwm(0.3)`), so no copy holds graph branches of a Notes pitch's
      # nodes that nothing reads.
      class Spec
        attr_reader :pitch, :count, :seed, :options, :chain

        # +seed+ is drawn when the unison is asked for (+drawn+ true), as
        # the block form draws it, or given.
        def initialize(pitch, count, seed:, drawn:, options:, chain: [])
          @pitch = pitch
          @count = count
          @seed = seed
          @drawn = drawn
          @options = options.freeze
          @chain = chain.freeze
          @built = nil
          @owner = nil
        end

        # The Pending or PendingChannels standing for this unison (see
        # #built).
        attr_writer :owner

        # True for a stereo unison (a spread above 0, or a spread node).
        def stereo?
          s = @options[:spread]
          s.respond_to?(:sample) || s > 0
        end

        # A new pending unison with oscillator call +name+ added to the
        # chain.
        def then_call(name, args, kwargs, block)
          spec = Spec.new(@pitch, @count, seed: @seed, drawn: @drawn, options: @options, chain: @chain + [[name, args, kwargs, block]])
          spec.stereo? ? PendingChannels.new(spec) : Pending.new(spec)
        end

        # The unison, built once: saws without a chain, else the chain's
        # oscillator on each copy (the block form's samples).  The calls
        # made building it aren't recorded: the built unison takes the
        # recipe of the stand-in that made it (`110.hz.unison(5).saw`).
        def built
          @built ||= GraphNode::Recipe.quietly {
            if @chain.empty?
              Unison.build(@pitch, @count, seed: @seed, **@options)
            else
              chain = @chain
              Unison.build(@pitch, @count, seed: @seed, **@options) { |p, _|
                chain.reduce(p) { |o, (name, args, kwargs, block)| o.public_send(name, *args, **kwargs, &block) }
              }
            end
          }.tap { |b| GraphNode::Recipe.share_record(@owner, b) if @owner }
        end
      end

      # A mono unison given without a block (Pitch#unison with no
      # +spread:+): plays as saws when used as a signal (built on first
      # use), and its Shapes methods make the unison of another oscillator.
      # Consumers get the built unison itself from #get_sampler, so this
      # node never stays in a graph.
      class Pending
        include GraphNode
        include Shapes
        node_traits memory: :short

        def initialize(spec)
          @pending = spec
          spec.owner = self
          @node_type_name = 'Unison'
        end

        def sample(count)
          @pending.built.sample(count)
        end

        def get_sampler
          @pending.built.get_sampler
        end

        # The built unison's output (so graph walks see the mixer).
        def outputs
          @pending.built.outputs
        end

        def sources
          { unison: @pending.built }
        end

        def sample_rate
          @pending.pitch.sample_rate
        end
      end

      # One channel of a stereo PendingChannels (built on first use).
      class PendingChannel
        include GraphNode
        node_traits memory: :short

        def initialize(spec, index)
          @pending = spec
          @index = index
          @node_type_name = "Unison #{index == 0 ? 'left' : 'right'}"
        end

        def sample(count)
          channel.sample(count)
        end

        def get_sampler
          channel.get_sampler
        end

        # The built channel's sources (so graph walks see the mixer).
        def sources
          channel.sources
        end

        def sample_rate
          @pending.pitch.sample_rate
        end

        private

        def channel
          @pending.built.outputs[@index]
        end
      end

      # A stereo unison given without a block (Pitch#unison with a
      # +spread:+): a Channels bundle of saws when used as a signal (built
      # on first use), whose Shapes methods make the unison of another
      # oscillator.
      class PendingChannels < GraphNode::Channels
        include Shapes
        node_traits memory: :none

        def initialize(spec)
          @pending = spec
          spec.owner = self
          super([PendingChannel.new(spec, 0), PendingChannel.new(spec, 1)])
        end
      end

      # Tone#unison (and Notes::KeyedTone's): the tone made again on each
      # copy of a unison of the pitch it was made from, from its recipe
      # (the call that made it and the calls that configured it since;
      # see GraphNode::Recipe), so `v.hz.saw.at(0.5).unison(5)` is
      # `v.hz.unison(5) { |p| p.saw.at(0.5) }`.
      module ToneMethods
        # Returns a unison of +count+ copies of this tone (see Pitch#unison
        # for the options), each copy made the way this tone was, on a
        # detuned copy of the pitch it was made from.  Bit for bit the
        # block form, also for a tone that drew one seed (`.rnd`, or
        # `.noise` without a seed:, whose draw becomes the unison's seed, as
        # the block form draws it there); a tone that drew several seeds
        # draws a new one.  Tones not made from a Pitch's oscillator methods
        # (or built with recipes off, MB_SOUND_RECIPES=0) can't be copied:
        # write the block form.
        #
        #     play 110.hz.saw.unison(7, detune: 25.cents)                 # a supersaw
        #     midi.synth(voices: 4) { |v| v.hz.square.pwm(0.3).unison(5, spread: 1) * v.amp_env }
        def unison(count = nil, seed: nil, **options)
          rec = GraphNode::Recipe.record_of(self)
          call = rec&.call
          unless call && call.receiver.is_a?(MB::Sound::Pitch) && rebuildable?(call)
            why = GraphNode::Recipe.enabled? ? "this tone wasn't made by a Pitch's oscillator method#{call ? " (it came from #{call.name})" : ''}" : 'recipes are off (MB_SOUND_RECIPES=0)'
            return MB::Sound.live_error(ArgumentError.new(
              "Can't make a unison of #{self}: #{why}; write the block form, e.g. pitch.unison(#{count || DEFAULT_COUNT}) { |p| p.saw }"
            ))
          end

          configs = rec.config || []
          drawn = ([call] + configs).flat_map { |c| c.seeds || [] }
          base = call.receiver
          rebuild = ->(p) {
            configs.reduce(p.public_send(call.name, *call.args, **call.kwargs, &call.block)) { |tone, c|
              tone.public_send(c.name, *c.args, **c.kwargs, &c.block)
            }
          }

          if seed.nil? && drawn.length == 1
            # The tone's one draw is the unison's seed: the root generator
            # moved once, as the block form moves it
            base.unison(count, seed: drawn[0], **options) { |p| rebuild.(p) }
          elsif seed
            base.unison(count, seed: seed, **options) { |p| rebuild.(p) }
          else
            base.unison(count, **options) { |p| rebuild.(p) }
          end
        end

        private

        # True if the call that made this tone can make it again on a copy.
        def rebuildable?(call)
          name = call.name
          Shapes::WAVES.include?(name) || Shapes::OSCILLATORS.include?(name) || name == :tone || name == :hz
        end
      end
    end
  end
end

MB::Sound::Tone.include(MB::Sound::Unison::ToneMethods)
