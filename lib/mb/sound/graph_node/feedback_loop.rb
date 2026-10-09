module MB
  module Sound
    module GraphNode
      # A feedback loop (GraphNode#feedback, alias #fb; #delay with a block):
      # the graph built by a block from the loop variable (+fb+ in the
      # examples) and the input (+input+) is the loop's body, and +fb+ is the
      # loop's own output, so the body
      # can feed its output back into itself through any of the nodes that
      # have loop ops: arithmetic (Mixer, Multiplier, Constant, / and **),
      # shapers (softclip, clip, abs, quantize, antialiased or not), delays
      # (`fb.delay(t)`, any interpolation; constant, moving, or tempo-synced
      # times), and SVF filters (`filter(:lowpass, cutoff:, quality:)`, any
      # type; cutoff, quality, and gain may move).  Nodes that don't depend
      # on +fb+ (the input, LFOs, envelopes, MIDI controls, delay times,
      # cutoffs) can be anything: the graph computes them a block at a time
      # and the loop reads them per sample.
      #
      # The body runs one sample at a time in C (MB::Sound::FastLoop; exact
      # Ruby mirror with MB_SOUND_PLAN=ruby or Plan.engine = :ruby), so the
      # output is the same whatever the block size (the point of per-sample
      # loops) and short loops (Karplus-Strong strings, flangers, filters
      # built from nodes) work.  See Plan::Loop for the details.
      #
      # == What the loop variable is
      #
      # When every path from +fb+ to the output goes through a delay, +fb+
      # is the current output, and the delays give the loop its length:
      # `sig.feedback { |fb, input| input + fb.delay(t) * 0.5 }` is a comb
      # filter whose echoes are exactly +t+ apart.  Otherwise (a path without
      # a delay) +fb+ is the output one sample earlier:
      # `sig.feedback { |fb, input| input + (fb - input) * 0.99 }` is a
      # one-pole lowpass.
      #
      # == Latency compensation (on by default)
      #
      # The longest delay on the loop reads earlier by the latency of the
      # rest of the loop (the one-sample history, an antialiased shaper's
      # half sample, a lowpass SVF's group delay, other delays), so the
      # loop's period is exactly that delay's time:
      # `exc.feedback { |fb, input| input + (fb.delay(t) ...).softclip }`
      # repeats every +t+.  #latency gives the compensation of the last
      # block; `compensate: false` turns it off.
      #
      # By default (`compensate: true` or `:pitch`, user decision
      # 2026-10-09) the latency is the rest of the loop's phase delay at
      # the loop's fundamental 1 / t, so a string with a loop lowpass plays
      # exactly at 1 / t (its higher partials keep the filter's
      # dispersion); it's evaluated every 16 samples of the stream and
      # ramps between those points while anything moves (Plan::Loop's
      # Program#pitch_latency).  `compensate: :dc` uses the group delay at
      # DC instead (exact for echo centers of mass, a few cents flat for
      # strings with a lowpass near the pitch; per sample when inputs move).
      #
      # == Sustain (on by default)
      #
      # A lowpass in a string's loop takes loop gain from its fundamental
      # every period (at 2x the pitch, 0.26 dB: T60 0.47 s instead of 4.7 s
      # at 440 Hz).  With `sustain: true` (or :pitch; user's request
      # 2026-10-09, the default chosen by playability) a loop with SVF
      # filters gets a hidden shelf on its pitch delay's input that makes
      # the loop's gain at the pitch (1 / the delay's time) what it would be
      # without the filters, so the ring time follows the loop's gains while
      # the filters change the tone (T60 within 2% from 8x the pitch down
      # to 2x, 5% at 1x, at 110-1760 Hz).  It is a high shelf (DC keeps its
      # loop gain: a flat boost would make the loop's DC mode grow), capped
      # at a boost of 2 (+6 dB; below about 0.6x the pitch the ring shortens
      # again), and only boosts for gentle lowpasses (every SVF a lowpass
      # with a quality up to 1 / sqrt(2), paths that join filtered alike):
      # other filters can have more gain at the harmonics than at the
      # pitch.  Where the filters have gain above 1 at the pitch (a
      # resonant lowpass there) it cuts flat instead.  Loops without SVFs
      # and `sustain: false` are unchanged; #delay echo loops have none
      # (their pitch would be 1 / the echo time).  It follows moving
      # cutoffs and delay times with Plan::Loop's pitch tracking (every 16
      # samples, ramped; the same at any block size; held while nothing
      # moves); #sustain_ratio gives the shelf's gain at the pitch.  Cost:
      # one more SVF and multiply-add per sample (constant parameters, KS
      # at 440 Hz: 0.62% of realtime instead of 0.52 at 512-sample blocks),
      # about twice the pitch tracking's Ruby while parameters move (cutoff
      # LFO: 7.0% instead of 3.8%).  Not in the fallback.
      #
      # Delays shorter than the sinc kernel's reach (about 13 samples) can't
      # read the samples newer than the read position (they aren't computed
      # yet), so inside loops sinc reads blend into cubic reads from about
      # 13 down to 9 samples (constant whole-sample delays always read the
      # sample directly).
      #
      # == Fallback
      #
      # A body with a node that has no loop op on the loop (an oscillator
      # modulated by +fb+, a four-pole filter, a reverb, a Ruby proc) can't
      # run per sample.  That's an error in scripts and specs; in live mode
      # (MB::Sound.live_error) it warns and runs the body as a graph in
      # small blocks instead: +fb+ is the output one block earlier and the
      # longest delay reads that much earlier (op latencies are not
      # compensated).  Short delays then cost a lot of CPU (a block of 1 for
      # loops without a delay).
      #
      # Examples (bin/sound.rb):
      #     # Comb filter / echo with exact 3/16 note repeats
      #     play file_input('sounds/drums.flac').feedback { |fb, input| input + fb.delay(3.n16) * 0.5 }
      #     # Karplus-Strong pluck (see bin/synths/pluck.rb)
      #     exc = noise.at(0.5) * adsr(0, 0.005, 0, 0.005, hold: 0.005)
      #     play exc.feedback { |fb, input| input + fb.delay(220.hz.period).then { |d| (d + d.delay(1.samples)) * 0.498 } }
      #     # Tape echo with saturation and tone in the loop
      #     play input.delay(0.3, feedback: 0.7) { |fb| fb.filter(:lowpass, cutoff: 3000).softclip(0.5, 1) }
      class FeedbackLoop
        include GraphNode
        include GraphNode::SampleRateHelper

        # The loop variable (+fb+ in the examples): the loop's output (see the
        # class description).  Its #sample is only used by the fallback.
        class Variable
          include GraphNode

          def initialize(loop)
            @loop = loop
            @data = nil
            @node_type_name = 'Feedback (y)'
          end

          # For the fallback: the buffer the next read returns.
          attr_writer :data

          def sample(count)
            raise "#{self} is computed by its feedback loop (#{@loop}), not sampled on its own" unless @data

            d = @data
            d.length == count ? d : d[0...count]
          end

          def sources
            {}
          end

          def sample_rate
            @loop.sample_rate
          end

          def sample_rate=(rate)
            self
          end
          alias at_rate sample_rate=
        end

        # The loop variable node.
        attr_reader :variable

        # The node computed by the block (the body's output).
        attr_reader :body

        # The compiled Plan::Loop::Program (nil while running the fallback).
        attr_reader :program

        # Why the loop runs as a block graph (nil when it runs per sample).
        attr_reader :fallback_reason

        # The loop's latency compensation in samples for the last block (a
        # Float, the mean for a block where it moved), or nil before the
        # first block, without a delay to compensate, or in the fallback.
        attr_reader :latency

        # True if the delay on the loop absorbs the loop's latency (see the
        # class description).
        attr_reader :compensate

        # :pitch if the loop's gain at the pitch is normalized for its
        # filters, false if not (see the class description).
        attr_reader :sustain

        # The sustain shelf's gain at the pitch for the last block (1.0
        # without sustain, before the first block, or for a loop without
        # SVF filters): the factor that makes up for the filters' loss.
        def sustain_ratio
          @program&.sustain ? @program.sustain_ratio : 1.0
        end

        # Builds a loop on +input+ (a node or nil) by calling +block+ with
        # the loop variable (and +input+).  See GraphNode#feedback.
        def initialize(input = nil, compensate: true, sustain: true, sample_rate: nil, &block)
          raise ArgumentError, 'A feedback loop needs a block that builds its body from the loop variable' unless block

          @input = input
          @sample_rate = (sample_rate || input&.sample_rate || 48000).to_f
          @compensate = case compensate
                        when true, :pitch then :pitch
                        when :dc then :dc
                        when false, nil then false
                        else raise ArgumentError, "compensate: must be true (:pitch), :dc, or false (got #{compensate.inspect})"
                        end
          @sustain = case sustain
                     when true, :pitch then :pitch
                     when false, nil then false
                     else raise ArgumentError, "sustain: must be true (:pitch) or false (got #{sustain.inspect})"
                     end
          @variable = Variable.new(self)
          @node_type_name = 'FeedbackLoop'

          body = block.arity == 1 || block.arity == -1 && !input ? block.call(@variable) : block.call(@variable, input)
          body = MB::Sound::GraphNode::Constant.new(body, sample_rate: @sample_rate) if body.is_a?(Numeric)
          unless body.respond_to?(:sample)
            raise ArgumentError, "The feedback block must return a graph node (got #{body.inspect})"
          end
          if body.respond_to?(:channel_count) && body.channel_count != 1
            raise ArgumentError, 'A feedback loop body must have one channel (call #feedback on each channel of a bundle)'
          end

          @body = body
          @body_handle = body.get_sampler
          @fallback = nil
          @latency = nil
          @check_failed = false
          @out = nil
          @out_views = {}

          compile
        end

        # Returns +count+ samples of the loop's output (a reused buffer), or
        # nil once an input (or a delay time) ends.
        def sample(count)
          return @fallback.sample(count) if @fallback

          sample_program(count)
        end

        def sources
          src = {}
          src[:input] = @input if @input.respond_to?(:sample)
          src[:body] = @body
          src
        end

        # The inputs the plan layer may fuse upstream (Plan::Installation):
        # the loop's boundary inputs, not the body (which only runs here).
        def plan_sources
          return { body: @body_handle } if @fallback

          src = @input_ops.each_with_index.to_h { |op, i| [:"input_#{i}", op.handles[0]] }
          @program.rings.each_with_index do |g, i|
            t = g.delay.sources[:delay]
            src[:"delay_time_#{i}"] = t if t
          end
          src
        end

        def sample_rate=(rate)
          return self if rate.to_f == @sample_rate

          super
          @body.sample_rate = rate if @body.respond_to?(:sample_rate=)
          compile unless @fallback
          self
        end
        alias at_rate sample_rate=

        # A listing of the loop program (or why it runs as a block graph).
        def explain
          return "#{self}: runs as a block graph (#{@fallback_reason})" if @fallback

          @program.to_s
        end

        def to_s
          "#{node_type_name}#{@fallback ? ' (fallback)' : ''}"
        end

        private

        # Finds the loop's nodes, describes them as a Plan::Loop::Program,
        # and picks the compensated delay.  On an unsupported node, raises in
        # scripts and specs, or warns and builds the fallback in live mode
        # (MB::Sound.live_error).
        def compile
          @program = Compiler.new(self, @variable, @body, compensate: @compensate, sustain: @sustain).program
          @sustain_ops = @program.params.grep(Plan::Loop::Op::SustainParam)
          @input_ops = @program.inputs
          @param_ops = @program.params
          @inputs = Array.new(@input_ops.length)
          @params = Array.new(@param_ops.length)
          @values = {}.compare_by_identity
          @delays = Array.new(@program.rings.length)

        rescue Plan::Unsupported => e
          message = "this feedback loop can't run one sample at a time (#{e.message.sub(/\A#{Regexp.escape(Plan.node_label(e.node))}: /, '')}); in live mode it runs as a block graph instead (slower; op latencies aren't compensated)"
          MB::Sound.live_error(Plan::Unsupported.new(e.node, message))

          @fallback_reason = e.message
          @program = nil
          @fallback = Fallback.new(self, @variable, @body_handle, compensate: @compensate)
        end

        # The loop's work for a block (see the class description).
        def sample_program(count)
          n = count

          # Boundary inputs (every handle, keeping their Tees in step)
          @input_ops.each_with_index do |op, i|
            hs = op.handles
            buf = hs[0].sample(count)
            j = 1
            while j < hs.length
              hs[j].sample(count)
              j += 1
            end
            return nil if buf.nil? || buf.empty?

            unless buf.is_a?(Numo::SFloat)
              if buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex)
                raise ArgumentError, "Feedback loops are real only (#{Plan.node_label(op.source)} gave a complex buffer)"
              end
              buf = Numo::SFloat.cast(buf)
            end
            buf = buf.dup unless buf.contiguous?
            n = buf.length if buf.length < n
            @inputs[i] = buf
            @values[op.dst] = buf
          end

          @param_ops.each_with_index do |op, i|
            next if op.is_a?(Plan::Loop::Op::SustainParam) # (set below)

            v = op.constant.plan_param(count)
            @params[i] = v
            @values[op.dst] = v.is_a?(Numo::NArray) ? v : v.to_f
          end

          if n < count
            @inputs.map! { |b| b.length > n ? b[0...n].dup : b }
            @params.map! { |v| v.is_a?(Numo::NArray) && v.length > n ? v[0...n].dup : v }
          end

          # Delay times (each delay node's own time handling), with room in
          # each delay line
          rings = @program.rings
          rings.each_with_index do |g, i|
            d = g.delays(n)
            return nil if d.nil?

            d = d[0...n] if d.is_a?(Numo::NArray) && d.length > n
            max = d.is_a?(Numo::NArray) ? d.max.to_f : d.to_f
            max = 0.0 unless max.finite?
            g.line.prepare(n, max + 2, Numo::SFloat)
            g.last_delay = d.is_a?(Numo::NArray) ? Numo::DFloat.cast(d) : d.to_f
            @delays[i] = d
          end

          # The latency and the sustain shelf at the pitch
          track = pitch_track(n) if @compensate == :pitch || @program.sustain
          set_sustain(track, n) if @program.sustain

          if (comp = @program.compensated)
            idx = rings.index { |g| g.equal?(comp) }
            if @compensate
              l = @compensate == :dc ? @program.latency(@values) : track[0]
              d = comp.last_delay
              @delays[idx] = d.is_a?(Numo::NArray) || l.is_a?(Numo::NArray) ? Numo::DFloat.cast(d - l) : d - l
              @latency = l.is_a?(Numo::NArray) ? l.mean : l
            end
          end

          run(n)
        end

        # Program#pitch_track for a block of +n+ samples; in check mode the C
        # kernel and its Ruby mirror from the same state, compared bit for bit.
        def pitch_track(n)
          unless MB::Sound::Plan.check && !@check_failed && MB::Sound::Plan.engine != :ruby
            return @program.pitch_track(@values, n)
          end

          track, problem = @program.pitch_track_check(@values, n)
          return track unless problem

          message = "Feedback loop check failed: #{problem}\n#{@program}"
          raise Plan::CheckFailed, message if Plan.check == :raise

          warn "#{message}\nNot checking this loop from now on."
          @check_failed = true
          track
        end

        # Sets the sustain shelf's params for a block of +n+ samples from
        # Program#pitch_track's [latency, gain, rest] (cutoff from the pitch
        # delay's time, per sample when it moves).
        def set_sustain(track, n)
          @sustain_ops.each do |op|
            v = case op.role
                when :gain then track[1]
                when :rest then track[2]
                when :cutoff then @program.sustain_cutoff(@program.pitch_ring.last_delay)
                end
            v = Numo::SFloat.cast(v.length > n ? v[0...n] : v) if v.is_a?(Numo::NArray)
            @params[op.index] = v
          end
        end

        def run(n)
          out = out_view(n)
          if MB::Sound::Plan.check && !@check_failed
            check_run(n, out)
          elsif MB::Sound::Plan.engine == :ruby
            out[true] = @program.run_ruby(n, @inputs, @params, @delays)
          else
            @program.run(n, @inputs, @params, @delays, out)
          end
          out
        end

        # Check mode (MB_SOUND_PLAN_CHECK): runs the block in C, then from
        # the same state with the Ruby mirror, and compares the samples and
        # the state bit for bit.
        def check_run(n, out)
          before = snapshot
          @program.run(n, @inputs, @params, @delays, out)
          c_out = out.dup
          c_state = snapshot
          restore(before)
          r_out = @program.run_ruby(n, @inputs, @params, @delays)
          r_state = snapshot

          problem = nil
          if c_out.to_binary != r_out.to_binary
            diff = (Numo::DFloat.cast(c_out) - Numo::DFloat.cast(r_out)).abs
            problem = "samples differ by up to #{diff.max} (first at #{(diff > 0).where.to_a.first})"
          elsif c_state != r_state
            problem = 'the loop state differs'
          end
          return unless problem

          message = "Feedback loop check failed: #{problem}\n#{@program}"
          raise Plan::CheckFailed, message if Plan.check == :raise

          warn "#{message}\nNot checking this loop from now on."
          @check_failed = true
        end

        # The loop's state (delay lines, shaper/SVF states, histories) as
        # plain values, for check mode.
        def snapshot
          rings = @program.rings.map { |g|
            line = g.line
            [line.instance_variable_get(:@buffer).to_binary, line.instance_variable_get(:@write_offset),
             line.instance_variable_get(:@block_start), g.read_state.dup]
          }
          states = @program.ops.filter_map { |op|
            case op
            when Plan::Op::Shape then op.shaper.plan_state.dup
            when Plan::Loop::Op::Svf then op.filter.instance_variable_get(:@state).dup
            when Plan::Loop::Op::LoopHistory then op.state.dup
            end
          }
          [rings, states]
        end

        def restore(snap)
          rings, states = snap
          @program.rings.each_with_index do |g, i|
            bin, w, bs, rs = rings[i]
            line = g.line
            buf = line.instance_variable_get(:@buffer)
            buf[true] = buf.class.from_binary(bin)
            line.instance_variable_set(:@write_offset, w)
            line.instance_variable_set(:@block_start, bs)
            g.read_state.replace(rs)
          end
          k = 0
          @program.ops.each do |op|
            arr = case op
                  when Plan::Op::Shape then op.shaper.plan_state
                  when Plan::Loop::Op::Svf then op.filter.instance_variable_get(:@state)
                  when Plan::Loop::Op::LoopHistory then op.state
                  end
            next unless arr

            arr.replace(states[k])
            k += 1
          end
        end

        # The output buffer's first +n+ samples (a view reused while +n+
        # stays the same).
        def out_view(n)
          if @out.nil? || @out.length < n
            @out = Numo::SFloat.zeros(n)
            @out_views.clear
          end
          @out_views[n] ||= @out[0...n]
        end

        # Finds the loop's nodes and describes them (see FeedbackLoop#compile).
        class Compiler
          # The compiled Plan::Loop::Program.
          attr_reader :program

          def initialize(loop, variable, body, compensate:, sustain: false)
            @loop = loop
            @y = variable
            @body = body
            @compensate = compensate
            @sustain = sustain

            traverse
            check_readers
            describe
          end

          private

          def origin(handle)
            Plan.origin(handle)
          end

          def handles_of(node)
            return [] unless node.respond_to?(:sources)

            s = node.sources
            return [] unless s.respond_to?(:each_value)

            s.each_value.select { |v| !v.is_a?(Numeric) && v.respond_to?(:sample) }
          end

          # Marks the nodes that depend on the loop variable (the loop's
          # nodes), and whether a path from the variable to the output avoids
          # every delay (then the variable is the output one sample earlier).
          def traverse
            @cycle = {}.compare_by_identity
            @readers = Hash.new { |h, k| h[k] = [] }.compare_by_identity
            visiting = {}.compare_by_identity
            dep = {}.compare_by_identity

            visit = lambda do |node|
              return true if node.equal?(@y)
              return dep[node] if dep.key?(node)
              raise ArgumentError, "A feedback loop body can't contain a cycle of its own (#{Plan.node_label(node)})" if visiting[node]

              visiting[node] = true
              d = false
              handles_of(node).each do |h|
                o = origin(h)
                @readers[o] << [node, h]
                d = true if visit.call(o)
              end
              visiting.delete(node)
              dep[node] = d
            end

            body = origin(@body)
            unless visit.call(body)
              raise ArgumentError, "The feedback block's result doesn't use the loop variable (#{Plan.node_label(body)})"
            end
            dep.each { |n, d| @cycle[n] = true if d }
            @output_node = body

            # A path from the variable to the output with no delay?
            seen = {}.compare_by_identity
            direct = lambda do |node|
              return true if node.equal?(@y)
              return false if seen[node] || !@cycle[node]

              seen[node] = true
              return false if delay_node?(node) # its input is behind the delay

              handles_of(node).any? { |h| direct.call(origin(h)) }
            end
            @history = direct.call(body)
          end

          # Nodes on the loop must be read only by other nodes on the loop
          # (and the output by the loop itself): an outside reader would run
          # the node's own #sample, outside the loop.
          def check_readers
            @cycle.each_key do |node|
              tee = node.instance_variable_get(:@internal_tee)
              next unless tee

              known = @readers[node].map { |_, h| h }
              tee.branches.each do |b|
                next if known.any? { |h| h.equal?(b) }
                next if node.equal?(origin(@body)) && origin(b).equal?(node) && b.equal?(@loop.instance_variable_get(:@body_handle))

                raise ArgumentError, "#{Plan.node_label(node)} is inside the feedback loop but also read outside it; use the loop's output (or a node computed from it) instead"
              end
            end
          end

          def delay_node?(node)
            node.respond_to?(:base_filter) && node.base_filter.is_a?(MB::Sound::Filter::Delay)
          end

          def describe
            b = Plan::Loop::Builder.new(method(:resolve), method(:defer))
            @b = b
            @described = {}.compare_by_identity
            @boundaries = {}.compare_by_identity
            @params = {}.compare_by_identity
            @pending = []
            @y_value = nil
            @output = nil
            @history_state = [0.0]

            @output = describe_node(b, @output_node)
            # The output must be a computed register (the variable alone, or
            # a boundary input passed through, are copied)
            @output = b.copy(@output) if @output.op.is_a?(Plan::Op::Input) || @output.op.is_a?(Plan::Op::Param)

            # Delay inputs are described after the output: they may read the
            # loop variable as the current output
            until @pending.empty?
              ring, handle = @pending.shift
              b.node_stack.push(ring.node)
              begin
                ring.input = b[handle]
              ensure
                b.node_stack.pop
              end
              ring.input = b.copy(ring.input) unless ring.input.is_a?(Plan::Value)
            end

            rings = b.rings
            sustain = nil
            unless rings.empty?
              # The longest delay sets the pitch and absorbs the latency
              # (node times count as longest; the first of equals)
              best = rings.max_by.with_index { |g, i| [g.constant_samples || Float::INFINITY, -i] }
              best.compensated = true if @compensate
              best.pitched = true if @compensate || @sustain

              # The sustain shelf on its input, for loops with SVF filters
              sustain = sustain_shelf(b, best) if @sustain && b.ops.any? { |op| op.is_a?(Plan::Loop::Op::Svf) }
            end

            @program = Plan::Loop::Program.new(
              ops: b.ops, inputs: b.inputs, params: b.params, rings: rings, histories: b.histories,
              output: @output, history: @history, title: Plan.node_label(@loop), sustain: sustain
            )
            @program.lower
          end

          # Builds the sustain shelf (Plan::Loop::Program#pitch_track) on
          # +ring+'s input: gain * x + rest * lowpass(x).
          def sustain_shelf(b, ring)
            b.node_stack.push(@loop)
            x = ring.input
            gain = b.sustain_param(:gain)
            rest = b.sustain_param(:rest)
            cutoff = b.sustain_param(:cutoff)
            filter = MB::Sound::Filter::SVF.new(:lowpass, @loop.sample_rate, 1000, quality: Plan::Loop::Program::SUSTAIN_SHELF_Q)
            lp = b.svf(filter, x, cutoff: cutoff, quality: Plan::Loop::Program::SUSTAIN_SHELF_Q, gain: 1.0)
            y = b.add(b.mul(x, gain), b.mul(lp, rest))
            ring.input = y
            { input: x, output: y, filter: filter, gain: gain, rest: rest, cutoff: cutoff, svf: lp.op }
          ensure
            b.node_stack.pop
          end

          def describe_node(b, node)
            v = @described[node]
            return v if v

            v = b.describe(node)
            @described[node] = v
          end

          # The Builder resolver (see Plan::Region#resolve).
          def resolve(b, handle, consumer, force_boundary, optional = false)
            node = origin(handle)

            if node.equal?(@y)
              return @y_value ||= @history ? b.history(@history_state) : current_output(b)
            end

            if @cycle[node]
              raise Plan::Unsupported.new(consumer, "it reads #{Plan.node_label(node)} as a block input, which depends on the loop") if force_boundary

              return describe_node(b, node)
            end

            if node.is_a?(GraphNode::Constant) && !handle.is_a?(GraphNode::Tee::Branch)
              return @params[node] ||= b.param(node)
            end

            op = @boundaries[node]
            if op
              op.handles << handle unless op.handles.any? { |h| h.equal?(handle) }
              return op.dst
            end

            unless handle.is_a?(GraphNode::Tee::Branch)
              raise Plan::Unsupported.new(consumer, "an input that isn't a Tee branch (#{Plan.node_label(node)})")
            end

            v = b.input(:real, source: node, handles: [handle], reason: 'computed outside the loop')
            @boundaries[node] = v.op
            v
          end

          # The loop variable as the current output (every path from it to
          # the output has a delay, so it is only read by delays' inputs,
          # after the output is computed).
          def current_output(b)
            raise Plan::Unsupported.new(@loop, 'the loop variable was read before the output was known') unless @output

            b.loop_output(@output)
          end

          public

          # For nodes' #loop_describe: queues +ring+'s input +handle+ (see
          # #describe).
          def defer(ring, handle)
            @pending << [ring, handle]
          end
        end

        # Runs the body as a graph in small blocks when it can't run per
        # sample (see the class description): the loop variable is the
        # output +block+ samples earlier, and the longest delay reads that
        # much earlier.
        class Fallback
          # The block size (1 when a path without a delay needs the output of
          # the previous sample).
          attr_reader :block

          def initialize(loop, variable, body_handle, compensate:)
            @loop = loop
            @y = variable
            @body = body_handle

            delays = loop.body.graph.select { |n| n.respond_to?(:base_filter) && n.base_filter.is_a?(MB::Sound::Filter::Delay) && depends?(n) }
            history = direct_path?
            longest = delays.max_by { |n| n.base_filter.delay_samples.is_a?(Numeric) ? n.base_filter.delay_samples : Float::INFINITY }
            if history || longest.nil?
              @block = 1
              offset = 0
            else
              ds = longest.base_filter.delay_samples
              @block = ds.is_a?(Numeric) ? ds.floor.clamp(1, 256) : 32
              offset = @block
            end
            longest&.base_filter&.loop_offset = offset if compensate && offset > 0

            @hist = Numo::SFloat.zeros(@block)
            @out = nil
          end

          def sample(count)
            @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
            pos = 0
            while pos < count
              b = [@block, count - pos].min
              @y.data = @hist[0...b]
              buf = @body.sample(b)
              return (pos == 0 ? nil : @out[0...pos]) if buf.nil? || buf.empty?

              buf = Numo::SFloat.cast(buf)
              got = buf.length
              @out[pos...(pos + got)] = buf
              @hist = @block > got ? @hist[got..].concatenate(buf) : buf[(got - @block)..].dup
              pos += got
              return @out[0...pos] if got < b
            end
            @out
          end

          private

          def depends?(node)
            node.graph.any? { |n| n.equal?(@y) }
          end

          def direct_path?
            seen = {}.compare_by_identity
            walk = lambda do |node|
              return true if node.equal?(@y)
              return false if seen[node]

              seen[node] = true
              return false if node.respond_to?(:base_filter) && node.base_filter.is_a?(MB::Sound::Filter::Delay)

              node.sources.each_value.any? { |h| h.respond_to?(:sample) && walk.call(Plan.origin(h)) }
            end
            walk.call(@loop.body)
          end
        end
      end
    end
  end
end
