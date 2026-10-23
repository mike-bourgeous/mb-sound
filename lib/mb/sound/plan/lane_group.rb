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
        # The most members FastPlan.run_lanes takes (MB_PLAN_MAX_LANES in
        # fast_plan.c); larger buckets are split into groups of at most this
        # many (before synth-sublanes-1, a bucket of more regions raised
        # "Plan lanes must number 1 to 64": e.g. a 5-layer stereo SF2 preset
        # in an 8-lane synth gave 80 same-shape regions).
        MAX_LANES = 64

        # The member regions, in lane order.
        attr_reader :members

        # Blocks the group ran (for specs and stats), and lanes run together
        # in them.
        attr_reader :runs, :lane_runs

        def initialize(members)
          raise ArgumentError, 'A lane group needs at least two regions' if members.length < 2

          @members = members.freeze
          @index = members.each_with_index.to_h.compare_by_identity
          @status = Array.new(members.length) # nil, :ready, :done, :gone (replaced), :replacing
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

          sample_gone(region, idx, count) if @status[idx] == :gone
          @delivered[idx] = true
          @results[idx]
        end

        def to_s
          "Lane group of #{@members.length} regions (#{Plan.node_label(@members[0].root)}, ...)"
        end

        # What #take_handoff returns when there is no block to hand off.
        NO_HANDOFF = Object.new.freeze

        # Called by Installation#uninstall for member +region+, about to be
        # replaced by a rebuild: if the group ran (or is running) the
        # member's block and its owner hasn't read it yet, the next read of
        # the member's root takes that block (see #take_handoff,
        # Planned#sample, Region#prepare) instead of computing it again.
        # A rebuild in the middle of a group run (a member's fallback
        # reading another region of its installation, whose stale check
        # rebuilds it) otherwise moved the root's hook to a new region
        # after the group had computed the block, so the owner's read
        # computed it a second time, advancing noise and free-running
        # states twice (fixes-8: a lane's `band * 0.5` left unread made
        # its band a separate region).
        def hand_off(region)
          idx = @index[region]
          return if idx.nil? || (!@running && @delivered[idx])

          region.root.instance_variable_set(:@plan_handoff, [self, region])
        end

        # The block of replaced member +region+ for a +count+-sample read
        # (see #hand_off), or NO_HANDOFF if the group has none waiting for
        # it.
        def take_handoff(region, count)
          idx = @index[region]
          return NO_HANDOFF if idx.nil? || @delivered[idx] || @count != count

          case @status[idx]
          when :done
            @delivered[idx] = true
            @results[idx]
          when :ready
            @running ? sample_during_run(region, idx, count) : NO_HANDOFF
          else
            NO_HANDOFF
          end
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
          when :gone
            sample_gone(region, idx, count)
          end
          @delivered[idx] = true
          @results[idx]
        end

        # The block of member +idx+ (+region+), replaced during this run (see
        # #run): rebuilds its installation if that hasn't happened yet, then
        # reads its root, whose hooks now lead to the new regions (or to its
        # own #sample).  Returning nil here would end the member's graph
        # (a stereo Synth lane whose envelope stream ended stopped for good,
        # its envelope never going idle; fixes-6).
        def sample_gone(region, idx, count)
          # Not :done until the block is computed, so the rebuild doesn't
          # hand the stale result over (see #hand_off)
          @status[idx] = :replacing
          inst = region.installation
          inst.rebuild if inst.stale?
          @results[idx] = region.installed? ? region.sample_alone(count) : region.root_sample(count)
          @status[idx] = :done
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
                # installation rebuilt or went stale, e.g. a feeder's
                # stream ended): its nodes belong to new regions now, and
                # its block comes from them when it's asked for (see
                # #sample_gone)
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
            taps = r.program.taps
            taps.each { |t| t.reserve(count) } unless taps.empty?
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
          listed = [] # [installation, region, program]
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

              listed << [inst, r, prog]
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

            regions.each_slice(LaneGroup::MAX_LANES) { |part| @groups << LaneGroup.new(part) if part.length > 1 }
          end

          # Regions left alone may differ from others only by gains (x vs
          # x * c): their cores (ScaleMatch) share a bucket, and they are
          # padded to one shape (only these are looked at, so a Synth's
          # identical lanes cost nothing more)
          alone = buckets.each_value.select { |regions| regions.length == 1 }.map(&:first).to_h { |r| [r, true] }.compare_by_identity
          unless alone.length < 2
            loose = Hash.new { |h, k| h[k] = [] }
            cores = {}.compare_by_identity
            seen = {}.compare_by_identity
            listed.each do |inst, r, prog|
              next unless alone.key?(r)

              key, sites = ScaleMatch.core(prog)
              cores[r] = [key, sites]
              shape = [key, prog.output_type]
              if inst.resamples?
                counts = (seen[inst] ||= Hash.new(0))
                k = shape + [counts[shape]]
                counts[shape] += 1
                shape = k
              end
              loose[shape] << r
            end

            loose.each_value do |regions|
              next if regions.length < 2

              pad_to_shape(regions, cores)
              regions.group_by { |r| r.program&.signature }.each do |sig, same|
                next if sig.nil? || same.length < 2

                same.each_slice(LaneGroup::MAX_LANES) { |part| @groups << LaneGroup.new(part) if part.length > 1 }
              end
            end
          end

          @generations = @installations.map(&:generation)
          self
        end

        private

        # Pads the programs of +regions+ (whose cores match; see
        # ScaleMatch) with `x * 1` where others have gains, so they lower to
        # the same words.  Each region's own sites count its earlier pads
        # too, so padding again is stable; if the padded signatures still
        # differ, the pads are removed again.
        def pad_to_shape(regions, cores)
          sigs = regions.map { |r| r.program.signature }
          return if sigs.uniq.length == 1

          own = regions.to_h { |r| [r, own_sites(r, cores[r][1])] }.compare_by_identity
          target = Hash.new(0)
          own.each_value { |s| s.each { |k, n| target[k] = n if n > target[k] } }
          regions.each do |r|
            pads = target.to_h { |k, n| [k, n - own[r][k]] }.reject { |_, n| n <= 0 }
            r.pad!(pads)
          end

          return if regions.map { |r| r.program&.signature }.compact.uniq.length == 1

          regions.each { |r| r.pad!(nil) }
        end

        # The gain sites of region +r+'s program without its own pads (the
        # program's sites count them).
        def own_sites(r, sites)
          s = Hash.new(0)
          sites.each { |k, n| s[k] = n - (r.pads&.[](k) || 0) }
          s
        end

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
