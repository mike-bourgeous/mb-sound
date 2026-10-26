module MB
  module Sound
    module Plan
      # Plans installed on the graphs feeding some outputs (a Session
      # player's channels, a Synth lane): finds the regions, hooks their
      # nodes, and rebuilds everything after a structural change.
      #
      # The region finder (greedy, consumers first): every node reachable
      # from the outputs is visited in an order where readers come before
      # the nodes they read.  A describable node (Describable, supported
      # settings, not observed, not planned by another installation) joins
      # the region of its readers if all of them are in one region, read it
      # through fusable inputs (#plan_inputs, not #plan_boundary_inputs),
      # and are all the readers it has (every branch of every Tee on it is
      # accounted for); otherwise it starts a region of its own as that
      # region's root.  Regions covering fewer than Plan.min_nodes nodes
      # are dropped.  Anything else is read by the regions as a boundary
      # input.
      class Installation
        attr_reader :roots, :regions, :engine, :check

        # The Plan::SharedInputs handing this installation's regions the
        # buffers of inputs shared with other installations (a Synth's
        # lanes), or nil.
        attr_accessor :shared

        # Counts builds (and region changes that affect shared inputs), so
        # SharedInputs can tell when to recompute.
        attr_reader :generation

        # How many times the installation rebuilt after it was first built
        # (for stats and specs; see #rebuild).
        attr_reader :rebuilds

        # The LaneGroups of this installation's own regions (see
        # Plan.install), regrouped after each rebuild; nil when a Synth
        # groups its lanes' regions itself, or with Plan.lanes off.
        attr_accessor :lane_groups

        # +unread+ (optional): a predicate telling Tee branches that nothing
        # reads (see #live_branches).
        def initialize(roots, engine:, check:, dry_run: false, unread: nil)
          @roots = roots
          @engine = engine
          @check = check
          @dry_run = dry_run
          @unread = unread
          @regions = []
          @excluded = {}
          @unsupported = {}.compare_by_identity
          @restart_watches = []
          @watched = {}.compare_by_identity
          @stale = false
          @generation = 0
          @rebuilds = 0
          @shared = nil
          @retired = {}.compare_by_identity

          # The layout (see #find_layout)
          @readers = nil
          @tees_of = nil
          @seen = nil
          @order = nil
          @region_of = nil

          # Changes since the last build (see #note_change): changed nodes
          # with the number of their latest change, and the number of the
          # latest change to everything (a structural change), or nil
          @changes = 0
          @changed = {}.compare_by_identity
          @all_changed = nil
          # Rebuilds that must happen before the next block, whatever the
          # context (see #foreign_read)
          @urgent = false
          # A rebuild in progress elsewhere (see #stale?, Plan::Deferral),
          # and the regions running unfused until it lands (see #held?)
          @job = nil
          @held = {}.compare_by_identity
          @hold_all = false
          # A build for another installation (see Plan::Rebuild): the live
          # installation, and its regions this build may keep
          @owner = nil
          @keep = nil
          # Called by #find_layout between steps (see Plan::Rebuild)
          @slicer = nil
          # Whether the layout has resamplers (see #resamples?)
          @resamples = nil
          # Nodes a build elsewhere found unsupported (see #commit)
          @found = nil
        end

        # Blocks run planned and unfused by every region this installation
        # has had (for stats and specs; see Region#planned_blocks): the
        # current regions, whose counts include those of the regions they
        # replaced, plus regions that went away in a rebuild without a
        # successor (#dropped_blocks).
        def planned_blocks
          @regions.sum(&:planned_blocks) + @retired.each_value.sum { |c| c[0] }
        end

        def unfused_blocks
          @regions.sum(&:unfused_blocks) + @retired.each_value.sum { |c| c[1] }
        end

        # The [planned, unfused] block counts of regions that went away in a
        # rebuild without a new region on the same root (or of every region
        # while uninstalled).
        def dropped_blocks
          [0, 1].map { |k| @retired.each_value.sum { |c| c[k] } }
        end

        # The branches of +tee+ that count as its readers: every branch,
        # less those the installation's +unread+ predicate leaves out (a
        # Synth's branches made while building its lanes and read by no lane,
        # e.g. a `band * 0.5` left unused in the voice block; see
        # Synth#unread_branch?).  Regions, fusing, direct sources, and
        # SharedInputs treat those as absent, so an unused node changes
        # nothing (a fused node's Tee isn't sampled, so they stay empty; a
        # read from one goes through Region#foreign_read).
        def live_branches(tee)
          return tee.branches unless @unread

          tee.branches.reject { |b| @unread.call(b) }
        end

        # The predicate telling Tee branches nothing reads (see
        # #live_branches), or nil.
        attr_reader :unread

        # True after a change the plans haven't followed yet, whatever the
        # thread (see #stale?).
        def stale_here?
          @stale
        end

        # True after a change the plans haven't followed yet; the next
        # block rebuilds.  While the thread renders with a Plan::Deferral (a
        # realtime Session's render thread, see Plan.rebuilds) this is false
        # and starts the rebuild there instead: the regions the changes
        # touch run unfused (see #held?) until the new layout lands at a
        # block boundary (see #adopt).
        def stale?
          return false unless @stale
          return true if @urgent

          d = Plan.deferral
          return true unless d

          defer(d)
          false
        end

        # Marks the plans for a rebuild before the next block (a structural
        # change: every region rebuilds; see #note_change).
        def stale!
          note_change(nil)
        end

        # Called by Plan.changed with +structure: :ended+: +node+ stopped
        # reading inputs that ended (a ringing sum dropping a summand, an
        # envelope's ended parameter input), and nothing else changed, so
        # only the region holding +node+ rebuilds.  An installation that
        # only reaches +node+ (planned by another installation, e.g. the
        # Session player's installation seeing a Synth lane's sum) has
        # nothing to rebuild.
        def inputs_ended(node)
          return if !@region_of&.key?(node) && planned_elsewhere?(node)

          note_change(node)
        end

        # The changes noted since the last build (a counter; see
        # #note_change).
        attr_reader :changes

        # For internal use: notes a change to +node+ (nil: a structural
        # change, after which the layout is found again from scratch).  The
        # plans rebuild before the next block (see #stale?): regions whose
        # nodes didn't change keep their compiled programs (see
        # #find_layout).
        def note_change(node)
          @stale = true
          @changes += 1
          if node.nil?
            @all_changed = @changes
            @hold_all = true
          else
            @changed[node] = @changes
            r = @region_of&.[](node)
            @held[r] = true if r
          end
          nil
        end

        # True if +region+ runs unfused until a rebuild in progress lands
        # (its nodes changed; see #stale?).
        def held?(region)
          return false unless @job

          @hold_all || (!@held.empty? && @held.key?(region))
        end

        # The rebuild in progress elsewhere (a Plan::Rebuild), or nil.
        attr_reader :job

        # Recompiles the region computing +node+ (if any) before its next
        # block (see Plan.changed).
        def settings_changed(node)
          @region_of&.[](node)&.recompile
        end

        # Finds and installs the regions, keeping the current ones whose
        # nodes didn't change (see #find_layout).
        def build
          since = @changes
          old = @regions
          find_layout(old)
          commit(self, since, old)
          self
        end

        # Compiles every region that hasn't played yet (see
        # Region#precompile), here and in the installations of nodes this
        # one found already planned (e.g. a Synth's lanes when a Session
        # adds the Synth), so playing starts without compiling.
        def precompile
          others = @seen.each_key.filter_map { |n|
            next unless n.is_a?(Describing)
            owner = n.instance_variable_get(:@plan_region) || n.instance_variable_get(:@plan_member)
            owner&.installation unless owner&.installation.equal?(self)
          }.uniq
          ([self] + others).each do |inst|
            inst.regions.each(&:precompile)
            # Nodes found unsupported while compiling (e.g. a shaper of a
            # complex signal) replan now rather than at the first block
            5.times do
              break unless inst.stale?

              inst.rebuild
              inst.regions.each(&:precompile)
            end
          end
          self
        end

        # Rebuilds after a structural change (see Plan.changed), and
        # regroups the new regions (see #lane_groups) unless +regroup+ is
        # false.
        def rebuild(regroup: true)
          @rebuilds += 1
          # A rebuild running elsewhere is superseded
          @job&.cancel
          @job = nil
          # Readers of shared inputs may change in the middle of a block
          @shared&.guard!
          build
          @lane_groups&.refresh if regroup
        end

        # For internal use by Plan::Deferral (at a block boundary, on the
        # thread that renders): installs the layout +job+ (a Plan::Rebuild)
        # found, unless a structural change came after it started or
        # something it kept changed meanwhile (then it starts again).
        # Changes noted while it ran hold their regions in the new layout
        # and start the next rebuild.
        def adopt(job)
          return false unless @job.equal?(job)

          @job = nil
          layout = job.layout
          if layout.nil? || (@all_changed && @all_changed > job.since) || !layout.kept_current?(self)
            # (stale stays set: the next #stale? starts another)
            warn "Plan: dropped a rebuild of #{Plan.node_label(@roots[0])}: #{job.error ? "#{job.error.class}: #{job.error.message}" : 'changed meanwhile'}" if ENV['MB_SOUND_PLAN_DEBUG']
            @urgent = true if job.error # (rebuild here, in the next block)
            return false
          end

          @rebuilds += 1
          @shared&.guard!
          commit(layout, job.since, @regions)
          @lane_groups&.refresh
          true
        end

        # Marks a change that affects which inputs may be shared (a region
        # stopped planning; see SharedInputs).
        def touch
          @generation += 1
        end

        # True if the planned graphs contain resamplers (nodes reading their
        # inputs at another count than they are read), so inputs aren't
        # shared with other installations (see SharedInputs).
        def resamples?
          return true if @seen.nil?

          @resamples = @seen.each_key.any? { |n| n.is_a?(GraphNode::Resample) || (n.is_a?(GraphNode::Tee::Branch) && n.resampled?) } if @resamples.nil?
          @resamples
        end

        # Removes every hook; the graph runs unfused from the next block.
        def uninstall
          @job&.cancel
          @job = nil
          # Blocks lane groups computed for these regions and not yet read
          # go to the regions' roots (see LaneGroup#hand_off)
          @regions.each { |r| r.lane_group&.hand_off(r) }
          @regions.each(&:uninstall)
          # Counts carry over to the regions on the same roots after a
          # rebuild (see #build)
          @regions.each do |r|
            c = (@retired[r.root] ||= [0, 0])
            c[0] += r.planned_blocks
            c[1] += r.unfused_blocks
          end
          @regions = []
          @watched.each_key do |obj|
            list = Plan.watch[obj]
            list&.delete(self)
          end
          @watched = {}.compare_by_identity
          @roots.each do |r|
            list = r.instance_variable_get(:@plan_installations) if r.respond_to?(:sample)
            list&.delete_if { |i| i.equal?(self) }
          end
        end

        # Called by Region#compile when a node turned out unsupported.
        def unsupported!(node, why)
          warn "Plan: unsupported #{Plan.node_label(node)}: #{why}" if ENV['MB_SOUND_PLAN_DEBUG']
          @excluded[node] = why
          @unsupported[node] = true
          (@found ||= []) << node if @owner # (see #commit)
          mark_excluded(node)
          note_change(node)
        end

        # True if this installation leaves +node+ out of its regions (see
        # #exclude, #unsupported!).
        def excludes?(node)
          @excluded.key?(node)
        end

        # Why +node+ is left out (nil if it isn't).
        def exclusion_reason(node)
          @excluded[node]
        end

        # The nodes left out of every region, with why (a Hash).
        def excluded
          @excluded.dup
        end

        # Leaves +node+ out of every region from the next block (it is read
        # as a boundary input), saying +why+ in listings.  With
        # +until_restart+ (an event-driven node whose event stream is over),
        # the node comes back when its stream's content jumps (a seek,
        # restart, or rewind: live sets loop and seek; see RestartWatch).
        def exclude(node, why, until_restart: false)
          return if @excluded.key?(node)

          warn "Plan: excluding #{Plan.node_label(node)}: #{why}" if ENV['MB_SOUND_PLAN_DEBUG']
          @excluded[node] = why
          mark_excluded(node)
          if until_restart && node.respond_to?(:plan_generation)
            watch = RestartWatch.new(self, node, node.plan_generation)
            node.instance_variable_set(:@plan_restart, watch)
            @restart_watches << watch
          end
          note_change(node)
        end

        # Takes back into planning every node left out because its stream
        # ended whose stream has jumped since (see #exclude; called by the
        # first such node to notice), all at once, since nodes on one
        # stream depend on each other (e.g. Notes::EnvelopeInputs and its
        # ports).  Nodes found unsupported meanwhile are looked at again
        # too (they may have been unsupported only because of an excluded
        # input).  The regions rebuild before their next block.
        def reinclude
          back = @restart_watches.select(&:restarted?)
          return if back.empty?

          @restart_watches -= back
          back.each do |w|
            w.node.instance_variable_set(:@plan_restart, nil)
            @excluded.delete(w.node)
            unmark_excluded(w.node)
            warn "Plan: replanning #{Plan.node_label(w.node)}: its MIDI stream jumped" if ENV['MB_SOUND_PLAN_DEBUG']
          end
          @unsupported.each_key { |n| @excluded.delete(n); unmark_excluded(n) }
          @unsupported.clear
          # (nothing to hold: the current regions stay right)
          @stale = true
          @changes += 1
        end

        # Called by Region#foreign_read.
        def foreign_read(node)
          return if @excluded.key?(node)

          warn "Plan: #{Plan.node_label(node)} inside a fused region was read from outside it (an unseen reader); replanning with it as a boundary" if $VERBOSE || Plan.check
          @excluded[node] = 'read by a reader outside the planned graphs'
          note_change(node)
          # Its region can't run unfused for long (the node's two readers
          # would both advance it), so this rebuilds before the next block
          # even where rebuilds are deferred
          @urgent = true
        end

        # Why +node+ is read as a boundary input (for listings).
        def boundary_reason(node, forced)
          return 'boundary input of its reader' if forced
          return @excluded[node] if @excluded.key?(node)
          return 'planned separately' if @region_of && @region_of[node]

          r = candidate_reason(node)
          r || 'read outside the region'
        end

        # A listing of the regions (with their programs) and the reasons
        # other nodes aren't fused.
        def explain
          # Compile everything, replanning around nodes that turn out
          # unsupported when described
          10.times do
            @regions.each { |r| r.compile(start: false) }
            break unless stale?

            @stale = false
            traverse
            assign
          end

          lines = ["#{@regions.length} planned region#{@regions.length == 1 ? '' : 's'} covering #{@regions.sum { |r| r.members.length }} nodes"]
          @regions.each { |r| lines << r.to_s }
          folds = @regions.flat_map { |r| r.folds || [] }
          unless folds.empty?
            lines << "Folded 0 * x to 0 (Plan::Fold; x still computed every block): #{folds.length}"
            folds.group_by { |f| Plan.class_label(f.node) }.each do |label, fs|
              lines << "  #{label}: #{fs.map { |f| "#{Plan.node_label(f.node)} (0 * #{f.folded})" }.first(8).join(', ')}#{fs.length > 8 ? ", ... (#{fs.length})" : ''}"
            end
          end
          others = @order.select { |n| (n.is_a?(GraphNode) || n.is_a?(MultiDescribable)) && !n.is_a?(GraphNode::Tee::Branch) && !@region_of[n] }
          unless others.empty?
            lines << 'Unfused nodes:'
            others.group_by { |n| candidate_reason(n) || 'its region was too small' }.each do |why, nodes|
              lines << "  #{why}: #{nodes.map { |n| Plan.node_label(n) }.first(8).join(', ')}#{nodes.length > 8 ? ", ... (#{nodes.length})" : ''}"
            end
          end
          lines.join("\n")
        end

        # nil if +node+ may be fused, else why not.
        def candidate_reason(node)
          return @excluded[node] if @excluded.key?(node)
          if !node.is_a?(Describing) && node.respond_to?(:plan_owner) && @region_of&.[](node.plan_owner)
            # (A multi-output node's output: see MultiDescribable)
            return "an output of #{Plan.node_label(node.plan_owner)} (computed in its region)"
          end
          return "not a planned node type (#{Plan.class_label(node)})" unless node.is_a?(Describing)
          return 'observed (Plan.observe)' if Plan.observed?(node)

          return 'planned by another installation' if planned_elsewhere?(node)
          # Left out by the installation that planned it (e.g. a Synth
          # lane's envelope whose stream ended): another installation
          # reaching it (the Session player's, through the Synth) would
          # only find the same reason later, rebuilding its whole graph
          # for each such node (render-rebuild-1: fm_bass's player
          # installation took over 32 lane nodes the lanes had left out,
          # then rebuilt 18 times as their envelopes ended)
          ex = node.instance_variable_get(:@plan_excluded)
          return "left out by another installation (#{ex.exclusion_reason(node)})" if ex && !ex.equal?(@owner || self) && ex.excludes?(node)

          node.plan_unsupported_reason
        end

        # True if +node+ belongs to a region of another installation.
        def planned_elsewhere?(node)
          owner = node.instance_variable_get(:@plan_region) || node.instance_variable_get(:@plan_member)
          !!owner && !owner.installation.equal?(@owner || self)
        end

        # For internal use by Plan::Rebuild: makes this (new, dry run)
        # installation a build of +live+'s layout from +snapshot+ (see
        # #snapshot) somewhere else, with +slicer+ called between steps.
        def shadow_of(live, snapshot, slicer)
          @owner = live
          @excluded = snapshot[:excluded]
          @unsupported = snapshot[:unsupported]
          @changed = snapshot[:changed]
          @all_changed = snapshot[:all_changed]
          @changes = snapshot[:changes]
          @slicer = slicer
          self
        end

        # For internal use by Plan::Rebuild: what a build elsewhere starts
        # from (copies, taken on the thread that renders).
        def snapshot
          {
            excluded: @excluded.dup, unsupported: @unsupported.dup, changed: @changed.dup,
            all_changed: @all_changed, changes: @changes, regions: @regions.dup,
          }
        end

        # For internal use by #adopt: true if the live regions this layout
        # (a build elsewhere) keeps are still +live+'s current regions.
        def kept_current?(live)
          current = live.regions.to_h { |r| [r, true] }.compare_by_identity
          @regions.all? { |r| !r.installation.equal?(live) || (current.key?(r) && r.installed? && !r.disabled && r.program && !r.recompile_requested?) }
        end

        # For internal use: finds the regions (into this installation's
        # layout: who reads what, the regions, which region computes each
        # node), keeping those of +current+ (the live installation's regions)
        # whose nodes are the same and didn't change since they were built,
        # so they keep their compiled programs (render-rebuild-1: when a
        # lane's envelopes end, only their region changes).  Nothing is
        # kept after a structural change (Plan.changed with +structure:
        # true+): Tee branches and readers may have changed anywhere.
        def find_layout(current)
          @stale = false
          traverse
          assign
          keep_regions(current) if current && !current.empty? && @all_changed.nil?
          resamples? # (found here, maybe on another thread; see Plan::Rebuild)
          self
        end

        private

        # Replaces the regions of the layout just found with those of
        # +current+ (see #find_layout) on the same roots whose nodes are the
        # same and haven't changed, are installed, and plan (compiled, not
        # disabled, no recompile asked for).
        def keep_regions(current)
          owner = @owner || self
          by_root = {}.compare_by_identity
          current.each do |r|
            next unless r.installation.equal?(owner) && r.installed? && !r.disabled && r.program && !r.recompile_requested?
            next if !@changed.empty? && r.members.any? { |m| @changed.key?(m) }

            by_root[r.root] = r
          end
          return if by_root.empty?

          @regions.map! do |r|
            old = by_root[r.root]
            next r unless old && old.members.length == r.members.length && r.members.all? { |m| old.member?(m) }

            old.members.each { |m| @region_of[m] = old }
            old
          end
        end

        # Installs the layout of +src+ (this installation, after #find_layout,
        # or a build elsewhere; see #adopt): the regions it didn't keep are
        # removed (their block counts kept for regions on the same roots),
        # the new ones installed.  +old+ is the regions before.  Changes
        # noted after change +since+ (while a build elsewhere ran) stay,
        # holding their regions.
        def commit(src, since, old)
          kept = {}.compare_by_identity
          src.regions.each { |r| kept[r] = true if r.installation.equal?(self) && r.installed? }

          # Blocks lane groups computed for these regions and not yet read
          # go to the regions' roots (see LaneGroup#hand_off)
          old.each { |r| r.lane_group&.hand_off(r) }
          old.each do |r|
            next if kept.key?(r)

            r.uninstall
            # Counts carry over to the regions on the same roots
            c = (@retired[r.root] ||= [0, 0])
            c[0] += r.planned_blocks
            c[1] += r.unfused_blocks
          end

          unless src.equal?(self)
            @readers = src.layout_part(:@readers)
            @tees_of = src.layout_part(:@tees_of)
            @seen = src.layout_part(:@seen)
            @order = src.layout_part(:@order)
            @region_of = src.layout_part(:@region_of)
            @resamples = src.layout_part(:@resamples)
            # Nodes the build found unsupported
            src.layout_part(:@found)&.each do |n|
              next if @excluded.key?(n)

              @excluded[n] = src.exclusion_reason(n)
              @unsupported[n] = true
              mark_excluded(n)
            end
            src.regions.each { |r| r.installation = self unless kept.key?(r) }
          end

          @regions = src.regions
          @regions.each do |r|
            next if kept.key?(r)

            planned, unfused = @retired.delete(r.root)
            r.carry_counts(planned, unfused) if planned
          end
          unless @dry_run
            @regions.each { |r| r.install unless kept.key?(r) }
            watch
          end
          @generation += 1

          # Changes after +since+ stay
          @changed.delete_if { |_, n| n <= since } unless @changed.empty?
          @all_changed = nil if @all_changed && @all_changed <= since
          @urgent = false
          @held.clear
          @hold_all = !@all_changed.nil?
          @changed.each_key { |n| (r = @region_of[n]) && (@held[r] = true) }
          @stale = @changes > since
        end

        # For internal use by #commit: a part of a layout found elsewhere.
        def layout_part(name)
          instance_variable_get(name)
        end
        protected :layout_part

        # Starts a rebuild for Plan::Deferral +d+ (see #stale?), unless one
        # is running there.
        def defer(d)
          return if @job && @job.deferral.equal?(d)

          @job&.cancel
          @job = Rebuild.new(self, d)
          d.submit(@job)
        end

        # Marks +node+ as left out by this installation (see
        # #candidate_reason), unless another installation marked it first.
        def mark_excluded(node)
          return if @owner # (a build elsewhere: see #commit)
          return unless node.respond_to?(:sample) || node.is_a?(MultiDescribable)

          ex = node.instance_variable_get(:@plan_excluded)
          return if ex && !ex.equal?(self) && ex.excludes?(node)

          node.instance_variable_set(:@plan_excluded, self)
        end

        def unmark_excluded(node)
          node.instance_variable_set(:@plan_excluded, nil) if node.instance_variable_get(:@plan_excluded).equal?(self)
        end

        # Visits every object reachable from the roots through #sources,
        # recording who reads what, in an order where readers come first.
        def traverse
          @readers = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          @tees_of = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          @seen = {}.compare_by_identity
          @resamples = nil
          post = []

          # An explicit stack (long chains could overflow Ruby's)
          stack = []
          @roots.each { |r| stack.push([r, false]) }
          slicer = @slicer
          steps = 0
          until stack.empty?
            if slicer && (steps += 1) % 32 == 0
              slicer.call
            end
            obj, expanded = stack.pop
            if expanded
              post << obj
              next
            end
            next if @seen.key?(obj)

            @seen[obj] = true
            srcs = sources_of(obj)
            srcs.each do |s|
              @readers[s] << obj unless @readers[s].any? { |r| r.equal?(obj) }
              if s.is_a?(GraphNode::Tee)
                src = s.sources[:input]
                @tees_of[src] << s unless @tees_of[src].any? { |t| t.equal?(s) }
              end
            end
            stack.push([obj, true])
            srcs.reverse_each { |s| stack.push([s, false]) unless @seen.key?(s) }
          end

          @order = post.reverse

          # Oversample regions take their rates now that the graph exists
          # (consumers first, so nested regions multiply their outer rate;
          # see GraphNode::Resample#apply_oversample)
          pending = @order.select { |n| n.is_a?(GraphNode::Resample) && n.oversample_pending }
          GraphNode::Resample.apply_pending(pending) unless pending.empty?
        end

        def sources_of(obj)
          return [] unless obj.respond_to?(:sources)

          # Nodes that run part of their graph themselves (a feedback loop's
          # body) show the plan only their inputs
          s = obj.respond_to?(:plan_sources) ? obj.plan_sources : obj.sources
          return [] unless s.respond_to?(:each_value)

          # (Multi-output nodes have no #sample of their own: their outputs
          # read them; see MultiDescribable)
          s.each_value.select { |v| !v.is_a?(Numeric) && (v.respond_to?(:sample) || v.is_a?(GraphNode::Tee) || v.is_a?(MultiDescribable)) }
        end

        # The readers of +node+ that aren't Tees or branches, each with the
        # handle it reads, and whether every reader is accounted for.
        def consumers(node)
          result = []
          complete = true

          internal = node.instance_variable_get(:@internal_tee)
          tees = @tees_of[node].dup
          if internal && !tees.any? { |t| t.equal?(internal) } && !live_branches(internal).empty?
            complete = false # branches nobody here reads
          end

          @readers[node].each do |r|
            next if r.is_a?(GraphNode::Tee) # counted through its branches
            result << [r, node]
          end

          queue = tees
          until queue.empty?
            tee = queue.shift
            live_branches(tee).each do |b|
              readers = @seen.key?(b) ? @readers[b] : []
              more = @tees_of[b]
              complete = false if readers.empty? && more.empty?
              readers.each do |r|
                next if r.is_a?(GraphNode::Tee)
                result << [r, b]
              end
              queue.concat(more)
            end
          end

          [result, complete]
        end

        # True if +consumer+ may describe the node behind +handle+ inside
        # its own plan.
        def fusable_edge?(consumer, handle)
          return false unless consumer.is_a?(Describing)
          return false if handle.is_a?(GraphNode::Tee::Branch) && handle.resampled?

          consumer.plan_inputs.any? { |h| h.equal?(handle) } && consumer.plan_boundary_inputs.none? { |h| h.equal?(handle) }
        end

        def assign
          @region_of = {}.compare_by_identity
          regions = []
          roots = @roots.to_h { |r| [r, true] }.compare_by_identity

          slicer = @slicer
          steps = 0
          @order.each do |node|
            slicer.call if slicer && (steps += 1) % 32 == 0
            next if candidate_reason(node)

            region = nil
            unless roots.key?(node)
              cons, complete = consumers(node)
              if complete && !cons.empty?
                regs = cons.map { |c, h| fusable_edge?(c, h) ? @region_of[c] : nil }
                region = regs[0] if regs[0] && regs.all? { |x| x.equal?(regs[0]) }
              end
            end

            if region
              region.add_member(node)
            else
              region = Region.new(self, node, [node])
              regions << region
            end
            @region_of[node] = region
          end

          @regions = regions.select { |r| r.members.length >= Plan.min_nodes }
          (regions - @regions).each { |r| r.members.each { |n| @region_of.delete(n) } }
        end

        # Registers this installation for Plan.changed on every node it
        # covers (weakly both ways, see Plan.watch), and keeps it alive from
        # its roots while the graph lives (so an installation left without
        # regions still rebuilds after a later change).  After a rebuild
        # only the nodes that came or went change their lists.
        def watch
          seen = @seen
          watched = @watched
          unless watched.empty?
            watched.each_key { |obj| Plan.watch[obj]&.delete(self) unless seen.key?(obj) }
            watched.keep_if { |obj, _| seen.key?(obj) }
          end
          seen.each_key do |obj|
            next if obj.is_a?(Numeric) || watched.key?(obj)

            list = (Plan.watch[obj] ||= ObjectSpace::WeakMap.new)
            list[self] = true
            watched[obj] = true
          end

          @roots.each do |r|
            next unless r.respond_to?(:sample) && !r.frozen?

            list = r.instance_variable_get(:@plan_installations) || r.instance_variable_set(:@plan_installations, [])
            list << self unless list.any? { |i| i.equal?(self) }
          end
        end
      end

      # Watches a node left out of planning because its MIDI stream was
      # over (Installation#exclude with +until_restart+): the node's
      # Planned hook asks #restarted? on each #sample (one ivar read while
      # nothing changed), and once the stream's generation moves (a seek,
      # restart, or rewind) the installation takes the node back.
      class RestartWatch
        # The node left out.
        attr_reader :node

        def initialize(installation, node, generation)
          @installation = installation
          @node = node
          @generation = generation
        end

        # True once the stream's content has jumped since the exclusion.
        def restarted?
          @node.plan_generation != @generation
        end

        # Replans with the node and every other node of its installation
        # whose stream jumped (see Installation#reinclude).
        def reinclude
          @installation.reinclude
        end
      end

      class << self
        # The node behind +handle+ (climbing Tee branches).
        def origin(handle)
          handle = handle.owner_tee.sources[:input] while handle.is_a?(GraphNode::Tee::Branch)
          handle
        end

        # The type a region expects from boundary input +node+ (checked
        # every block): Describable#plan_output_type, :complex for complex
        # tones, else :real.
        def output_type(node)
          return node.plan_output_type if node.respond_to?(:plan_output_type)

          :real
        end
      end
    end
  end
end
