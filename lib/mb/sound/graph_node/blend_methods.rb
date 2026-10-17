module MB
  module Sound
    module GraphNode
      # Mixing an effect in (ux-1 round 2; maintainer: "help :wet and help
      # :dry didn't tell me how to mix .resonate in"): `sig.blend(0.3) { |s|
      # s.reverb(:hall, mix: 1) }`.  Included in GraphNode and Channels
      # (bundles hand the whole bundle to the block, so stereo effects stay
      # stereo).
      module BlendMethods
        # Crossfade laws #blend takes.
        CURVES = %i[linear power].freeze

        # Mixes the effect the block builds from this node with the node
        # itself: +mix+ 0 is all dry, 1 all wet.  +mix+ is a number, a knob's
        # name (a Symbol: `knob(:wet)` read per sample), or any node.
        #
        # +curve:+ :linear (default, the same law as the effects' own `mix:`
        # options: dry * (1 - mix) + wet * mix, which keeps the level of
        # correlated signals) or :power (equal power: dry * sqrt(1 - mix) +
        # wet * sqrt(mix), which keeps the loudness of uncorrelated ones,
        # like reverb tails).  +compensate:+ true (default) delays the dry
        # path by the effect's reported latency (lookahead dynamics and
        # limiters: GraphNode#latency on the effect's own nodes, summed as
        # for a chain), so the two line up; other effects report none.
        #
        #     drums.blend(0.4) { |s| s.resonate(:plate, 0.25.hz.lfo.at(110..440), decay: 1.5).at(-22.db) }
        #     keys.blend(:wet) { |s| s.chorus(:juno2, mix: 1) }
        #     stereo(l, r).blend(0.25, curve: :power) { |s| s.reverb(:hall, mix: 1) }
        def blend(mix = 0.5, curve: :linear, compensate: true, &block)
          raise ArgumentError, 'blend needs a block making the effect: sig.blend(0.3) { |s| s.reverb(:hall, mix: 1) }' unless block
          raise ArgumentError, "blend curve: is #{CURVES.map(&:inspect).join(' or ')} (got #{curve.inspect})" unless CURVES.include?(curve)

          amount = BlendMethods.amount(mix)
          wet = block.call(self)
          raise ArgumentError, "blend's block must return the effect (a graph node; got #{wet.class})" unless wet.respond_to?(:sample) || wet.is_a?(Channels)

          lag = compensate ? BlendMethods.latency_of(wet, self) : 0
          dry = lag > 0 ? delay(lag.samples) : self
          dry_gain, wet_gain = BlendMethods.gains(amount, curve)
          dry * dry_gain + wet * wet_gain
        end

        # +mix+ as a number in 0..1 or a node.
        def self.amount(mix)
          case mix
          when Numeric
            raise ArgumentError, "blend's mix is 0..1 (0 dry, 1 wet; got #{mix})" unless mix.real? && (0..1).cover?(mix)
            mix.to_f
          when Symbol then MB::Sound.knob(mix)
          else
            raise ArgumentError, "blend's mix is a number, a knob name, or a node (got #{mix.inspect})" unless mix.respond_to?(:sample)
            mix
          end
        end

        # [dry gain, wet gain] for +amount+ (a number or a node).
        def self.gains(amount, curve)
          if amount.is_a?(Numeric)
            return [1 - amount, amount] if curve == :linear
            return [Math.sqrt(1 - amount), Math.sqrt(amount)]
          end
          dry = 1 - amount
          return [dry, amount] if curve == :linear
          [dry.aclip(0, 1) ** 0.5, amount.aclip(0, 1) ** 0.5]
        end

        # Samples of latency the effect +wet+ reports between +dry+ and its
        # output: the latencies of its nodes (outside +dry+'s own graph)
        # that report one, summed (the right total for a chain of them).
        def self.latency_of(wet, dry)
          inside = dry.respond_to?(:graph) ? dry.graph.map(&:__id__).to_set : Set.new
          nodes = wet.respond_to?(:graph) ? wet.graph : []
          # (outputs of multi-output nodes, like Dynamics::Output, stand for their owner)
          owners = nodes.map { |n| o = n.instance_variable_get(:@owner); o.respond_to?(:latency) ? o : n }
          owners.uniq(&:__id__).sum do |n|
            next 0 if inside.include?(n.__id__) || !n.respond_to?(:latency)
            l = n.latency
            l.is_a?(Integer) && l > 0 ? l : 0
          end
        end
      end
    end
  end
end
