module MB
  module Sound
    module Plan
      # A planned part of a graph at run time: its root node (whose #sample
      # runs the region through the Planned hook), the nodes inside it, and
      # the compiled Program.  Each block it reads the boundary inputs
      # through the handles the region's nodes hold, reads the Constants'
      # values, and runs the program (in C, or with the Ruby mirror).
      #
      # Fallbacks: a block whose inputs don't fit the program (a boundary
      # input of another type, a Constant turning complex) runs unfused,
      # replaying the inputs already read (Tee::Branch#replay), and the
      # program is rebuilt for the next block.  A structural change
      # (Plan.changed) rebuilds the whole installation before the next
      # block.
      class Region
        # How far node states may differ in check mode after a block of a
        # program with inexact ops (relative to 1 or the value's size).
        STATE_TOLERANCE = 1e-5

        # The node whose output this region computes.
        attr_reader :root

        # Every node computed by the region (the root included).
        attr_reader :members

        # The Installation this region belongs to.
        attr_reader :installation

        # True while the region's nodes run their own #sample (a fallback
        # or check mode's reference run).
        attr_reader :unfused

        # The compiled program (nil before the region first plays).
        attr_reader :program

        # The products folded to zero in the program (Op::ZeroFold; see
        # Plan::Fold), after it compiled.
        attr_reader :folds

        # Why the region stopped planning (nil while it plans).
        attr_reader :disabled

        # Blocks run planned and unfused (for stats and specs), counted
        # since the region's root was first planned: a rebuild (see
        # Installation#rebuild) carries the counts of the region it
        # replaces over to the new region with the same root (see
        # #carry_counts), so blocks that ran unfused before a rebuild still
        # count.
        def planned_blocks
          @planned_blocks + @carried_planned
        end

        def unfused_blocks
          @unfused_blocks + @carried_unfused
        end

        # For internal use by Installation: adds +planned+ and +unfused+
        # blocks counted by the regions this one replaces.
        def carry_counts(planned, unfused)
          @carried_planned += planned
          @carried_unfused += unfused
        end

        def initialize(installation, root, members)
          @installation = installation
          @root = root
          @members = []
          @member_set = {}.compare_by_identity
          members.each { |m| add_member(m) }
          @unfused = false
          @program = nil
          @disabled = nil
          @types = {}
          @planned_blocks = 0
          @unfused_blocks = 0
          @carried_planned = 0
          @carried_unfused = 0
          @out_views = {}
        end

        # For internal use by Installation: adds a node to the region.
        def add_member(node)
          return if @member_set.key?(node)

          @members << node
          @member_set[node] = true
        end

        # True if +node+ is computed by this region.
        def member?(node)
          @member_set.key?(node)
        end

        # True while the region is installed on its nodes.
        def installed?
          @installed
        end

        # Hooks the nodes (see Planned).
        def install
          @installed = true
          @members.each do |n|
            if n.equal?(@root)
              n.instance_variable_set(:@plan_region, self)
            else
              n.instance_variable_set(:@plan_member, self)
            end
          end
        end

        # Removes the hooks; the nodes run unfused from the next block.
        def uninstall
          @installed = false
          @members.each do |n|
            n.instance_variable_set(:@plan_region, nil) if n.instance_variable_get(:@plan_region).equal?(self)
            n.instance_variable_set(:@plan_member, nil) if n.instance_variable_get(:@plan_member).equal?(self)
          end
        end

        # Compiles the program now (normally done when the region first
        # plays), returning it, or nil if a node turned out unsupported.
        # +start+ starts the region's tones (as playing them would).
        def compile(start: true)
          return @program if @program

          b = Builder.new(method(:resolve))
          @described = {}
          @boundaries = {}
          @consumers = {}
          output = b.describe(@root)
          @described[@root] = output
          # The output is computed into the output buffer, so a boundary
          # input or param passed through is copied there
          output = b.copy(output) if output.op.is_a?(Op::Input) || output.op.is_a?(Op::Param)

          @input_ops = b.inputs
          @param_ops = b.params
          ops, @folds = Fold.zero_products(b.ops)
          Fold.report(@folds)
          @program = Program.new(ops: ops, inputs: b.inputs, params: b.params, output: output, title: Plan.node_label(@root))
          @program = ScaleMatch.pad(@program, @pads) if @pads
          @program.lower if @installation.engine == :c
          @inputs = Array.new(@input_ops.length)
          @params = Array.new(@param_ops.length)
          @ended = Array.new(@input_ops.length, false)
          @read = Array.new(@input_ops.length) { [] }
          @want = @input_ops.map { |op| op.dst.complex? ? Numo::SComplex : Numo::SFloat }
          @direct = @input_ops.map { |op| direct_source(op) }
          @via_shared = Array.new(@input_ops.length, false)
          @out_class = output.complex? ? Numo::SComplex : Numo::SFloat
          @out = nil
          @out_views.clear
          @out_alt = nil
          @out_views_alt = nil

          # Event-driven nodes run their per-block Ruby (see EventList),
          # each once, in op order
          @feeders = []
          @program.ops.each do |op|
            f = op.respond_to?(:feeder) ? op.feeder : nil
            @feeders << f if f && @feeders.none? { |x| x.equal?(f) }
          end
          @feeders = Plan.group_feeders(@feeders)

          @started = false
          start_tones if start
          @program

        rescue Unsupported => e
          @program = nil
          @installation.unsupported!(e.node, e.message)
          nil
        end

        # Gains `x * 1` to insert so the program has the shape of other
        # regions it differs from only by gains (a Hash of core op index =>
        # count, or nil; see ScaleMatch and LaneGroups#refresh).
        attr_reader :pads

        # Sets #pads and recompiles now (returning the program, or nil).
        # The region's tones start as usual when it next plays.
        def pad!(pads)
          pads = nil if pads&.empty?
          return @program if pads == @pads && @program

          @pads = pads
          @program = nil
          @recompile = false
          compile(start: false)
        end

        # Asks for a recompile before the next block (a node's settings
        # changed; see Plan.changed).  Safe to call from another thread.
        def recompile
          @recompile = true
        end

        # Compiles a region that hasn't played yet ahead of time (from
        # Plan.install, so a live graph's first block doesn't compile;
        # its tones start when it plays).  Returns the program or nil.
        def precompile
          return @program unless @planned_blocks == 0 && @unfused_blocks == 0

          if @recompile
            @recompile = false
            @program = nil
          end
          compile(start: false)
        end

        # The Plan::LaneGroup running this region's program together with
        # structurally identical regions (e.g. the same region in every lane
        # of a Synth), or nil.
        attr_accessor :lane_group

        # Runs one block (called by the root's Planned hook): through the
        # region's LaneGroup if it has one, else alone.
        def sample(count)
          group = @lane_group
          return group.sample(self, count) if group

          sample_alone(count)
        end

        # Runs one block of this region by itself (see #sample).
        def sample_alone(count)
          n = prepare(count)
          return @result unless n.is_a?(Integer)

          finish(n, count)
        end

        # For internal use by #sample_alone and LaneGroup: everything a
        # block does before the program runs (rebuilds, compiles, fallbacks,
        # reading the boundary inputs, and the feeds).  Returns the sample
        # count to run, or :done with the block's result in #result (an
        # unfused block, a rebuilt installation's output, or nil once the
        # region's graph ended).
        def prepare(count)
          if @installation.stale?
            @installation.rebuild
            @result = @root.sample(count)
            return :done
          end

          if @disabled || count <= 0
            @result = run_unfused(count)
            return :done
          end

          if @recompile
            @recompile = false
            @program = nil
          end

          unless @program || compile
            @result = @installation.stale? ? @root.sample(count) : run_unfused(count)
            return :done
          end
          start_tones unless @started

          # A feeder whose stream is over may start ending (returning nil)
          # in an order that depends on the graph: run this block unfused
          # and replan with it as a boundary (see EventList)
          feeders = @feeders
          unless feeders.empty?
            k = 0
            while k < feeders.length
              f = feeders[k]
              if f.plan_finished?(count)
                (f.respond_to?(:plan_nodes) ? f.plan_nodes : [f]).each { |x| @installation.exclude(x, 'its event stream is over', until_restart: true) }
                @result = run_unfused(count)
                return :done
              end
              k += 1
            end
          end

          if @installation.check
            @check_stateful = @members.select { |m| m.respond_to?(:plan_snapshot) }
            @check_before = @check_stateful.map(&:plan_snapshot)
          end

          gathered = gather(count)
          if gathered.equal?(:ended)
            tails = @members.select { |m| m.respond_to?(:plan_tail?) && m.plan_tail? }
            unless tails.empty?
              # Nodes holding delayed samples (a lookahead compressor) flush
              # them after their input ends: this block runs unfused on the
              # inputs already read, and those nodes stay unfused while
              # they flush
              tails.each { |m| @installation.exclude(m, 'flushing its delayed tail after its input ended') }
              @result = replay_unfused(count)
              return :done
            end

            # Spies see the end as the nodes' own #sample shows it (nil)
            @program.taps.each { |t| t.deliver(nil) } unless @installation.check
            @result = nil
            return :done
          end
          if gathered.equal?(:mismatch)
            @result = replay_unfused(count)
            return :done
          end

          k = 0
          while k < feeders.length
            feeders[k].plan_feed(count)
            k += 1
          end

          gathered
        end

        # The result of a block #prepare finished (see there).
        attr_reader :result

        # For internal use by #sample_alone and LaneGroup: runs the program
        # for +n+ samples of a +count+-sample block that #prepare made ready
        # (or, with +planned+, takes the output a LaneGroup computed into
        # #out_view), checking it in check mode.  Returns the output.
        def finish(n, count, planned = nil)
          if @installation.check
            stateful = @check_stateful
            before = @check_before
            @check_stateful = @check_before = nil
            return check_block(n, count, stateful, before, planned)
          end

          @planned_blocks += 1
          out = planned || execute(n)
          taps = @program.taps
          unless taps.empty?
            k = 0
            while k < taps.length
              taps[k].deliver(n)
              k += 1
            end
          end
          out
        end

        # For internal use by LaneGroup: the boundary input buffers and
        # params of the gathered block, as FastPlan.run takes them.
        attr_reader :inputs, :params

        # Called by a node inside this region that was read from outside
        # the plan (a reader the region finder didn't see, e.g. a Tee made
        # outside every installed graph): the installation rebuilds with
        # that node as a boundary.  The read itself runs unfused, so this
        # one block may hear the node advance twice.
        def foreign_read(node)
          @installation.foreign_read(node)
        end

        # The listing of the compiled program (compiling it if needed).
        def to_s
          compile
          @program ? @program.to_s : "Region #{Plan.node_label(@root)} (not compiled: #{@disabled})"
        end

        # Stops planning this region (its nodes run unfused from now on).
        def disable(why)
          @disabled = why
          @installation.shared&.guard!
          @installation.touch
        end

        private

        # The node a region may read directly for boundary input +op+:
        # its handles are every branch of one Tee on that node (so nothing
        # else reads the Tee), else nil.
        def direct_source(op)
          tees = op.handles.map(&:tee).uniq
          return nil unless tees.length == 1

          tee = tees[0]
          src = tee.sources[:input]
          return nil if src.is_a?(GraphNode::Tee::Branch) || !src.equal?(op.source)
          return nil unless tee.branches.length == op.handles.length && tee.branches.all? { |b| op.handles.any? { |h| h.equal?(b) } }

          src
        end

        # Starts the region's tones as their first #sample would.
        def start_tones
          @program.tones.each { |op| op.tone.plan_start }
          @started = true
        end

        # Builder resolver: describes members inside the plan, reads
        # everything else as boundary inputs.
        def resolve(b, handle, consumer, force_boundary, optional = false)
          node = Plan.origin(handle)
          if !force_boundary && @member_set.key?(node) && !node.equal?(@root)
            v = @described[node]
            unless v
              v = b.describe(node)
              @described[node] = v
              b.tap_value(v, node) if Plan.tapped?(node)
            end
            return v
          end

          key = [node, optional]
          op = @boundaries[key]
          if op
            op.handles << handle unless op.handles.any? { |h| h.equal?(handle) }
            @consumers[op] << consumer unless @consumers[op].any? { |c| c.equal?(consumer) }
            return op.dst
          end

          raise Unsupported.new(consumer, "an input that isn't a Tee branch (#{Plan.node_label(node)})") unless handle.is_a?(GraphNode::Tee::Branch)

          type = @types[node] || Plan.output_type(node)
          reason = @installation.boundary_reason(node, force_boundary)
          v = b.input(type, source: node, handles: [handle], reason: reason, optional: optional)
          @boundaries[key] = v.op
          @consumers[v.op] = [consumer]
          v
        end

        # Reads every boundary input and Constant for one block.  Returns
        # the sample count to run (shorter if an input gave a short
        # buffer), :ended if a required input ended, or :mismatch if a
        # buffer doesn't fit the program.
        def gather(count)
          min = count
          ended = false
          mismatch = false
          inputs = @inputs
          ops = @input_ops
          shared = @installation.shared&.buffers

          i = 0
          while i < ops.length
            op = ops[i]
            read = @read[i]
            read.clear
            if @ended[i]
              inputs[i] = nil
              i += 1
              next
            end

            handles = op.handles
            if shared && shared.key?(op.source)
              # Read once for every installation sharing it (a Synth's
              # lanes; see SharedInputs)
              buf = shared[op.source]
              read << buf
              @via_shared[i] = true
            elsif (direct = @direct[i])
              # Every branch of the source's Tee is ours: read the source
              # itself (the Tee is skipped like a fused node's)
              buf = direct.sample(count)
              read << buf
              @via_shared[i] = false
            else
              @via_shared[i] = false
              buf = handles[0].sample(count)
              read << buf
              j = 1
              while j < handles.length
                read << handles[j].sample(count)
                j += 1
              end
            end

            if buf.nil? || buf.empty?
              inputs[i] = nil
              if op.optional
                @ended[i] = true
                @consumers[op].each do |c|
                  # A consumer may ask for the block to run unfused (it reads
                  # the ended input itself; see Envelope#plan_input_ended)
                  if c.respond_to?(:plan_input_ended) && c.plan_input_ended(op.source) == :replay
                    mismatch = true
                  end
                end
              else
                ended = true
              end
            else
              unless buf.class == @want[i]
                if buf.is_a?(Numo::SFloat) || buf.is_a?(Numo::SComplex)
                  @types[op.source] = buf.is_a?(Numo::SComplex) ? :complex : :real
                else
                  # Double precision inputs make the nodes compute in double
                  disable("a #{buf.class.name} input from #{Plan.node_label(op.source)}")
                end
                mismatch = true
              end
              buf = buf.dup unless buf.contiguous?
              if buf.length < count && op.optional && @consumers[op].any? { |c| c.respond_to?(:plan_pads_inputs?) && c.plan_pads_inputs? }
                # A consumer that pads short inputs (Envelope) runs this
                # block itself
                mismatch = true
              end
              min = buf.length if buf.length < min
              inputs[i] = buf
            end

            i += 1
          end

          return :ended if ended

          if mismatch
            @program = nil
            return :mismatch
          end

          params = @params
          pops = @param_ops
          k = 0
          while k < pops.length
            op = pops[k]
            c = op.constant
            if c.plan_complex? && !op.dst.complex?
              @program = nil
              return :mismatch
            end
            params[k] = c.plan_param(count) # as its readers would sample it
            k += 1
          end

          min
        end

        public

        # Runs the program on gathered inputs for +n+ samples (for internal
        # use by LaneGroup too).
        def execute(n)
          taps = @program.taps
          k = 0
          while k < taps.length
            taps[k].reserve(n)
            k += 1
          end

          if @installation.engine == :ruby
            result = @program.run_ruby(n, @inputs, @params)
            out = out_view(n)
            out[true] = result
            out
          else
            @program.run(n, @inputs, @params, out_view(n))
          end
        end

        # The output buffer's first +n+ samples (a view reused while +n+
        # stays the same).
        def out_view(n)
          if @out.nil? || @out.length < n
            @out = @out_class.zeros(n)
            @out_views.clear
          end
          @out_views[n] ||= @out[0...n]
        end

        # For internal use by LaneGroup: switches to the other of two output
        # buffers.  A group computes every member when any member is read,
        # so a member's next block is written before the member's own
        # readers (a Tee sharing its last buffer as a frozen frame) have
        # asked for it; with two buffers the block they hold stays intact
        # until they read again.
        def swap_out!
          @out, @out_alt = @out_alt, @out
          @out_views, @out_views_alt = (@out_views_alt || {}), @out_views
          self
        end

        private

        # Runs the region's nodes themselves for this block, replaying the
        # boundary inputs the region already read.
        def replay_unfused(count)
          @input_ops.each_with_index do |op, i|
            read = @read[i]
            next if read.empty?

            if @direct[i] || @via_shared[i]
              # One read of the source for every branch, shared read-only
              # as the Tee would share it
              buf = read[0]
              buf = buf[0..].freeze if buf && !buf.frozen? && op.handles.length > 1
              buf = GraphNode::Tee::Branch::ENDED if buf.nil?
              op.handles.each { |h| h.replay = buf }
            else
              op.handles.each_with_index do |h, j|
                h.replay = read[j].nil? ? GraphNode::Tee::Branch::ENDED : read[j] if j < read.length
              end
            end
          end
          run_unfused(count, replaying: true)
        ensure
          @input_ops&.each { |op| op.handles.each { |h| h.replay = nil } }
        end

        # Runs the region's nodes themselves for this block (see
        # #replay_unfused; without +replaying+, inputs shared with other
        # installations are put on every branch first, see
        # SharedInputs#guard!).
        def run_unfused(count, replaying: false)
          @installation.shared&.guard! unless replaying
          @unfused_blocks += 1
          @unfused = true
          @members.each { |m| m.instance_variable_set(:@plan_bypass, true) }
          @root.sample(count)
        ensure
          @unfused = false
          @members.each { |m| m.instance_variable_set(:@plan_bypass, false) }
        end

        # Check mode: runs the block planned, then unfused from the same
        # state with the same inputs, and compares the samples and the
        # nodes' states.  Returns the unfused samples.
        def check_block(n, count, stateful, before, planned = nil)
          planned ||= execute(n)
          planned = planned.dup
          planned_states = stateful.map(&:plan_snapshot)

          stateful.each_with_index { |m, i| m.plan_restore(before[i]) }
          reference = replay_unfused(count)
          @unfused_blocks -= 1
          @planned_blocks += 1

          problem = nil
          if reference.nil?
            problem = 'the unfused graph ended'
          elsif reference.length != planned.length
            problem = "lengths differ (planned #{planned.length}, unfused #{reference.length})"
          else
            diff = (Numo::DComplex.cast(planned) - Numo::DComplex.cast(reference)).abs
            nan_ok = planned.isnan.eq(reference.isnan).all?
            finite = diff[~(diff.isnan)]
            worst = finite.empty? ? 0.0 : finite.max # (every sample NaN on one side only: nan_ok reports it)
            # Inexact ops (Plan.precision :fast) may differ by their
            # tolerance, scaled by the output's level
            limit = @program.exact? ? 0.0 : @program.ops.map(&:tolerance).max * [1.0, Numo::DComplex.cast(reference).abs.max].max
            if !nan_ok || worst > limit
              idx = diff.isnan.where.to_a.first || diff.max_index
              problem = "samples differ by up to #{worst} (first at #{idx}: planned #{planned[idx]}, unfused #{reference[idx]})"
            end
          end

          after = stateful.map(&:plan_snapshot)
          if problem.nil?
            stateful.each_with_index do |m, i|
              next if after[i] == planned_states[i]
              # Inexact ops' differences can reach state through the ops
              # after them (a fast sine modulating a frequency moves a
              # phase), within the same tolerance
              next if !@program.exact? && Plan.states_close?(after[i], planned_states[i], STATE_TOLERANCE)
              detail = planned_states[i].is_a?(Snapshot) && after[i].is_a?(Snapshot) ? planned_states[i].diff(after[i]) : "planned #{planned_states[i].inspect[0, 300]}, unfused #{after[i].inspect[0, 300]}"
              problem = "the state of #{Plan.node_label(m)} differs: #{detail}"
              break
            end
          end

          if problem
            message = "Plan check failed for #{Plan.node_label(@root)}: #{problem}\n#{@program}"
            raise CheckFailed, message if @installation.check == :raise

            warn "#{message}\nRunning this region unfused from now on."
            disable(problem)
          end

          reference
        end
      end
    end
  end
end
