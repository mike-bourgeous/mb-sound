module MB
  module Sound
    module UI
      # The patch inspector's data (sound-design-ui-1; design in
      # design/notes/sound_design_ui.md): what one track's graph reads and
      # is made of, gathered by Poll on the painter thread while a pane
      # needs :inspect, from Session#ui_graphs (the players' mutex, never
      # the render lock) and Traversable's settings readers (#param_info,
      # #param_snapshot, #to_ruby: no sampling).  Frozen plain data, so
      # the inspector, preview, and code panes draw without the graph.
      #
      # The panes choose what to inspect through .target (painter thread:
      # the same thread that polls and draws).
      module Inspect
        # One node of the inspected graph worth showing: +key+ its index
        # in InspectInfo#nodes, +label+ what made it (the DSL method name
        # from its recipe, else its node name or class), +kind+ the class's
        # short name, +count+ how many copies the graph has (synth lanes,
        # unison copies with the same settings), +params+ its frozen
        # Traversable::Params (#param_snapshot), +preview+ true when
        # Plot::Panels draws one for it, +knobs+ the knob names its params
        # read (Symbols).
        NodeInfo = Data.define(:key, :label, :kind, :count, :params, :preview, :knobs)

        # What the inspector shows of one track: +track+ (the player name,
        # nil when nothing plays), +tracks+ (players with graphs, in the
        # order the inspector cycles them), +knobs+ (the knob names the
        # graph reads, in graph order: these are what turns), +nodes+
        # (NodeInfos: knob readers first, then nodes with previews, then
        # the rest), +node+ (the selected node's index, or nil), +code+ (the
        # graph's Ruby, `to_ruby` of its roots, or nil), +error+ (why the
        # graph couldn't be read, or nil).
        InspectInfo = Data.define(:track, :tracks, :knobs, :nodes, :node, :code, :error) do
          # The selected NodeInfo, or nil.
          def selected = node && nodes[node]
        end

        # Node classes never listed (plumbing: their settings are other
        # nodes' params).  Matched by class name so the list needs no
        # requires.
        SKIP = %w[
          MB::Sound::GraphNode::Constant MB::Sound::GraphNode::Knob MB::Sound::GraphNode::Knob::Reader
          MB::Sound::GraphNode::Tee MB::Sound::GraphNode::Tee::Branch MB::Sound::GraphNode::Multiplier
          MB::Sound::GraphNode::Mixer MB::Sound::GraphNode::ProcNode MB::Sound::Notes::Frequency
          MB::Sound::Synth::Output MB::Sound::GraphNodeInput
        ].freeze

        # Nodes listed at most (a big graph's tail is left out).
        MAX_NODES = 40

        class << self
          # What the inspector panes asked for: a Hash with +track:+ (a
          # player name or nil: the clip matrix's track, else the first)
          # and +node:+ (an index or nil: the first node with a preview),
          # set by the inspector pane's keys on the painter thread.
          attr_accessor :target
        end

        # Gathers InspectInfos, keeping what only changes when the graph
        # does (the node list and the code) per graph.
        class Gatherer
          def initialize
            @cache = {}
          end

          # The InspectInfo for +session+'s track +target+ asks for (see
          # Inspect.target), or nil without a session.  Never raises: a
          # graph that can't be read (one changing as it is walked) keeps
          # the last info for that track with +error+ set.
          def call(session, target = Inspect.target)
            target ||= {}
            graphs = session.respond_to?(:ui_graphs) ? session.ui_graphs : {}
            tracks = graphs.keys.reject { |n| n.to_s.end_with?('/live') }.freeze
            track = pick_track(target[:track], tracks)
            return InspectInfo.new(track: nil, tracks: tracks, knobs: [].freeze, nodes: [].freeze, node: nil, code: nil, error: nil) unless track

            roots = Inspect.roots(graphs[track])
            entry = @cache[track]
            unless entry && entry[:roots].length == roots.length && entry[:roots].zip(roots).all? { |a, b| a.equal?(b) }
              entry = @cache[track] = { roots: roots, **Inspect.walk(roots) }
            end
            @cache.select! { |k, _| graphs.key?(k) }

            nodes = entry[:nodes]
            sel = target[:node]
            sel = nodes.index(&:preview) || (nodes.empty? ? nil : 0) if sel.nil?
            sel = sel.clamp(0, nodes.length - 1) if sel && !nodes.empty?
            sel = nil if nodes.empty?
            # (the selected node's snapshot again: its knob-driven values
            # and preview follow turns; the others keep their first one)
            if sel && (n = entry[:objects][sel])
              nodes = nodes.dup
              nodes[sel] = nodes[sel].with(params: Inspect.snapshot(n))
              nodes.freeze
            end
            InspectInfo.new(track: track, tracks: tracks, knobs: entry[:knobs], nodes: nodes, node: sel, code: entry[:code], error: nil)
          rescue StandardError => e
            info = InspectInfo.new(track: track, tracks: tracks || [].freeze, knobs: entry&.[](:knobs) || [].freeze, nodes: entry&.[](:nodes) || [].freeze,
                                   node: nil, code: entry&.[](:code), error: "#{e.class}: #{e.message}".freeze)
            info
          end

          private

          def pick_track(want, tracks)
            return want if want && tracks.include?(want)
            sel = Panes::Clips.selected&.first if defined?(Panes::Clips)
            return sel if sel && tracks.include?(sel)
            tracks.first
          end
        end

        module_function

        # The graphs a player's input renders: through Tees to the nodes
        # themselves, and from a multi-output node's outputs to the node
        # that has the recipe (a Synth's outputs to the Synth), without
        # duplicates.
        def roots(input)
          nodes = input.respond_to?(:nodes) ? input.nodes : [input]
          nodes.map { |n| root_of(n) }.uniq(&:object_id)
        end

        # +node+'s node with a recipe (see .roots).
        def root_of(node)
          n = GraphNode.climb_tee_tree(node)
          8.times do
            break if recipe?(n)
            owner = n.respond_to?(:sources) && n.sources.values.find { |s| GraphNode::Traversable.owner_edge?(n, s) }
            break unless owner
            n = GraphNode.climb_tee_tree(owner)
          end
          n
        end

        def recipe?(n) = n.instance_variable_defined?(:@graph_recipe) && !n.instance_variable_get(:@graph_recipe).nil?

        # The node list, knob names, and code of graph +roots+ (see
        # InspectInfo): { nodes:, objects:, knobs:, code: }.
        def walk(roots)
          all = roots.flat_map { |r| r.respond_to?(:graph) ? r.graph : [r] }.uniq(&:object_id)
          knobs = []
          all.each do |n|
            k = n.is_a?(GraphNode::Knob::Reader) ? n.knob : n.is_a?(GraphNode::Knob) ? n : nil
            knobs << k.name if k&.name && !knobs.include?(k.name)
          end

          groups = {}
          all.each do |n|
            next if n.is_a?(Numeric) || !n.respond_to?(:param_info)
            next if SKIP.include?(n.class.name)
            info = n.param_info
            next if info.empty? && !preview?(n)
            sig = [n.class, info.map { |name, v| [name, v.value, v.label] }]
            (groups[sig] ||= []) << n
          end
          rows = groups.values.map { |list|
            n = list.first
            snap = Inspect.snapshot(n)
            read = Inspect.knobs_read(n).freeze
            preview = preview?(n)
            [n, list.length, snap, read, preview]
          }
          rows = rows.sort_by.with_index { |(_, _, _, read, preview), i| [read.empty? ? (preview ? 1 : 2) : 0, i] }.first(MAX_NODES)
          nodes = rows.each_with_index.map { |(n, count, snap, read, preview), i|
            NodeInfo.new(key: i, label: label_of(n), kind: n.class.name.split('::').last.freeze, count: count, params: snap, preview: preview, knobs: read)
          }.freeze

          code = roots.filter_map { |r| r.respond_to?(:to_ruby) ? (r.to_ruby rescue nil) : nil }.uniq.join("\n").freeze
          { nodes: nodes, objects: rows.map(&:first).freeze, knobs: knobs.freeze, code: code.empty? ? nil : code }
        end

        # True if Plot::Panels draws a preview for +node+'s class.
        def preview?(node)
          node.class.ancestors.any? { |a| a.name && Plot::Panels.registered.include?(a.name) }
        end

        # +node+'s frozen Traversable::Params (#param_snapshot; nodes with a
        # parameter API of their own that lack it get one from
        # #param_info).
        def snapshot(node)
          return node.param_snapshot if node.respond_to?(:param_snapshot)
          GraphNode::Traversable::Params.new(node_class: node.class, name: nil, values: node.param_info, preview: nil)
        end

        # The knob names +node+'s params read: directly, or through a few
        # nodes of arithmetic (`lp4(knob(:cut) * lfo)` reads :cut).
        def knobs_read(node, depth: 3)
          out = []
          node.params.each_value do |src|
            next if src.is_a?(Numeric)
            frontier = [src]
            depth.times do
              nxt = []
              frontier.each do |s|
                s = GraphNode.climb_tee_tree(s)
                k = s.is_a?(GraphNode::Knob::Reader) ? s.knob : s.is_a?(GraphNode::Knob) ? s : nil
                if k
                  out << k.name if k.name && !out.include?(k.name)
                  next
                end
                nxt.concat(s.sources.values.reject { |v| v.is_a?(Numeric) }) if s.respond_to?(:sources)
              end
              frontier = nxt
              break if frontier.empty?
            end
          end
          out
        end

        # Labels for nodes built inside blocks without recipes of their
        # own (synth lanes), by class name.
        CLASS_LABELS = {
          'FourPole' => 'lp4', 'DiodeLadder' => 'diode', 'NoteEnvelope' => 'env', 'Envelope' => 'env', 'Unison' => 'unison',
          'Reverb' => 'reverb', 'Chorus' => 'chorus', 'Dynamics' => 'dynamics', 'Limiter' => 'limit', 'Formant' => 'formant',
        }.freeze

        # What made +node+: its node name, else what its preview says it is
        # (a filter's type, a shaper's mode), else its recipe's method name
        # (lp4, softclip), a tone's wave, or CLASS_LABELS, else its class's
        # short name.
        def label_of(node)
          return node.graph_node_name.to_s.freeze if node.respond_to?(:named?) && node.named?
          d = node.respond_to?(:preview_data) ? (node.preview_data rescue nil) : nil
          return d[:filter_type].to_s.freeze if d.is_a?(Hash) && d[:filter_type]
          return d[:mode].to_s.freeze if d.is_a?(Hash) && d[:mode]
          rec = node.instance_variable_defined?(:@graph_recipe) ? node.instance_variable_get(:@graph_recipe) : nil
          name = rec.respond_to?(:call) && rec.call.respond_to?(:name) ? rec.call.name : nil
          name ||= node.wave_type if node.respond_to?(:wave_type)
          short = node.class.name.split('::').last
          (name || CLASS_LABELS[short] || short).to_s.freeze
        end
      end
    end
  end
end
