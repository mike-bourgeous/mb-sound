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

        def initialize(roots, engine:, check:, dry_run: false)
          @roots = roots
          @engine = engine
          @check = check
          @dry_run = dry_run
          @regions = []
          @excluded = {}
          @watched = []
          @stale = false
        end

        # True after a structural change; the next block rebuilds.
        def stale?
          @stale
        end

        # Marks the plans for a rebuild before the next block.
        def stale!
          @stale = true
        end

        # Recompiles the region computing +node+ (if any) before its next
        # block (see Plan.changed).
        def settings_changed(node)
          @region_of&.[](node)&.recompile
        end

        # Finds and installs the regions.
        def build
          @stale = false
          traverse
          assign
          @regions.each(&:install) unless @dry_run
          watch unless @dry_run
          self
        end

        # Compiles every region that hasn't played yet (see
        # Region#precompile), here and in the installations of nodes this
        # one found already planned (e.g. a Synth's lanes when a Session
        # adds the Synth), so playing starts without compiling.
        def precompile
          others = @seen.each_key.filter_map { |n|
            next unless n.is_a?(Describable)
            owner = n.instance_variable_get(:@plan_region) || n.instance_variable_get(:@plan_member)
            owner&.installation unless owner&.installation.equal?(self)
          }.uniq
          (@regions + others.flat_map(&:regions)).each(&:precompile)
          self
        end

        # Rebuilds after a structural change (see Plan.changed).
        def rebuild
          uninstall
          build
        end

        # Removes every hook; the graph runs unfused from the next block.
        def uninstall
          @regions.each(&:uninstall)
          @regions = []
          @watched.each do |obj|
            list = Plan.watch[obj]
            list&.delete(self)
          end
          @watched = []
        end

        # Called by Region#compile when a node turned out unsupported.
        def unsupported!(node, why)
          @excluded[node] = why
          stale!
        end

        # Called by Region#foreign_read.
        def foreign_read(node)
          return if @excluded.key?(node)

          warn "Plan: #{Plan.node_label(node)} inside a fused region was read from outside it (an unseen reader); replanning with it as a boundary" if $VERBOSE || Plan.check
          @excluded[node] = 'read by a reader outside the planned graphs'
          stale!
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
          others = @order.select { |n| n.is_a?(GraphNode) && !n.is_a?(GraphNode::Tee::Branch) && !@region_of[n] }
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
          return "not a planned node type (#{Plan.class_label(node)})" unless node.is_a?(Describable)
          return 'observed (a spy or Plan.observe)' if Plan.observed?(node)

          owner = node.instance_variable_get(:@plan_region) || node.instance_variable_get(:@plan_member)
          return 'planned by another installation' if owner && !owner.installation.equal?(self)

          node.plan_unsupported_reason
        end

        private

        # Visits every object reachable from the roots through #sources,
        # recording who reads what, in an order where readers come first.
        def traverse
          @readers = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          @tees_of = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          @seen = {}.compare_by_identity
          post = []

          # An explicit stack (long chains could overflow Ruby's)
          stack = []
          @roots.each { |r| stack.push([r, false]) }
          until stack.empty?
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
        end

        def sources_of(obj)
          return [] unless obj.respond_to?(:sources)

          s = obj.sources
          return [] unless s.respond_to?(:each_value)

          s.each_value.select { |v| !v.is_a?(Numeric) && (v.respond_to?(:sample) || v.is_a?(GraphNode::Tee)) }
        end

        # The readers of +node+ that aren't Tees or branches, each with the
        # handle it reads, and whether every reader is accounted for.
        def consumers(node)
          result = []
          complete = true

          internal = node.instance_variable_get(:@internal_tee)
          tees = @tees_of[node].dup
          if internal && !tees.any? { |t| t.equal?(internal) } && !internal.branches.empty?
            complete = false # branches nobody here reads
          end

          @readers[node].each do |r|
            next if r.is_a?(GraphNode::Tee) # counted through its branches
            result << [r, node]
          end

          queue = tees
          until queue.empty?
            tee = queue.shift
            tee.branches.each do |b|
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
          return false unless consumer.is_a?(Describable)

          consumer.plan_inputs.any? { |h| h.equal?(handle) } && consumer.plan_boundary_inputs.none? { |h| h.equal?(handle) }
        end

        def assign
          @region_of = {}.compare_by_identity
          regions = []
          roots = @roots.to_h { |r| [r, true] }.compare_by_identity

          @order.each do |node|
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

        def watch
          @seen.each_key do |obj|
            next if obj.is_a?(Numeric)

            list = (Plan.watch[obj] ||= [])
            list << self unless list.any? { |i| i.equal?(self) }
            @watched << obj
          end
        end
      end

      class << self
        # The node behind +handle+ (climbing Tee branches).
        def origin(handle)
          handle = handle.tee.sources[:input] while handle.is_a?(GraphNode::Tee::Branch)
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
