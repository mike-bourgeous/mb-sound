module MB
  module Sound
    module Sequence
      # Names for clips and kits (like GraphNode#named for nodes), shown in
      # Set listings (`scenes`, `tracks`, `players`) and printed by
      # graph-io's #to_ruby:
      #
      #     bass_a = seq(A1, A1, Rest, A2).n8.loop.named(:bass_a)
      #     beat = grid(16, kick: 'x...x...x...x...').loop.named(:beat)
      #
      # A name belongs to the object it was given to: a clip made from a
      # named one (`bass_a.transpose(12)`, `.loop`) has no name until it
      # gets its own, so name a clip after its last transform.
      module Named
        # Gives this clip or kit a +name+ (a Symbol or String, kept as a
        # Symbol; nil removes it).  Returns self.
        def named(name)
          raise ArgumentError, "Clip names are Symbols or Strings (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol) || name.is_a?(String)
          @name = name&.to_sym
          self
        end

        # The name given with #named, or nil.
        def name
          @name ||= nil
        end

        # True if this clip or kit has a name.
        def named?
          !name.nil?
        end
      end
    end
  end
end
