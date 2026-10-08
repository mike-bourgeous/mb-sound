module MB
  module Sound
    module Plan
      # The node side of the plan layer (see Plan's description): included
      # by node classes that can describe their per-sample work as ops.
      # Such a class defines #plan_describe(p) (see Builder) and, when they
      # differ from these defaults, #plan_inputs, #plan_boundary_inputs,
      # #plan_unsupported_reason, #plan_snapshot, and #plan_restore.
      #
      # Including it also prepends Planned, the hook that runs a region in
      # place of the node's own #sample when the node is a region's root.
      module Describable
        def self.included(base)
          base.prepend(Planned)
        end

        # The handles (Tee branches) #plan_describe reads, for the region
        # finder.  By default every input in #sources that responds to
        # #sample.
        def plan_inputs
          sources.each_value.select { |v| v.respond_to?(:sample) }
        end

        # The handles among #plan_inputs that must stay boundary inputs
        # (read by the region, never described inside it), e.g. a tone's
        # reset trigger, which may end without ending the tone.
        def plan_boundary_inputs
          []
        end

        # nil if this node's current settings can be described as ops,
        # otherwise a String saying why not.
        def plan_unsupported_reason
          nil
        end

        # The node's per-sample state as plain values, for check mode (nil
        # for stateless nodes).
        def plan_snapshot
          nil
        end

        # Restores state from #plan_snapshot.
        def plan_restore(snapshot)
        end

        # The type of this node's output when a region reads it as a
        # boundary input (:real or :complex); checked every block.
        def plan_output_type
          :real
        end
      end

      # Prepended to describable node classes: a region's root runs the
      # region instead of its own #sample (unless the region is running
      # unfused, for a fallback or a check), and a node inside a region
      # that someone outside the plan reads makes the plan rebuild (see
      # Region#foreign_read).
      module Planned
        def sample(count)
          if (region = @plan_region)
            return region.sample(count) unless region.unfused
          elsif (region = @plan_member) && !region.unfused
            region.foreign_read(self)
          end

          super
        end
      end
    end
  end
end
