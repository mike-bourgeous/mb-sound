module MB
  module Sound
    # Modulation sums: a small mod matrix for synth voices, written as a
    # base value plus { source => amount } pairs, like the SQ-80's two mod
    # slots per destination (any number of slots here).  Extended into
    # MB::Sound (console), and included in Notes, where sources may also be
    # Symbols for the voice's own controls (see Notes#mod_source).
    #
    #     pitch = v.mod_sum(lfo1 => 0.3, env2 => 12.st)               # semitones, for v.hz.transpose
    #     cutoff = v.mod_scale(800, env1 => 3.oct, :key => 0.5, :velocity => 1.oct)
    #     level = v.mod_sum(0.5, :aftertouch => 0.5)
    #
    # Amounts are numbers, Intervals (semitones in #mod_sum, octaves in
    # #mod_scale), or graph nodes (a depth that moves, e.g. `v.mod * 2`).
    # The result is an ordinary graph node (a Mixer, or a Multiplier for
    # #mod_scale), so it can feed any input that takes nodes.
    module ModMethods
      # Returns +base+ (a number or node; default 0) plus the sum of each
      # source × amount (see the module description): a linear destination
      # (levels, semitone offsets, pan, LFO rates).  Interval amounts count
      # in semitones.  Alias #modulation_sum.
      def mod_sum(base = 0.0, mods = {}, **more)
        mod_mixer(base, mods.merge(more), :semitones, 'mod sum')
      end
      alias modulation_sum mod_sum

      # Returns +base+ (a number or node, e.g. a cutoff in Hz) × 2 ** (the
      # sum of each source × amount in octaves): an exponential destination
      # (cutoffs, frequencies, times, rates).  Interval amounts count in
      # octaves (`7.st` is 7/12 of an octave).  Alias #mod_octaves.
      def mod_scale(base, mods = {}, **more)
        exponent = mod_mixer(0.0, mods.merge(more), :octaves, 'mod octaves')
        node = (2.0.constant(sample_rate: mod_rate) ** exponent)
        node = node * base unless base == 1
        node.named('mod scale')
      end
      alias mod_octaves mod_scale

      # The graph node for a modulation source: a node as is, a Numeric as a
      # constant.  Notes overrides this to resolve Symbols.
      def mod_source(source)
        return source if source.respond_to?(:sample)
        return source.to_f.constant(sample_rate: mod_rate) if source.is_a?(Numeric)

        raise ArgumentError, "Modulation sources must be graph nodes (got #{source.inspect}; Symbols need a Notes voice, e.g. v.mod_sum)"
      end

      private

      # A Mixer of +base+ and source × amount pairs, amounts converted from
      # Intervals to +unit+ (:semitones or :octaves).
      def mod_mixer(base, mods, unit, name)
        summands = [[base.is_a?(Numeric) ? base.to_f : base, 1.0]]
        mods.each do |src, amount|
          node = mod_source(src)
          amount = mod_amount(amount, unit)
          summands << (amount.respond_to?(:sample) ? [node * amount, 1.0] : [node, amount])
        end
        MB::Sound::GraphNode::Mixer.new(summands, sample_rate: mod_rate).named(name)
      end

      def mod_amount(amount, unit)
        case amount
        when Interval then unit == :octaves ? amount.to_octaves.to_f : amount.to_semitones.to_f
        when Numeric then amount.to_f
        else
          raise ArgumentError, "Modulation amounts must be numbers, Intervals, or graph nodes (got #{amount.inspect})" unless amount.respond_to?(:sample)
          amount
        end
      end

      # The sample rate of new nodes.
      def mod_rate
        respond_to?(:sample_rate) && sample_rate.is_a?(Numeric) ? sample_rate : 48000
      end
    end
  end
end
