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
            if !@members.all? { |r| current?(r) }
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
          if count != @count && @status[idx] == :ready
            # (LaneGroups doesn't group regions that may run at different
            # counts; see #refresh)
            raise "#{self}: a member read for #{count} samples was gathered for #{@count}"
          end

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
          status = @status
          @running = true
          @count = count
          @runs += 1
          ready = @ready
          ready.clear
          begin
            i = 0
            while i < members.length
              status[i] = nil
              @delivered[i] = false
              # Write this block's outputs into each member's other buffer
              # (see Region#swap_out!)
              members[i].swap_out!
              i += 1
            end

            i = 0
            while i < members.length
              r = members[i]
              if !status[i] && !current?(r)
                # Replaced by a rebuild during this run (another member's
                # installation rebuilt): its nodes belong to new regions now
                status[i] = :gone
                @results[i] = nil
              end
              unless status[i] # run already (asked for during the run)
                n = r.prepare(count)
                unless status[i] # asked for while preparing (inside it)
                  if n.is_a?(Integer)
                    status[i] = :ready
                    @n[i] = n
                    ready << i
                  else
                    status[i] = :done
                    @results[i] = r.result
                  end
                end
              end
              i += 1
            end

            # Members finished early (asked for during the run) are done
            ready.select! { |k| status[k] == :ready }
            execute(ready, count) unless ready.empty?
          ensure
            @running = false
          end
        end

        # True if +region+ is still its root's installed region.
        def current?(region)
          region.installed? && !region.installation.stale?
        end

        # Runs the ready members (indices +ready+): those with full blocks
        # and the leader's program shape together, the rest alone.
        def execute(ready, count)
          together = (@together ||= [])
          together.clear
          lead = nil
          k = 0
          while k < ready.length
            i = ready[k]
            k += 1
            r = @members[i]
            prog = r.program
            if @n[i] == count && prog && r.installation.engine == :c
              sig = prog.signature
              lead ||= sig
              if sig.equal?(lead) || sig == lead
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
          k = 0
          while k < together.length
            i = together[k]
            r = @members[i]
            @status[i] = :done
            @results[i] = r.finish(count, count, r.out_view(count))
            k += 1
          end
          @lane_runs += together.length
        end

        # One FastPlan.run_lanes call for members +lanes+ (indices).
        def run_lanes(lanes, count)
          scalars, objects, inputs, params, outs = @lists
          @lists.each(&:clear)
          words = nil
          nslots = 0
          k = 0
          while k < lanes.length
            r = @members[lanes[k]]
            low = r.program.lower
            words ||= low[0]
            nslots = low[3]
            scalars << low[1]
            objects << low[2]
            inputs << r.inputs
            params << r.params
            outs << r.out_view(count)
            k += 1
          end

          stride = 2 * count
          need = nslots * stride * lanes.length
          need = 1 if need < 1
          if @scratch.nil? || @scratch.length < need
            @scratch = Numo::SFloat.zeros(need)
            @scratch_views = {}
          end
          # The C side divides the scratch evenly among the lanes
          scratch = @scratch.length == need ? @scratch : (@scratch_views[need] ||= @scratch[0...need])
          MB::Sound::FastPlan.run_lanes(words, scalars, objects, inputs, params, scratch, outs, count)
        end
      end

      # Finds and keeps the LaneGroups of a set of installations (a Synth's
      # lanes, or one installation, e.g. a Session player's): every region
      # with the same program signature and output type is in one group,
      # across installations (a Synth's voices and spares, and each voice's
      # channels) and, for one installation, among the regions computing its
      # outputs (e.g. the left and right channels of a stereo patch; see
      # +roots_only+).  In installations with resamplers (whose regions may
      # run at different sample counts, inside and outside an oversampler)
      # only the n-th region of a shape of each installation share a group.
      # #check regroups after any installation rebuilt or a region stopped
      # planning.
      class LaneGroups
        # The current groups.
        attr_reader :groups

        # +installations+: the lanes' Installations (nil entries for lanes
        # without plans).  With +roots_only+ (Plan.install's grouping inside
        # one installation) only regions computing an output of their
        # installation are grouped: inside a graph, nodes like a drum
        # voice push buffers to their subgraphs (Drums::Voice::Tap) or skip
        # them while idle, so computing another region before its owner
        # asks for it isn't safe; an installation's outputs are read by its
        # owner (a Session) every block.
        def initialize(installations, roots_only: false)
          @all = installations
          @roots_only = roots_only
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
            inst.rebuild(regroup: false) if inst.stale?
            # Regions of an installation with resamplers may run at different
            # sample counts (inside and outside an oversampler), so there
            # only the n-th region of one shape in each installation group
            # (a Synth's lanes have the same graph: the same counts)
            seen = inst.resamples? ? Hash.new(0) : nil
            outputs = @roots_only ? inst.roots.map { |o| Plan.origin(o) } : nil
            inst.regions.each do |r|
              next if r.disabled
              next if outputs && outputs.none? { |o| o.equal?(r.root) }

              prog = r.program || r.precompile
              next unless prog

              shape = [prog.signature, prog.output_type]
              key = shape
              if seen
                key = shape + [seen[shape]]
                seen[shape] += 1
              end
              buckets[key] << r
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
