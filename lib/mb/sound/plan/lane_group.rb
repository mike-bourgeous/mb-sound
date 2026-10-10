module MB
  module Sound
    module Plan
      # Regions with the same program shape run together: a LaneGroup holds
      # regions whose programs lower to the same words (Program#signature:
      # the same ops, registers, and scalar layout; scalars and objects, the
      # nodes and states they run on, may differ), e.g. the same region in
      # every lane (voice and spare) of a Synth.  When any member is sampled
      # and the group hasn't run for this block, the group runs every member:
      # each member's Ruby side as usual (Region#prepare: fallbacks, boundary
      # inputs, feeds), then one call of FastPlan.run_lanes for all of them,
      # whose recursions (SVF filters, ...) run lane-major (every lane's
      # sample k before any lane's k + 1, so the lanes' independent
      # recursions fill the pipeline), then each member's Region#finish
      # (check mode).  Each member gets exactly what running alone gives it.
      #
      # Every member is computed every block (user decision 2026-10-10:
      # compute all voices, so the cost is the same whatever is playing; a
      # Synth doesn't skip idle lanes whose regions are grouped).
      #
      # Members that can't run with the others in a block (a fallback, a
      # rebuild, a shorter input, a program recompiled to another shape)
      # run alone; members sampled while the group is gathering (a member
      # reading another member's output) run as soon as they're asked for.
      #
      # The Ruby engine (Plan.engine :ruby) runs each member's mirror.
      class LaneGroup
        # The member regions, in lane order.
        attr_reader :members

        # Blocks the group ran (for specs and stats), and lanes run together
        # in them.
        attr_reader :runs, :lane_runs

        def initialize(members)
          raise ArgumentError, 'A lane group needs at least two regions' if members.length < 2

          @members = members.freeze
          @index = members.each_with_index.to_h.compare_by_identity
          @status = Array.new(members.length) # nil, :ready, :done
          @n = Array.new(members.length)
          @results = Array.new(members.length)
          @delivered = Array.new(members.length, true)
          @count = nil
          @running = false
          @dissolved = false
          @runs = 0
          @lane_runs = 0
          @scratch = nil
          @lists = Array.new(5) { [] }
          @ready = []
          members.each { |r| r.lane_group = self }
        end

        # Stops grouping: every member runs alone from now on.
        def dissolve
          @dissolved = true
          @members.each { |r| r.lane_group = nil if r.lane_group.equal?(self) }
        end

        # True after #dissolve.
        def dissolved?
          @dissolved
        end

        # The output of +region+ (a member) for a +count+-sample block,
        # running the group first if the block is new (see the class
        # description).
        def sample(region, count)
          idx = @index[region]
          return region.sample_alone(count) if idx.nil?

          if @running
            return sample_during_run(region, idx, count)
          end

          if @delivered[idx] || @count != count
            if @members.any? { |r| !current?(r) }
              # A member's installation rebuilt (its region was replaced):
              # every member runs alone until the owner regroups (see
              # LaneGroups#check)
              dissolve
              return region.sample_alone(count)
            end

            run(count)
          end

          @delivered[idx] = true
          @results[idx]
        end

        def to_s
          "Lane group of #{@members.length} regions (#{Plan.node_label(@members[0].root)}, ...)"
        end

        private

        # A member asked for while the group is gathering (an input of
        # another member): runs it now.
        def sample_during_run(region, idx, count)
          case @status[idx]
          when :ready
            @status[idx] = :done
            @results[idx] = region.finish(@n[idx], count)
          when nil
            @status[idx] = :done
            @results[idx] = region.sample_alone(count)
          end
          @delivered[idx] = true
          @results[idx]
        end

        # Runs every member for a +count+-sample block.
        def run(count)
          members = @members
          @running = true
          @count = count
          @runs += 1
          ready = @ready
          ready.clear
          begin
            members.each_index do |i|
              @status[i] = nil
              @delivered[i] = false
            end

            members.each_with_index do |r, i|
              next if @status[i] # run already (asked for during the run)

              n = r.prepare(count)
              next if @status[i] # asked for while preparing (inside it)

              if n == :done
                @status[i] = :done
                @results[i] = r.result
              else
                @status[i] = :ready
                @n[i] = n
              end
            end

            members.each_with_index { |r, i| ready << i if @status[i] == :ready }
            execute(ready, count) unless ready.empty?
          ensure
            @running = false
          end
        end

        # True if +region+ is still its root's installed region.
        def current?(region)
          region.root.instance_variable_get(:@plan_region).equal?(region) && !region.installation.stale?
        end

        # Runs the ready members (indices +ready+): those with full blocks
        # and the leader's program shape together, the rest alone.
        def execute(ready, count)
          lead = nil
          together = []
          ready.each do |i|
            r = @members[i]
            if @n[i] == count && r.program && r.installation.engine == :c
              lead ||= r.program.signature
              if r.program.signature == lead
                together << i
                next
              end
            end
            @status[i] = :done
            @results[i] = r.finish(@n[i], count)
          end
          return if together.empty?

          if together.length == 1
            i = together[0]
            @status[i] = :done
            @results[i] = @members[i].finish(@n[i], count)
            return
          end

          run_lanes(together, count)
          together.each do |i|
            r = @members[i]
            @status[i] = :done
            @results[i] = r.finish(count, count, r.out_view(count))
          end
          @lane_runs += together.length
        end

        # One FastPlan.run_lanes call for members +lanes+ (indices).
        def run_lanes(lanes, count)
          scalars, objects, inputs, params, outs = @lists
          @lists.each(&:clear)
          words = nil
          nslots = 0
          lanes.each do |i|
            r = @members[i]
            w, sc, objs, ns = r.program.lower
            words ||= w
            nslots = ns
            ins, pars = r.run_arguments
            scalars << sc
            objects << objs
            inputs << ins
            params << pars
            outs << r.out_view(count)
          end

          stride = 2 * count
          need = [nslots * stride * lanes.length, 1].max
          if @scratch.nil? || @scratch.length < need
            @scratch = Numo::SFloat.zeros(need)
          end
          # The C side divides the scratch evenly among the lanes
          scratch = @scratch.length == need ? @scratch : (@scratch_views ||= {})[need] ||= @scratch[0...need]
          MB::Sound::FastPlan.run_lanes(words, scalars, objects, inputs, params, scratch, outs, count)
        end
      end

      # Finds and keeps the LaneGroups of a set of installations (a Synth's
      # lanes): regions of different installations with the same program
      # signature (in the same order within each installation) are grouped.
      # #check regroups after any installation rebuilt or a region stopped
      # planning.
      class LaneGroups
        # The current groups.
        attr_reader :groups

        # +installations+: the lanes' Installations (nil entries for lanes
        # without plans).
        def initialize(installations)
          @all = installations
          @installations = installations.compact
          @groups = []
          @generations = nil
          refresh
        end

        # Regroups if an installation changed since the last grouping.
        # Returns true if it regrouped.
        def check
          return false unless @installations.any?(&:stale?) || generations_changed? || @groups.any?(&:dissolved?)

          refresh
          true
        end

        # The indices of the installations given to the constructor (nil
        # entries counted) with at least one grouped region.
        def grouped_lanes
          @all.each_index.select { |i| @all[i] && @groups.any? { |g| g.members.any? { |r| r.installation.equal?(@all[i]) } } }
        end

        # Dissolves every group and groups the current regions again.
        def refresh
          @groups.each(&:dissolve)
          @groups = []

          buckets = Hash.new { |h, k| h[k] = [] }
          @installations.each do |inst|
            inst.rebuild if inst.stale?
            seen = Hash.new(0)
            inst.regions.each do |r|
              next if r.disabled

              prog = r.program || r.precompile
              next unless prog

              key = [prog.signature, prog.output_type]
              occurrence = seen[key]
              seen[key] += 1
              buckets[[key, occurrence]] << r
            end
          end

          buckets.each_value do |regions|
            next if regions.length < 2

            @groups << LaneGroup.new(regions)
          end

          @generations = @installations.map(&:generation)
          self
        end

        private

        def generations_changed?
          return true if @generations.nil?

          i = 0
          while i < @installations.length
            return true unless @installations[i].generation == @generations[i]
            i += 1
          end
          false
        end
      end
    end
  end
end
