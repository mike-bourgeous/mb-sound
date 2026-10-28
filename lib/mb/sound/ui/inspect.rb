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
        # from its recipe, else its node name; never a class name), +role+
        # what it is for in a patch ('osc', 'filter', 'env', ...; see
        # .role_of; nil when nothing fits), +count+ how many copies the graph has (synth lanes,
        # unison copies with the same settings), +params+ its frozen
        # Traversable::Params (#param_snapshot), +preview+ true when
        # Plot::Panels draws one for it, +knobs+ the knob names its params
        # read (Symbols), +live+ what a preview shows beyond the settings
        # (an envelope's sounding note: see .live_of; nil otherwise),
        # +binds+ (the selected node's; else empty) its params that no knob
        # drives, as { param => Bind }: live literals.
        NodeInfo = Data.define(:key, :label, :role, :count, :params, :preview, :knobs, :live, :binds) do
          def initialize(key:, label:, role:, count:, params:, preview:, knobs:, live: nil, binds: {}.freeze)
            super
          end
        end

        # How a param no knob drives can be made one (live literals,
        # Arrangement::LiteralBinding): the console +line+ that binds it
        # (`bind :bass, lp4: :resonance`) and the +knob+ it makes, or nil
        # and the +reason+ it can't (not a number, a graph track, ...).
        Bind = Data.define(:line, :knob, :reason)

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
          MB::Sound::Synth::Output MB::Sound::GraphNodeInput MB::Sound::Notes::NoteEnvelope::GmTime
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
            @peaks = {} # (the last sounding note's peak per envelope group, by the group's first node)
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
              nodes[sel] = nodes[sel].with(params: Inspect.snapshot(n), live: live_of(entry[:groups][sel]), binds: binds_of(session, track, entry, sel, n))
              nodes.freeze
            end
            InspectInfo.new(track: track, tracks: tracks, knobs: entry[:knobs], nodes: nodes, node: sel, code: entry[:code], error: nil)
          rescue StandardError => e
            info = InspectInfo.new(track: track, tracks: tracks || [].freeze, knobs: entry&.[](:knobs) || [].freeze, nodes: entry&.[](:nodes) || [].freeze,
                                   node: nil, code: entry&.[](:code), error: "#{e.class}: #{e.message}".freeze)
            info
          end

          private

          # The Binds of node +n+ (index +sel+ of +entry+'s graph) of track
          # +track+ (kept per graph: literals change only when it is built
          # again): every param with a number and no knob.
          def binds_of(session, track, entry, sel, n)
            (entry[:binds] ||= {})[sel] ||= begin
              lb = Arrangement::LiteralBinding
              tr = session.respond_to?(:arrangement) ? session.arrangement.tracks[track] : nil
              all = tr&.patch? ? (entry[:all] ||= lb.nodes(entry[:roots])) : nil
              Inspect.snapshot(n).values.each_with_object({}) { |(name, v), h|
                next if v.label.is_a?(Symbol) || !v.value.is_a?(Numeric)
                h[name] =
                  if !tr&.patch?
                    Bind.new(line: nil, knob: nil, reason: "#{track} plays a graph, not a patch: nothing to rebuild".freeze)
                  else
                    begin
                      t = lb.target(entry[:roots], n, name, all: all)
                      Bind.new(line: lb.line(track, t).freeze, knob: lb.knob_name(track, t.param), reason: nil)
                    rescue StandardError => e
                      Bind.new(line: nil, knob: nil, reason: (e.is_a?(lb::Error) ? e.message : "#{e.class}: #{e.message}").dup.freeze)
                    end
                  end
              }.freeze
            end
          end

          # The playhead of an envelope group's newest sounding note (see
          # Inspect.live_of), keeping the last note's peak after it ends.
          def live_of(group)
            return nil unless group&.first.respond_to?(:playhead_state)
            key = group.first.__id__
            live = Inspect.live_of(group)
            @peaks.shift while @peaks.length > 64
            if live
              @peaks[key] = live[:peak]
              live
            elsif (peak = @peaks[key])
              { stage: :idle, peak: peak }.freeze
            end
          end

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
            lits = literal_params(n, info)
            info = info.merge(lits) unless lits.empty?
            next if info.empty? && !preview?(n)
            # (copies with the same settings are one row; settings only a
            # preview reads tell apart, e.g. an amp and a filter envelope)
            sig = [n.class, info.map { |name, v| [name, v.value, v.label] }, preview?(n) ? (n.preview_data rescue nil) : nil]
            (groups[sig] ||= []) << n
          end
          rows = groups.values.map { |list|
            n = list.first
            snap = Inspect.snapshot(n)
            read = Inspect.knobs_read(n).freeze
            preview = preview?(n)
            [n, list.length, snap, read, preview, list.freeze]
          }
          rows = rows.sort_by.with_index { |(_, _, _, read, preview), i| [read.empty? ? (preview ? 1 : 2) : 0, i] }.first(MAX_NODES)
          nodes = rows.each_with_index.map { |(n, count, snap, read, preview, _), i|
            label = label_of(n)
            NodeInfo.new(key: i, label: label, role: role_of(n, label), count: count, params: snap, preview: preview, knobs: read)
          }.freeze

          code = roots.filter_map { |r| r.respond_to?(:to_ruby) ? (r.to_ruby rescue nil) : nil }.uniq.join("\n").freeze
          { nodes: nodes, objects: rows.map(&:first).freeze, groups: rows.map(&:last).freeze, knobs: knobs.freeze, code: code.empty? ? nil : code }
        end

        # Where the newest sounding note of an envelope +group+ (the copies
        # of one envelope: synth lanes) is, as a frozen Hash for
        # Plot::Panels::EnvelopeView (+:stage+ :segment or :sustain,
        # +:segment+, +:position+ seconds into it, +:peak+, +:at+ the
        # monotonic clock when read, for painters to move it on), or nil
        # when none sounds.  Reads each envelope's state as the render
        # thread left it (Envelope#playhead_state), never the render lock.
        def live_of(group)
          best = nil
          group.each do |e|
            stage, seg, pos, since, peak, rate = e.playhead_state
            next unless stage == :segment || stage == :sustain
            best = [since, stage, seg, pos / rate, peak] if best.nil? || since < best[0]
          end
          return nil unless best
          { stage: best[1], segment: best[2], position: best[3], peak: best[4], at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }.freeze
        end

        # True if Plot::Panels draws a preview for +node+'s class.
        def preview?(node)
          node.class.ancestors.any? { |a| a.name && Plot::Panels.registered.include?(a.name) }
        end

        # +node+'s frozen Traversable::Params (#param_snapshot; nodes with a
        # parameter API of their own that lack it get one from
        # #param_info).
        #
        # The numbers the node's recorded call was given that #param_info
        # doesn't list (a filter's `resonance: 0.25` kept as a Float) are
        # added as params (detail "literal"), so the inspector shows them
        # and can bind them (Arrangement::LiteralBinding).
        def snapshot(node)
          snap = node.respond_to?(:param_snapshot) ? node.param_snapshot : GraphNode::Traversable::Params.new(node_class: node.class, name: nil, values: node.param_info, preview: nil)
          lits = literal_params(node, snap.values)
          lits.empty? ? snap : snap.with(values: snap.values.merge(lits).freeze)
        end

        # The literal arguments of +node+'s recorded call missing from
        # +values+ (see .snapshot), as { name => ParamValue }.
        def literal_params(node, values)
          lb = Arrangement::LiteralBinding
          call = lb.call_of(node) or return {}
          names = lb.positional_names(call) || []
          found = call.args.each_with_index.filter_map { |v, i| names[i] && [names[i], v] } + call.kwargs.to_a
          found.each_with_object({}) { |(name, v), h|
            next unless name.is_a?(Symbol) && !values.key?(name) && lb.literal?(v)
            num, unit =
              case v
              when Pitch then [v.frequency.to_f, 'Hz']
              when Length::Seconds then [Length.seconds(v).to_f, 's']
              when Length::Samples then [v.value, 'samples']
              else [v.is_a?(Integer) ? v : v.to_f, nil]
              end
            h[name] = GraphNode::Traversable::ParamValue.new(value: num, type: :control, unit: unit&.freeze, range: nil, label: nil, detail: LITERAL)
          }
        rescue StandardError
          {}
        end

        # The detail of a literal param (see .literal_params).
        LITERAL = 'literal'.freeze

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
          'SampleWrapper' => 'filter', 'Decimator' => 'decimate', 'ModalResonator' => 'resonate', 'Resonator' => 'ping',
        }.freeze

        # Roles by class (the first of a node's ancestors listed here), for
        # the inspector's node rows: what a node is for, in the words of
        # the DSL rather than its class (maintainer, 2026-10-28: "it
        # shouldn't mention SampleWrapper").
        ROLES = {
          'MB::Sound::Tone' => 'osc', 'MB::Sound::GraphNode::Wavetable' => 'osc',
          'MB::Sound::GraphNode::SamplerVoice' => 'osc', 'MB::Sound::GraphNode::Grains' => 'osc',
          'MB::Sound::Filter::SampleWrapper' => 'filter', 'MB::Sound::GraphNode::FourPole' => 'filter',
          'MB::Sound::GraphNode::Formant' => 'filter', 'MB::Sound::GraphNode::Resonator' => 'filter',
          'MB::Sound::Envelope' => 'env',
          'MB::Sound::GraphNode::Shaper' => 'shaper', 'MB::Sound::GraphNode::Decimator' => 'lofi',
          'MB::Sound::GraphNode::Reverb' => 'fx', 'MB::Sound::GraphNode::Chorus' => 'fx', 'MB::Sound::GraphNode::FeedbackLoop' => 'fx',
          'MB::Sound::GraphNode::Dynamics' => 'dynamics',
          'MB::Sound::Synth' => 'voices',
          'MB::Sound::GraphNode::ChannelMixer' => 'mix', 'MB::Sound::GraphNode::ChannelMixer::Output' => 'mix', 'MB::Sound::GraphNode::Mixer' => 'mix', 'MB::Sound::GraphNode::Multiplier' => 'mix',
          'MB::Sound::GraphNode::Knob' => 'control', 'MB::Sound::GraphNode::Knob::Reader' => 'control', 'MB::Sound::GraphNode::Constant' => 'control',
          'MB::Sound::Notes::Node' => 'control', 'MB::Sound::GraphNode::Drift' => 'mod', 'MB::Sound::GraphNode::Dust' => 'mod',
        }.freeze

        # Labels of filter-shaped nodes that are effects (a delay line in a
        # SampleWrapper).
        FX_LABELS = %w[delay multitap].freeze

        # What made +node+: its node name, else what its preview says it is
        # (a filter's type, a shaper's mode), else its recipe's method name
        # (lp4, softclip), a tone's wave, or CLASS_LABELS, else its class's
        # short name in snake_case (FadeIn: fade_in), never the class name
        # itself.
        def label_of(node)
          return node.graph_node_name.to_s.freeze if node.respond_to?(:named?) && node.named?
          d = node.respond_to?(:preview_data) ? (node.preview_data rescue nil) : nil
          return d[:filter_type].to_s.freeze if d.is_a?(Hash) && d[:filter_type]
          return d[:mode].to_s.freeze if d.is_a?(Hash) && d[:mode]
          rec = node.instance_variable_defined?(:@graph_recipe) ? node.instance_variable_get(:@graph_recipe) : nil
          name = rec.respond_to?(:call) && rec.call.respond_to?(:name) ? rec.call.name : nil
          name ||= node.wave_type if node.respond_to?(:wave_type)
          short = node.class.name.to_s.split('::').last.to_s
          (name || CLASS_LABELS[short] || snake(short)).to_s.freeze
        end

        # What +node+ (labelled +label+) is for (see ROLES), or nil.
        def role_of(node, label = nil)
          return 'fx' if FX_LABELS.include?(label)
          node.class.ancestors.each do |a|
            r = a.name && ROLES[a.name]
            return r.freeze if r
          end
          nil
        end

        # "FadeIn" -> "fade_in".
        def snake(name)
          name.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
        end
      end
    end
  end
end
