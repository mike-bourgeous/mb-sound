module MB
  module Sound
    module GraphNode
      # A named, swappable hole in a graph (racks R3, proposal 2.7): what
      # `sig.slot(:color) { |s| s.softclip }` makes.  The slot reads its
      # input and runs it through its content, built from the block on a
      # stand-in for the input (one Feed per channel).  A Session swaps the
      # content on an exact frame (Session#swap_slot, console `swap
      # :"dub/color", arack { ... }`), handing over the way master chains
      # do (Session::Handover): the old content spills over (fed silence
      # from the switch frame, so its tails ring out, and dropped once
      # quiet), crossfades (+fade:+), or is cut (+fade: 0+).
      #
      # A slot inside a rack's block belongs to the rack's instance (its
      # Session name is :"dub/color", or :"bass/dub/color" once the rack
      # plays in several players, like rack knobs; see
      # Session::Racks#adopt_slots); outside a rack (or in an anonymous
      # one) it belongs to the player (:"bass/color").  Named audio racks
      # (MB::Sound::Rack) also wrap each instance in a slot without a name,
      # so re-defining the rack swaps playing instances.
      #
      # Contents are Session::Master::Chain values (the master chain
      # machinery: +block+ is what built it, +source+ its Feeds, +nodes+
      # its output per channel, +start+ the frame it starts on).  The slot
      # is a plan boundary; its contents plan on their own.
      class Slot
        include MultiOutput
        node_traits memory: :none

        # One output channel of a Slot (the node the graph reads).
        class Output
          include GraphNode
          include GraphNode::NodeOutput
          node_traits memory: :none

          # The channel's index.
          attr_reader :index

          def initialize(slot, index)
            @owner = slot
            @index = index
            @node_type_name = 'Slot'
            @graph_node_name = nil
          end

          def sample(count)
            @owner.sample_internal(count, @index)
          end

          def sample_rate
            @owner.sample_rate
          end

          # The Slot this output belongs to.
          def owner_slot
            @owner
          end

          # The contents' nodes for this channel: the current content as
          # +input+, older ones still spilling over (or waiting to start)
          # as input_2, input_3, ...
          def sources
            @owner.channel_sources(@index)
          end

          def to_s
            @owner.to_s
          end
        end

        # A slot content's stand-in for one channel of the slot's input: it
        # gives the content the frames the slot pushes (the input, or
        # silence while the content spills over).  Contents may read a
        # buffer in pieces, never ahead of it.
        class Feed
          include GraphNode
          node_traits memory: :none

          def initialize(slot, index)
            @slot = slot
            @index = index
            @buf = nil
            @pos = 0
            @node_type_name = 'Slot input'
            @graph_node_name = nil
          end

          # Gives the next read +buf+ (nil: the input ended).  For the Slot.
          def push(buf)
            @buf = buf
            @pos = 0
          end

          def sample(count)
            b = @buf
            return nil if b.nil?
            if @pos == 0 && count == b.length
              @pos = count
              return b
            end
            if @pos + count <= b.length
              v = b[@pos...(@pos + count)].dup
              @pos += count
              return v
            end
            return nil if @pos >= b.length && b.length < @slot.last_count # (the input ended inside the buffer)

            raise ArgumentError, "slot #{@slot.name.inspect}: its content read #{count} samples with #{b.length - @pos} left in the buffer " \
                                 '(nodes that read ahead of their output, like a resample with a lookahead, go outside slots)'
          end

          def sample_rate
            @slot.sample_rate
          end

          # The slot's input for this channel (what the feed stands for).
          def sources
            { input: @slot.input_node(@index) }
          end
        end

        # The slot's name (a Symbol; nil for a rack instance's slot).
        attr_reader :name

        # The Rack whose application made the slot (nil outside racks), and
        # that Rack::Application.
        attr_reader :rack, :application

        # For a named rack's instance slot (see MB::Sound::Rack#call): the
        # rack applied and its coerced extra port values (rebuilt with them
        # when the rack is re-defined); nil for other slots.
        attr_reader :instance_of, :instance_ports

        # The Session name the slot answers to once its graph plays
        # (:"dub/color"), set by Session::Racks#adopt_slots; nil before.
        attr_accessor :path

        # The player whose graph holds the slot (set when it joins a
        # Session), and its rack instance key ([player, ordinal]).
        attr_accessor :player, :instance_key

        # The receiver and result of the recorded `slot` call (how a swap
        # re-records the slot so documents print its current content).
        attr_accessor :receiver, :result

        # The output nodes (one per channel).
        attr_reader :outputs

        # The sample rate.
        attr_reader :sample_rate

        # The count of the latest read (for Feed).
        attr_reader :last_count

        # Creates a slot named +name+ on +input+ (a node or bundle) whose
        # content +content+ builds (a block or anything callable taking
        # the input's stand-in: a node for one channel, else a bundle).
        # +instance_of+ (a Rack) and +ports+ make a named rack's instance
        # slot (see MB::Sound::Rack#call).
        def initialize(input, name:, content:, instance_of: nil, ports: {}, application: Rack.application)
          raise ArgumentError, "Slot names are Symbols (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol)
          unless input.is_a?(GraphNode) || input.is_a?(MultiOutput)
            raise ArgumentError, "A slot's input is a graph node or bundle (got #{input.class}); notes slots come later"
          end

          @name = name
          @application = application
          @rack = application&.rack
          @instance_of = instance_of
          @instance_ports = ports.dup.freeze
          @path = nil
          @player = nil
          @instance_key = nil
          @receiver = nil
          @result = nil
          ins = input.outputs
          @inputs = ins.map(&:get_sampler)
          @sample_rate = @inputs[0].sample_rate.to_f
          @chains = []
          @pending = []
          @frame = nil
          @clock = nil
          @last_count = 0
          @in_bufs = Array.new(@inputs.length)
          @data = []
          @out = nil
          @out_bufs = nil
          @sampled = nil
          @session = nil
          @scratch = {}.compare_by_identity

          first = build(content)
          @channels = first.nodes.length
          @outputs = Array.new(@channels) { |i| Output.new(self, i) }.freeze
          @sampled = Array.new(@channels, false)
          first.started = true
          first.start = 0
          @chains << first
        end

        # The node or bundle the `slot` call returns: the output for one
        # channel, else a Channels bundle.
        def returned
          @channels == 1 ? @outputs[0] : Channels.new(@outputs)
        end

        # The number of input channels.
        def input_channels
          @inputs.length
        end

        # The slot input for channel +index+ (see Feed#sources).
        def input_node(index)
          @inputs[index]
        end

        # The content playing now (a Session::Master::Chain).
        def current
          @chains.last
        end

        # What built the current content (a Proc or Rack).
        def content
          current.block
        end

        # The contents playing: spilling over, and current last.
        def chains
          @chains.dup
        end

        # A description: "slot :color (softclip)".
        def to_s
          "#{@name ? "slot #{(@path || @name).inspect}" : "rack #{@instance_of&.name.inspect}"} (#{current.description})"
        end

        def inspect
          "#<Slot #{self}#{" +#{@chains.length - 1} handing over" if @chains.length > 1}>"
        end

        # See Output#sources.
        def channel_sources(index)
          src = {}
          k = 0
          @chains.reverse_each do |c|
            n = c.nodes[index]
            src[k == 0 ? :input : :"input_#{k + 1}"] = n
            k += 1
          end
          src
        end

        # Builds a content (a Session::Master::Chain, not started) from
        # +content+ (a block, a Rack, or anything callable on the
        # stand-in), on new Feeds.  Raises if it gives another number of
        # channels than the slot has (one channel plays on every channel).
        def build(content)
          feeds = Array.new(@inputs.length) { |i| Feed.new(self, i) }
          arg = feeds.length == 1 ? feeds[0] : Channels.new(feeds)
          result = Slot.call_content(content, arg)
          list = Slot.nodes_of(result, @name)
          if @channels && list.length != @channels
            raise ArgumentError, "slot #{(@path || @name).inspect} has #{@channels} channel#{'s' if @channels != 1}; the new content gives #{list.length}" unless list.length == 1
            list *= @channels
          end
          nodes = list.map(&:get_sampler)
          Session::Master::Chain.new(
            block: content, source: feeds, nodes: nodes, description: Slot.describe(content, list),
            timeline_nodes: nodes.flat_map { |n| [n, *n.graph] }.grep(Sequence::TimelineNode).uniq,
            started: false, feeding: true, gain: 1.0, gain_step: 0.0, tail_start: nil, quiet: nil, tail_done: false,
            slow_warned: false, mode: :spill
          )
        end

        # Hands over to +chain+ (from #build) on session frame +frame+ by
        # +mode+ (:spill, :fade, :cut) with +step+ the gain change per frame
        # of a fade.  Called by Session#swap_slot under the render lock;
        # the change shows in #sources at once (Plan.changed).
        def queue(chain, frame, mode: :spill, step: 1.0, session: nil)
          chain.start = frame
          chain.mode = mode
          chain.fade = step
          @session ||= session
          @pending.clear # (the latest change for one slot wins)
          @pending << chain
          chain
        end

        # Contents queued but not started (in the Session's waiting-graph
        # bookkeeping until they start; see Session::Strip#catch_up_waiting).
        # They join #sources when they start.
        def waiting
          @pending
        end

        # The content queued last, else the one playing.
        def latest
          @pending.last || current
        end

        # Samples every channel when +index+ was read already this buffer
        # (or on the first read), then gives channel +index+.
        def sample_internal(count, index)
          if @out.nil? || @sampled[index]
            @sampled.fill(false)
            @out = render(count)
          end
          @sampled[index] = true
          @out && @out[index]
        end

        # Builds +content+ on +arg+ (the stand-in): a block or callable
        # taking it, or a Rack applied to it.
        def self.call_content(content, arg)
          if content.is_a?(MB::Sound::Rack)
            content.call(arg)
          elsif content.respond_to?(:call)
            content.call(arg)
          else
            raise ArgumentError, "A slot's content is a block, rack, or callable taking the signal (got #{content.class})"
          end
        end

        # The output nodes of a content's +result+.
        def self.nodes_of(result, name)
          case result
          when Array then result.flat_map { |r| nodes_of(r, name) }
          when GraphNode, MultiOutput then result.outputs
          else
            raise ArgumentError, "slot #{name.inspect}: its content must return audio (a graph node or bundle; got #{result.class})"
          end
        end

        # A short description of +content+ (built as +nodes+).
        def self.describe(content, nodes)
          if content.is_a?(MB::Sound::Rack) && content.name
            "rack #{content.name.inspect}"
          else
            text = nodes.uniq.map { |n| (n.respond_to?(:graph_node_name) ? n.graph_node_name : nil) || n.class.name.to_s.split('::').last }.uniq.join(', ')
            text.length > 40 ? "#{text[0, 37]}..." : text
          end
        end

        private

        # Plan.changed on the outputs (sources changed).
        def changed!
          @outputs&.each { |o| Plan.changed(o) }
        end

        # The first frame of this read on the Session's clock (the player's
        # first frame in the span, then on from there for reads in pieces),
        # or the slot's own count outside a Session (see
        # Knob::Reader#next_frame_for).
        def frame_for(count)
          s = @session || Session.span&.session
          c = s&.player_frame
          f = if c.nil?
                @frame || 0
              elsif c == @clock && @frame && @frame > c
                @frame
              else
                c
              end
          @clock = c
          @frame = f + count
          f
        end

        # Starts queued contents whose frame falls before +frame+ + +count+.
        def activate(frame, count)
          while (c = @pending.first) && c.start < frame + count
            @pending.shift
            offset = MB::M.max(c.start - frame, 0)
            c.started = true
            c.skip = offset > 0 ? offset : nil
            Session::Handover.start(c, @chains, offset, c.mode, c.mode == :fade ? c.fade : 1.0)
            @chains << c
            changed!
            # (documents print the content playing: see Session#swap_slot)
            rec = @result&.instance_variable_get(:@graph_recipe)
            rec.call = c.recipe if rec && c.recipe
            start_timeline(c, frame + offset)
            @session&.slot_started(self, c, offset)
          end
        end

        # Starts a new content's timeline nodes on its first frame.
        def start_timeline(c, at)
          return if c.timeline_nodes.empty?
          span = Session.span
          return unless span
          pos = span.moving ? Sequence::Transport.position_at(span.pos, at - span.frame, span.per_sample) : span.pos
          c.timeline_nodes.each { |n| n.start_at(pos, origin: pos, launch: pos, transport: span.session.transport) }
        end

        # Renders every channel for +count+ frames: an Array of buffers, or
        # nil when the input or the current content ended.
        def render(count)
          @last_count = count
          frame = frame_for(count)
          activate(frame, count) unless @pending.empty?

          ins = @in_bufs
          i = -1
          ended = false
          while (i += 1) < @inputs.length
            ins[i] = @inputs[i].sample(count)
            ended = true if ins[i].nil?
          end

          if @chains.length == 1
            c = @chains[0]
            if c.gain >= 1 && c.gain_step == 0 && c.skip.nil? && c.feeding && c.input_until.nil?
              return steady(c, ins, count)
            end
          end
          return nil if ended

          handover(ins, frame, count)
        end

        # One content at full level: the input to its feeds, its output out
        # as it is (no copies; a mono content on every channel is read once,
        # through its Tee).
        def steady(c, ins, count)
          feeds = c.source
          i = -1
          while (i += 1) < feeds.length
            feeds[i].push(ins[i])
          end
          data = @data
          data.clear
          nodes = c.nodes
          i = -1
          while (i += 1) < nodes.length
            d = nodes[i].sample(count)
            return nil if d.nil?
            data << d
          end
          data
        end

        # Several contents (or one fading or starting): each fed its part of
        # the input, mixed with its ramp, spilling tails followed and
        # dropped on their last frame.
        def handover(ins, frame, count)
          n = ins[0].length
          out = out_bufs(n)
          fed = @chains.count { |c| c.started && (c.feeding || c.input_until) }

          @chains.each do |c|
            next unless c.started
            skip = c.skip || 0
            c.skip = nil
            len = n - skip
            next if len <= 0

            c.source.each_with_index do |f, idx|
              f.push(feed_part(c, ins[idx], skip, n, fed))
            end
            data = c.nodes.map { |node|
              d = node.sample(len)
              d = d.real if d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)
              d = Numo::SFloat.cast(d) if d && !d.is_a?(Numo::SFloat)
              d
            }
            if data.any?(&:nil?)
              # (a content that ended: done)
              c.tail_done = true
              c.feeding = false
              c.gain = 0.0
              c.gain_step = -1.0
              next
            end

            mix_n = c.feeding && !c.input_until ? len : Session::Handover.track_tail(c, data, len, @sample_rate, frame + skip)
            ramp = Session::Handover.ramp(c, len, MB::M.max((c.ramp_from || 0) - skip, 0))
            data.each_with_index do |d, idx|
              next if mix_n <= 0
              o = out[idx]
              next if d.length == len && (ramp.nil? || ramp.length == len) && mix_n == len && Kernels.add_at(o, skip, d, len, ramp)
              d = d[0...mix_n] if mix_n < d.length
              d = d * (ramp.length == mix_n ? ramp : ramp[0...mix_n]) if ramp
              o[skip...(skip + mix_n)].inplace + d
            end
            c.input_from = c.input_until = c.ramp_from = nil
          end

          dropped = false
          @chains.dup.each do |c|
            next unless Session::Handover.done?(c, @chains)
            @chains.delete(c)
            dropped = true
          end
          if dropped
            changed!
            @session&.slot_dropped(self)
          end
          out
        end

        # The input +buf+ as content +c+ hears it from frame +skip+ of +n+:
        # all of it, silence after its input stopped (a spill), or silence.
        def feed_part(c, buf, skip, n, fed)
          if !c.feeding && c.input_until.nil?
            z = @scratch[c]
            z = @scratch[c] = Numo::SFloat.zeros(n - skip) if z.nil? || z.length != n - skip
            return z
          end
          part = skip > 0 ? buf[skip..].dup : buf
          if c.input_until && c.input_until < n
            part = part.dup if part.equal?(buf)
            part[MB::M.max(c.input_until - skip, 0)..] = 0
          elsif fed > 1 && part.equal?(buf)
            part = buf.dup
          end
          part
        end

        # Zeroed output buffers for +n+ frames (reused).
        def out_bufs(n)
          bufs = @out_bufs
          if bufs.nil? || bufs[0].length != n
            return @out_bufs = Array.new(@channels) { Numo::SFloat.zeros(n) }
          end
          bufs.each { |b| BufferHelper.zero(b) }
          bufs
        end
      end
    end
  end
end
