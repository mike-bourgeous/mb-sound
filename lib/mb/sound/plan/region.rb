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

        # Why the region stopped planning (nil while it plans).
        attr_reader :disabled

        # Blocks run planned and unfused (for stats and specs).
        attr_reader :planned_blocks, :unfused_blocks

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

        # Hooks the nodes (see Planned).
        def install
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
          @program = Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: output, title: Plan.node_label(@root))
          @program.lower if @installation.engine == :c
          @inputs = Array.new(@input_ops.length)
          @params = Array.new(@param_ops.length)
          @ended = Array.new(@input_ops.length, false)
          @read = Array.new(@input_ops.length) { [] }
          @want = @input_ops.map { |op| op.dst.complex? ? Numo::SComplex : Numo::SFloat }
          @direct = @input_ops.map { |op| direct_source(op) }
          @out_class = output.complex? ? Numo::SComplex : Numo::SFloat
          @out = nil
          @out_views.clear

          # Event-driven nodes run their per-block Ruby (see EventList),
          # each once, in op order
          @feeders = []
          @program.ops.each do |op|
            f = op.respond_to?(:feeder) ? op.feeder : nil
            @feeders << f if f && @feeders.none? { |x| x.equal?(f) }
          end

          @started = false
          start_tones if start
          @program

        rescue Unsupported => e
          @program = nil
          @installation.unsupported!(e.node, e.message)
          nil
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

        # Runs one block (called by the root's Planned hook).
        def sample(count)
          if @installation.stale?
            @installation.rebuild
            return @root.sample(count)
          end

          return run_unfused(count) if @disabled || count <= 0

          if @recompile
            @recompile = false
            @program = nil
          end

          unless @program || compile
            return @root.sample(count) if @installation.stale?
            return run_unfused(count)
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
              if f.plan_finished?
                @installation.exclude(f, 'its MIDI stream is over')
                return run_unfused(count)
              end
              k += 1
            end
          end

          if @installation.check
            stateful = @members.select { |m| m.respond_to?(:plan_snapshot) }
            before = stateful.map(&:plan_snapshot)
          end

          gathered = gather(count)
          return nil if gathered == :ended
          return replay_unfused(count) if gathered == :mismatch

          n = gathered
          k = 0
          while k < feeders.length
            feeders[k].plan_feed(count)
            k += 1
          end

          return check_block(n, count, stateful, before) if @installation.check

          @planned_blocks += 1
          execute(n)
        end

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
            if (direct = @direct[i])
              # Every branch of the source's Tee is ours: read the source
              # itself (the Tee is skipped like a fused node's)
              buf = direct.sample(count)
              read << buf
            else
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

        # Runs the program on gathered inputs for +n+ samples.
        def execute(n)
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

        # Runs the region's nodes themselves for this block, replaying the
        # boundary inputs the region already read.
        def replay_unfused(count)
          @input_ops.each_with_index do |op, i|
            read = @read[i]
            next if read.empty?

            if @direct[i]
              # One read of the source for every branch, shared read-only
              # as the Tee would share it
              buf = read[0]
              buf = buf[0..].freeze if buf && !buf.frozen? && op.handles.length > 1
              op.handles.each { |h| h.replay = buf }
            else
              op.handles.each_with_index do |h, j|
                h.replay = read[j] if j < read.length
              end
            end
          end
          run_unfused(count)
        ensure
          @input_ops&.each { |op| op.handles.each { |h| h.replay = nil } }
        end

        def run_unfused(count)
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
        def check_block(n, count, stateful, before)
          planned = execute(n)
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
            worst = diff[~(diff.isnan)].max || 0.0
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
              problem = "the state of #{Plan.node_label(m)} differs: planned #{planned_states[i].inspect[0, 300]}, unfused #{after[i].inspect[0, 300]}"
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
