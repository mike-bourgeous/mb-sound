require_relative 'inspect'

module MB
  module Sound
    module GraphNode
      # Methods related to building and traversing node graphs.  Classes should
      # include this if they want to have #sources, #graph, #graph_edges, and
      # similar methods.
      module Traversable
        include Inspect # one-line #inspect (ux-fix-1)

        # Overridden by users of this mixin to return the inputs to the current
        # object.  For example, a Mixer will return a list of objects that are
        # added together by that mixer, as well as any constant DC offset
        # applied.
        #
        # See #graph for a method that returns every source feeding into this
        # node.
        def sources
          {}
        end

        # The node's named inputs, for introspection (e.g. a future UI): the
        # same as #sources.  Typed ports (with roles and types) are in
        # #port_info; side outputs in GraphNode::Ports#ports.
        def inputs
          sources
        end

        # The three port types (racks, design/notes/racks.md): samples
        # (:audio), values read as parameters (:control), and events at
        # exact times (:notes; MIDI streams, sources, clips).
        PORT_TYPES = [:audio, :control, :notes].freeze

        # Input names that are a node's main signal (role :main): its
        # input(s), channels, and voices.  Other names are parameters
        # (:param), except sidechains (:side); an output's edge from the
        # node that owns it (a Synth's Output, a Tee's Branch) is :main
        # whatever its name.
        MAIN_INPUT = /\A(input|in|sig|signal|source|stream|body|channel|voice|owner|inputs|allocator|parent|sources)(_\d+)*\z/

        # Side inputs (role :side).
        SIDE_INPUT = /\A(side|sidechain)(_\d+)*\z/

        # The type of what this object outputs: :audio for graph nodes,
        # :notes for MIDI streams, sources, and transforms, :control for
        # constants, knobs, and note-derived values (see PORT_TYPES).  An
        # audio node read as a parameter is a :control edge (#port_info).
        def port_type
          :audio
        end

        # The role of input +name+ (a key of #sources): :main, :side, or
        # :param (overridden by nodes whose inputs are named otherwise).
        def port_role(name)
          n = name.to_s
          return :side if n.match?(SIDE_INPUT)
          return :main if n.match?(MAIN_INPUT)
          :param
        end

        # True if input +name+ is being read (overridden by nodes that skip
        # inputs, e.g. while muted).
        def port_active?(name)
          true
        end

        # Typed ports for inspection (the racks project's protocol;
        # design/notes/racks.md):
        #
        #     {
        #       in: [{ name:, type: :audio/:control/:notes, role: :main/:side/:param/:feedback, source:, active: }, ...],
        #       out: [{ name:, type: }, ...],
        #     }
        #
        # Built from #sources (parameters are :control edges, whatever
        # feeds them), #feedback_sources (role :feedback), and the
        # outputs; nodes with side outputs add them (GraphNode::Ports).
        # #sources and #inputs keep their return values.
        def port_info
          { in: input_port_info, out: output_port_info }
        end

        # The :in part of #port_info.
        def input_port_info
          list = sources.map { |name, src|
            role = Traversable.owner_edge?(self, src) ? :main : port_role(name)
            Traversable.port_entry(self, name, src, role)
          }
          list + feedback_sources.map { |name, src| Traversable.port_entry(self, name, src, :feedback) }
        end

        # The :out part of #port_info: one entry per output (:out for a
        # single output, :out_1, :out_2, ... for several).
        def output_port_info
          outs = respond_to?(:outputs) ? Array(outputs.to_a) : [self]
          return [{ name: :out, type: port_type }] if outs.length <= 1

          outs.each_with_index.map { |o, idx|
            { name: :"out_#{idx + 1}", type: o.equal?(self) ? port_type : Traversable.port_type_of(o) }
          }
        end

        # The output port type of any graph value: Traversable objects say
        # (#port_type); numbers are :control; Clips, Notes, and Seqs are
        # :notes; anything else :audio.
        def self.port_type_of(obj)
          case obj
          when Traversable then obj.port_type
          when Numeric then :control
          when MB::Sound::Notes, MB::Sound::Sequence::Clip, MB::Sound::Sequence::Seq then :notes
          else :audio
          end
        end

        # The node's parameters by name: its :param inputs (see #port_info),
        # as numbers for constants and as the nodes given otherwise (a knob
        # reader, an LFO).  Nodes with a parameter API of their own
        # override it (ChannelMixer).  See #param_info for ranges and units.
        def params
          sources.each_with_object({}) do |(name, src), h|
            next unless port_role(name) == :param && !Traversable.owner_edge?(self, src)
            src = GraphNode.climb_tee_tree(src)
            h[name] = src.is_a?(Constant) ? src.constant : src
          end
        end

        # #params as frozen values for painters and other threads: a frozen
        # Hash { name => ParamValue }.  Each ParamValue is deep-frozen
        # (Ractor-shareable): +value+ is the number for constants and knobs
        # (their current value) and nil for parameters fed by other nodes
        # (+detail+ names the node), +type+ the edge type (:control, or
        # :notes), +unit+/+range+ where known (Constants, knobs, declared
        # ChannelMixer params), +label+ a knob's name.  Reads settings only
        # (never samples, no render lock), so a poll thread may call it.
        def param_info
          info = sources.each_with_object({}) do |(name, src), h|
            next unless port_role(name) == :param && !Traversable.owner_edge?(self, src)
            h[name] = Traversable.describe_param(src, param_range(name))
          end
          info.freeze
        end

        # Everything a panel needs to draw this node at rest, as one frozen
        # value (see Params): its class, name, #param_info, and
        # #preview_data.  Safe to take from a poll thread; previews are a
        # pure function of it (Plot::Panels.preview).
        def param_snapshot
          name = respond_to?(:named?) && named? ? graph_node_name.to_s.dup.freeze : nil
          Params.new(node_class: self.class, name: name, values: param_info, preview: Ractor.make_shareable(preview_data))
        end

        # Settings a panel preview needs beyond #param_info (a filter's type
        # and sample rate, a shaper's mode), as a Hash of plain values, or
        # nil (the default).  Deep-frozen by #param_snapshot.
        def preview_data
          nil
        end

        # The range of parameter +name+, if the node knows it (nil by
        # default).
        def param_range(name)
          nil
        end

        # Draws a picture of the node at rest that only the node can compute
        # (a filter's response, a shaper's transfer curve) onto +chart+ (a
        # Plot::ChartBuilder), returning the chart, or nil if the node has
        # none.  A convenience for Plot::Panels.preview(self.class,
        # param_snapshot, chart), which is a pure function of the frozen
        # snapshot (painters call that with a snapshot taken on a poll
        # thread).  See Plot.preview.
        def plot_preview(chart)
          MB::Sound::Plot::Panels.preview(self.class, param_snapshot, chart)
        end

        # One parameter of #param_info (deep-frozen; see there).
        ParamValue = Data.define(:value, :type, :unit, :range, :label, :detail)

        # A node's frozen parameter snapshot (#param_snapshot): its class,
        # name String (nil if unnamed), #param_info Hash, and #preview_data (frozen Hash or
        # nil).
        Params = Data.define(:node_class, :name, :values, :preview) do
          # The numeric value of parameter +name+ (nil if a node drives it).
          def [](name)
            values[name]&.value
          end
        end

        # One #param_info entry for value +v+ (frozen).
        def self.describe_param(v, range = nil)
          range = range&.frozen? ? range : range&.dup&.freeze
          f = ->(x) { x.is_a?(String) ? x.dup.freeze : x }
          v = GraphNode.climb_tee_tree(v) # a node shared through a Tee: the node itself
          case v
          when Numeric
            ParamValue.new(value: v, type: :control, unit: nil, range: range, label: nil, detail: nil)
          when Constant
            ParamValue.new(value: v.constant, type: :control, unit: f.(v.unit), range: range || v.range, label: nil, detail: nil)
          when Knob::Reader, Knob
            k = v.is_a?(Knob::Reader) ? v.knob : v
            ParamValue.new(value: k.value, type: :control, unit: f.(k.spec.unit), range: range || k.spec.range, label: k.name, detail: k.to_s.dup.freeze)
          else
            type = port_type_of(v)
            ParamValue.new(value: nil, type: type == :notes ? :notes : :control, unit: nil, range: range,
              label: v.respond_to?(:named?) && v.named? ? v.graph_node_name.to_s.dup.freeze : nil, detail: words_of(v).dup.freeze)
          end
        end

        # Short DSL words for node +v+ (a param's input, as the sound
        # panes show it: "knob cut × lfo", "notes frequency", "2 bars
        # jumps"): its name, a knob, a number, products and sums one level
        # deep, its recipe's method name or a tone's wave, else its type
        # name in lower-case words; never a class name (omnibus15).
        def self.words_of(v, depth = 1)
          v = GraphNode.climb_tee_tree(v)
          case v
          when Numeric then MB::M.sigfigs(v.to_f, 3).to_s
          when Constant then MB::M.sigfigs(v.constant.to_f, 3).to_s
          when Knob::Reader then "knob #{v.knob.name}"
          when Knob then "knob #{v.name}"
          else
            # (`2 ** lfo`, `x / 3`: the operands' words, never the node ids
            # of their generated names; sound-design-nav-1)
            if v.is_a?(ProcNode) && %w[** /].include?(v.plan_operator) && v.sources.key?(:operand) && v.graph_node_name.to_s.include?('id=')
              a, b = v.sources.values_at(:input, :operand)
              return depth > 0 ? "#{words_of(a, depth - 1)} #{v.plan_operator} #{words_of(b, depth - 1)}" : (v.plan_operator == '**' ? 'a power' : 'a quotient')
            end
            return v.graph_node_name.to_s if v.respond_to?(:named?) && v.named?
            if depth > 0 && (v.is_a?(Multiplier) || v.is_a?(Mixer))
              parts = (v.is_a?(Multiplier) ? v.multiplicands : v.summands).map { |m| words_of(m, depth - 1) }
              c = v.constant
              parts.unshift(MB::M.sigfigs(c.to_f, 3).to_s) if c.is_a?(Numeric) && c != (v.is_a?(Multiplier) ? 1 : 0)
              return parts.join(v.is_a?(Multiplier) ? ' × ' : ' + ')
            end
            rec = v.instance_variable_defined?(:@graph_recipe) ? v.instance_variable_get(:@graph_recipe) : nil
            name = rec.respond_to?(:call) && rec.call.respond_to?(:name) ? rec.call.name : nil
            name = nil if name && !name.to_s.match?(/\A[a-z_]/) # (operators: their words below)
            name ||= v.wave_type if v.is_a?(MB::Sound::Tone)
            return name.to_s if name

            t = v.respond_to?(:node_type_name) ? v.node_type_name.to_s : ''
            t = v.to_s.split('/', 2).last.to_s if t.match?(/\A(Port|Tempo Hz)\z/) # (a timeline port: "2 bars.jumps")
            t = t.tr('.', ' ').gsub(/([a-z\d])([A-Z])/, '\\1 \\2').downcase
            t.empty? ? 'a node' : t
          end
        end

        # True if +src+ is the multi-output node that +node+ is an output of.
        def self.owner_edge?(node, src)
          return false if src.equal?(node) || src.is_a?(Numeric) || !src.respond_to?(:outputs)
          outs = src.outputs
          outs.respond_to?(:any?) && outs.any? { |o| o.equal?(node) }
        rescue NotImplementedError
          false
        end

        # One :in entry of #port_info for +node+'s input +name+ fed by
        # +src+ with +role+.
        def self.port_entry(node, name, src, role)
          src_type = port_type_of(src)
          type =
            if src_type == :notes
              :notes
            elsif role == :param || role == :feedback && src_type == :control
              :control
            else
              src_type
            end
          { name: name, type: type, role: role, source: src, active: node.port_active?(name) }
        end

        # Returns a Hash with backward-pointing sources.  Keys are source names,
        # values are source nodes.  These sources are not used when building or
        # ordering the node #graph or #graph_ranks.
        #
        # TODO: this is progress, but we still need a better way of representing
        # feedback in a node graph.
        def feedback_sources
          @feedback_sources ||= {}.freeze
        end

        # Merges the Hash of +sources+ to the feedback source list, replacing any
        # sources of the same name.  Keys are source names, values are source
        # nodes.
        def with_feedback(sources)
          @feedback_sources ||= {}
          @feedback_sources = @feedback_sources.merge(sources).freeze
          self
        end

        # Returns an Array with the port name and source name or object ID (if
        # no name) of all sources for this node, for use in generating
        # descriptions of the node.
        def source_names
          sources.map { |name, src| "#{name}: #{make_source_name(src)}" }
        end

        # Returns a list of all nodes feeding into this node, either directly or
        # indirectly, plus this node itself, without duplication.  Also may
        # include numeric values used as parameters to some of the nodes.
        #
        # Entries in the returned list should be in order of increasing distance
        # from this node, but if there are loops in the graph this is not
        # guaranteed.
        def graph(include_tees: true)
          MB::Sound::GraphNode.graph(self, include_tees: include_tees)
        end

        # Returns a Hash from source node to a Set of destination node/port name
        # tuples describing all connections upstream of this graph node.
        #
        # If +:feedback+ is true, then only backward-pointing feedback edges are
        # returned.  If false, then only normal edges are returned.
        #
        # Example output shape:
        #     {
        #       Constant => Set.new([[Tone, :frequency]])
        #       Tone => Set.new([[Filter, :cutoff], [Filter, :quality]])
        #     }
        def graph_edges(include_tees: true, feedback: false)
          edges = {}

          graph(include_tees: include_tees).each do |dest|
            if feedback
              next unless dest.respond_to?(:feedback_sources)
            else
              next unless dest.respond_to?(:sources)
            end

            list = feedback ? dest.feedback_sources : dest.sources

            list.each do |name, s|
              s = s.round if s.is_a?(Numeric) && s.respond_to?(:round) && s.round == s

              unless include_tees
                s = MB::Sound::GraphNode.climb_tee_tree(s)
              end

              edges[s] ||= Set.new
              edges[s] << [dest, name]
            end
          end

          edges
        end

        # Separates the graph into ranks (in GraphViz terms) based on distance
        # from this node.  Ignores Numeric sources in the graph.  Returns an
        # Array of Arrays of nodes.
        def graph_ranks(include_tees: true)
          MB::Sound::GraphNode.graph_ranks(self, include_tees: include_tees)
        end

        # Looks for the first source node within the graph feeding into this node
        # with the given name.
        def find_by_name(name)
          graph.find { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
        end

        # Returns all nodes within this nodes input graph matching the given
        # name.
        def find_all_by_name(name)
          graph.select { |s| s.respond_to?(:graph_node_name) && s.graph_node_name == name }
        end

        # Returns a String containing a GraphViz representation of the signal
        # graph.
        #
        # Nodes made by one per-channel DSL call on a multichannel signal
        # (e.g. `stereo.filter(:lowpass, cutoff: channels(800, 1200))`) are
        # drawn as one box listing the arguments that differ per channel,
        # unless +:expand_channels+ is true.  See ChannelDispatch.
        def graphviz(include_tees: false, expand_channels: false)
          nodes = graph(include_tees: include_tees)
          boxes = expand_channels ? {}.compare_by_identity : Traversable.channel_boxes(nodes, include_tees)
          id = ->(n) { (g = boxes[n]) ? "channels #{g.__id__}" : n.__id__.to_s }

          digraph = +"digraph {\n"

          digraph << "  graph [ bgcolor=\"#000000e0\" rankdir=\"LR\" pad=\"0.25\" ];\n"
          digraph << "  node [ style=\"filled\" fontcolor=\"#ffffff\" color=\"#2266ee\" shape=\"Mrecord\" ];\n"
          digraph << "  edge [ fontcolor=\"#ffffff\" color=\"#ffffff\" headport=\"w\" tailport=\"e\" ];\n"

          # Add nodes
          nodes.each do |node|
            next if node.is_a?(Numeric) || boxes[node]
            desc = node.respond_to?(:to_s_graphviz) ? node.to_s_graphviz : node.to_s
            digraph << "  #{node.__id__.to_s.inspect} [label=#{desc.inspect}]\n"
          end

          # Add one node per group of per-channel nodes
          boxes.values.uniq(&:__id__).each do |g|
            digraph << "  #{id.(g.members[0]).inspect} [label=#{g.label.inspect}, color=\"#2288aa\"];\n"
          end

          lines = Set.new

          # Add forward edges
          graph_edges(include_tees: include_tees).each do |src, edges|
            edges.each do |dest, name|
              # TODO: add ports to nodes instead of labeling edges
              if src.is_a?(Numeric)
                # Include a separate numeric source node for each destination
                srcname = "#{src.inspect} to #{id.(dest)}/#{name}"
                lines << "  #{srcname.inspect} [label=#{src.to_s.inspect}];\n"
                lines << "  #{srcname.inspect} -> #{id.(dest).inspect} [label=#{name.to_s.inspect}];\n"
              else
                next if id.(src) == id.(dest)
                lines << "  #{id.(src).inspect} -> #{id.(dest).inspect} [label=#{name.to_s.inspect}];\n"
              end
            end
          end

          # Add feedback edges
          graph_edges(include_tees: include_tees, feedback: true).each do |src, edges|
            edges.each do |dest, name|
              lines << "  #{id.(src).inspect} -> #{id.(dest).inspect} [label=#{name.to_s.inspect}, color=red, constraint=false];\n"
            end
          end

          digraph << lines.to_a.join
          digraph << "}\n"

          digraph
        end

        # Returns a Hash (compared by identity) from each node in +nodes+
        # that belongs to a per-channel DSL call to that call's ChannelGroup:
        # the nodes the call returned plus the nodes it created upstream of
        # them, but not the channels it ran on or nodes passed as arguments.
        def self.channel_boxes(nodes, include_tees)
          boxes = {}.compare_by_identity
          groups = nodes.filter_map { |n| n.respond_to?(:channel_group) && n.channel_group }.uniq(&:__id__)

          groups.each do |g|
            outside = Set.new.compare_by_identity
            (g.inputs + g.arg_nodes).each do |n|
              outside << n
              n.graph(include_tees: include_tees).each { |u| outside << u } if n.respond_to?(:graph)
            end

            g.members.each do |m|
              ([m] + m.graph(include_tees: include_tees)).each do |n|
                next if n.is_a?(Numeric) || outside.include?(n)
                boxes[n] ||= g
              end
            end
          end

          boxes
        end

        # Saves a GraphViz representation of the graph to a temporary file,
        # generates a PNG using dot, and opens the PNG using open.  The PNG file
        # is left behind after the program exits for inspection.
        def open_graphviz(include_tees: false, expand_channels: false)
          dot = Tempfile.create([self.to_s.gsub(/[^A-Za-z0-9_-]+/, '_')[0, 40], '.dot'])

          png = "#{dot.path}.png"
          File.write(dot, self.graphviz(include_tees: include_tees, expand_channels: expand_channels))
          system("dot -Tpng:cairo #{dot.path.shellescape} -o #{png.shellescape}")
          system("open #{png.shellescape}")

          png
        end
      end
    end
  end
end
