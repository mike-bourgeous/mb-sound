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
        #
        # Sections (sound-design-nav-1; Classify): +section+ (one of
        # SECTIONS, :plumbing for a hidden node shown with the p key, nil
        # in data made without sections), +what+ (a few words of role:
        # "amp env", "post-amp EQ"), +dest+ (where an envelope or LFO goes:
        # ["lp4 cutoff"]), +voice+ (a drum voice's name, or nil),
        # +channels+ (2 after a stereo mixer: +count+ is then the copies
        # one voice has in one channel), +param_knobs+ ({ param => knob
        # name } for params a knob drives through arithmetic, `knob(:cut)
        # * lfo`, so turning the param turns that knob).
        NodeInfo = Data.define(:key, :label, :role, :count, :params, :preview, :knobs, :live, :binds, :section, :what, :dest, :voice, :channels, :param_knobs) do
          def initialize(key:, label:, role:, count:, params:, preview:, knobs:, live: nil, binds: {}.freeze, section: nil, what: nil, dest: [].freeze,
                         voice: nil, channels: 1, param_knobs: {}.freeze)
            super
          end

          # The knob param +name+ turns: its knob's name, directly or
          # through arithmetic, else nil.
          def knob_of(name)
            v = params.values[name]
            v&.label.is_a?(Symbol) ? v.label : param_knobs[name]
          end
        end

        # The sections of the inspector, in signal order (the maintainer,
        # 2026-10-29: "Fewer, envelopes inside", the Minimoog way), their
        # titles and jump keys (chosen around the inspector's own keys: m
        # learns, so MOD is o).
        SECTIONS = %i[source filter amp mod fx].freeze
        SECTION_TITLES = { source: 'SOURCE', filter: 'FILTER', amp: 'AMP', mod: 'MOD', fx: 'FX', plumbing: 'PLUMBING' }.freeze
        SECTION_KEYS = { source: 's', filter: 'f', amp: 'a', mod: 'o', fx: 'x' }.freeze

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
        #
        # Sections (sound-design-nav-1): +loose+ (the knob names no row's
        # params show: listed above the sections), +hidden+ ({ reason =>
        # count } of plumbing nodes), +voices+ (a kit's drum voices, in
        # order; empty for synths), +voice+ (the voice shown), +unfit+
        # (nodes no section takes: 0 for every shipped instrument),
        # +document+ (the graph document's name when the graph is a preset:
        # its numbers are fixed, its params are the track's knobs),
        # +voice_knobs+ (a kit's knob values per voice: { kick: { tune:
        # 50.0, ... } }), +build_knobs+ (the knobs read while the graph
        # built, such as the init voice's sync: turning one rebuilds the
        # track, so the inspector turns them a step a key, never as a held
        # sweep; Arrangement::BuildKnobs).
        InspectInfo = Data.define(:track, :tracks, :knobs, :nodes, :node, :code, :error, :loose, :hidden, :voices, :voice, :unfit, :document, :voice_knobs,
                                  :build_knobs) do
          def initialize(track:, tracks:, knobs:, nodes:, node:, code:, error:, loose: nil, hidden: {}.freeze, voices: [].freeze, voice: nil, unfit: 0, document: nil,
                         voice_knobs: {}.freeze, build_knobs: [].freeze)
            super(track: track, tracks: tracks, knobs: knobs, nodes: nodes, node: node, code: code, error: error, loose: loose || knobs,
                  hidden: hidden, voices: voices, voice: voice, unfit: unfit, document: document, voice_knobs: voice_knobs, build_knobs: build_knobs)
          end

          # The selected NodeInfo, or nil.
          def selected = node && nodes[node]

          # The rows shown (+plumbing+: the hidden nodes too) of the
          # shown voice, as indices into #nodes.
          def shown(plumbing: false)
            nodes.each_index.select { |i|
              n = nodes[i]
              (plumbing || n.section != :plumbing) && (voice.nil? || n.voice.nil? || n.voice == voice)
            }
          end

          # True when the nodes are in sections (data from Classify).
          def sections? = nodes.any?(&:section)
        end

        # Node classes never listed (plumbing: their settings are other
        # nodes' params).  Matched by class name so the list needs no
        # requires.
        SKIP = %w[
          MB::Sound::GraphNode::Constant MB::Sound::GraphNode::Knob MB::Sound::GraphNode::Knob::Reader
          MB::Sound::GraphNode::Tee MB::Sound::GraphNode::Tee::Branch MB::Sound::GraphNode::Multiplier
          MB::Sound::GraphNode::Mixer MB::Sound::GraphNode::ProcNode MB::Sound::GraphNode::BinaryOperation
          MB::Sound::GraphNode::NoteFrequency MB::Sound::GraphNode::QualityResonance MB::Sound::Notes::Frequency
          MB::Sound::Synth::Output MB::Sound::GraphNodeInput MB::Sound::Notes::NoteEnvelope::GmTime
        ].freeze

        # Section rows listed at most (a big graph's tail is left out).
        MAX_NODES = 200

        # Plumbing rows (the p key's hidden nodes) listed at most.
        MAX_PLUMBING = 40

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
            tracks = graphs.keys.reject { |n| Session::Name.monitored(n) }.freeze
            track = pick_track(target[:track], tracks)
            return InspectInfo.new(track: nil, tracks: tracks, knobs: [].freeze, nodes: [].freeze, node: nil, code: nil, error: nil) unless track

            roots = Inspect.roots(graphs[track])
            entry = @cache[track]
            unless entry && entry[:roots].length == roots.length && entry[:roots].zip(roots).all? { |a, b| a.equal?(b) }
              entry = @cache[track] = { roots: roots, **Inspect.walk(roots) }
            end
            @cache.select! { |k, _| graphs.key?(k) }

            nodes = entry[:nodes]
            voices = entry[:voices]
            voice = voices.include?(target[:voice]) ? target[:voice] : voices.first
            sel = target[:node]
            sel = nil if sel && voice && (v = nodes[sel.clamp(0, [nodes.length - 1, 0].max)]&.voice) && v != voice
            sel = Inspect.default_node(nodes, voice, objects: entry[:objects]) if sel.nil?
            sel = sel.clamp(0, nodes.length - 1) if sel && !nodes.empty?
            sel = nil if nodes.empty?
            # (the selected node's snapshot again: its knob-driven values
            # and preview follow turns; the others keep their first one)
            if sel && (n = entry[:objects][sel])
              nodes = nodes.dup
              nodes[sel] = nodes[sel].with(params: Inspect.snapshot(n, entry[:extras][sel]), live: live_of(entry[:groups][sel]), binds: binds_of(session, track, entry, sel, n))
              nodes.freeze
            end
            InspectInfo.new(track: track, tracks: tracks, knobs: entry[:knobs], nodes: nodes, node: sel, code: entry[:code], error: nil,
                            loose: entry[:loose], hidden: entry[:hidden], voices: voices, voice: voice, unfit: entry[:unfit], document: entry[:document],
                            voice_knobs: entry[:voice_knobs], build_knobs: entry[:build_knobs] || [].freeze)
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

        # The nodes +root+ reads, itself first: its #graph, or for a root
        # that isn't a GraphNode but has sources (a ChannelMixer: Pan,
        # Balance, Unison, the multi-output node holding the recipe) the
        # same walk from it (GraphNode.graph; before omnibus15 such roots
        # showed only themselves: tine_piano's inspector listed one node,
        # found by research-sound-design-nav).
        def nodes_of(root)
          return root.graph if root.respond_to?(:graph)
          return GraphNode.graph(root) if root.respond_to?(:sources)
          [root]
        end

        # The node list, knob names, and code of graph +roots+ (see
        # InspectInfo): { nodes:, objects:, groups:, extras:, knobs:, loose:,
        # hidden:, voices:, unfit:, code:, capped: }.
        #
        # The nodes are the sections' rows (Classify: SOURCE FILTER AMP MOD
        # FX, copies with the same settings merged, counted per voice and
        # channel), then the plumbing nodes that have params or a preview
        # (section :plumbing, +what+ the reason they're hidden; the p key
        # shows them), at most MAX_PLUMBING groups.  +objects+ holds each
        # row's first node, +groups+ its copies, +extras+ the knobs read
        # only through hidden arithmetic that join the row ([[param,
        # reader], ...]).
        def walk(roots)
          cls = Classify.call(roots)
          knobs = []
          readers = {}
          cls.plumbing.each do |_, n|
            k = n.is_a?(GraphNode::Knob::Reader) ? n.knob : n.is_a?(GraphNode::Knob) ? n : nil
            next unless k&.name
            knobs << k.name unless knobs.include?(k.name)
            readers[k.name] ||= n if n.is_a?(GraphNode::Knob::Reader)
          end
          # (switches read while the graph built: Tone#sync's enabled:)
          build_knobs = []
          cls.rows.each do |r|
            sw = r.nodes.first.respond_to?(:sync_switch) && GraphNode.climb_tee_tree(r.nodes.first.sync_switch)
            k = sw.is_a?(GraphNode::Knob::Reader) ? sw.knob : nil
            next unless k&.name
            knobs << k.name unless knobs.include?(k.name)
            build_knobs << k.name unless build_knobs.include?(k.name)
          end
          # (knobs a row reads that no row's shown params name: an
          # oscillator's pitch offset through note plumbing, an FM depth
          # inside its frequency; sound-design-2: the init voice's tune2 and
          # fm) join the first row reading them as knob params
          kept = cls.rows.first(MAX_NODES)
          unseen = kept.map { |r| unshown_knobs(r.nodes.first, r.knobs) }
          seen = kept.each_with_index.flat_map { |r, i| Inspect.knobs_read(r.nodes.first) - unseen[i] + r.knobs.map { |_, rd| rd.knob.name } }.uniq
          claimed = seen.to_h { |kn| [kn, true] }
          rows = kept.each_with_index.map { |r, i|
            n = r.nodes.first
            label = r.label
            pk = Inspect.param_knobs(n)
            extras = r.knobs
            mine = unseen[i].reject { |kn| claimed[kn] }
            unless mine.empty?
              extras = r.knobs + mine.filter_map { |kn| readers[kn] && [Session::Name[kn].leaf, readers[kn]] }
              mine.each { |kn| claimed[kn] = true }
            end
            snap = Inspect.snapshot(n, extras)
            read = (Inspect.knobs_read(n) + extras.map { |_, rd| rd.knob.name }).uniq.freeze
            info = NodeInfo.new(key: 0, label: label, role: role_of(n, label), count: r.copies, params: snap, preview: preview?(n), knobs: read,
                                section: r.section == :other ? nil : r.section, what: r.what, dest: r.dest, voice: r.voice, channels: r.channels, param_knobs: pk)
            [n, info, r.nodes, extras]
          }

          # (hidden nodes with settings, for the p key: grouped by settings)
          groups = {}
          cls.plumbing.each do |why, n|
            next if n.is_a?(Numeric) || !n.respond_to?(:param_info)
            next if SKIP.include?(n.class.name) # (knobs have rows of their own; arithmetic and note frequencies are other nodes' params)
            info = (n.param_info rescue {})
            if recipe?(n) # (the numbers its call was given: a synth's voices)
              lits = literal_params(n, info)
              info = info.merge(lits) unless lits.empty?
            end
            next if info.empty? && !preview?(n)
            sig = [why, n.class, info.map { |name, v| [name, v.value, v.label] }, preview?(n) ? (n.preview_data rescue nil) : nil]
            (groups[sig] ||= []) << n
          end
          capped = cls.rows.length > MAX_NODES || groups.length > MAX_PLUMBING
          groups.first(MAX_PLUMBING).each do |sig, list|
            n = list.first
            label = label_of(n)
            info = NodeInfo.new(key: 0, label: label, role: role_of(n, label), count: list.length, params: Inspect.snapshot(n), preview: preview?(n),
                                knobs: Inspect.knobs_read(n).freeze, section: :plumbing, what: sig[0].dup.freeze)
            rows << [n, info, list.freeze, [].freeze]
          end

          nodes = rows.each_with_index.map { |(_, info, _, _), i| info.with(key: i) }.freeze
          shown = {}
          nodes.each do |info|
            next if info.section == :plumbing
            info.params.values.each_value { |v| shown[v.label] = true if v.label.is_a?(Symbol) }
            info.param_knobs.each_value { |k| shown[k] = true }
          end
          voices = cls.rows.filter_map(&:voice).uniq.freeze

          code = roots.filter_map { |r| r.respond_to?(:to_ruby) ? (r.to_ruby rescue nil) : nil }.uniq.join("\n").freeze
          {
            nodes: nodes, objects: rows.map(&:first).freeze, groups: rows.map { |r| r[2] }.freeze, extras: rows.map(&:last).freeze,
            knobs: knobs.freeze, loose: knobs.reject { |k| shown[k] }.freeze, hidden: cls.hidden, voices: voices, unfit: cls.unfit.length,
            code: code.empty? ? nil : code, capped: capped, voice_knobs: cls.voice_knobs, build_knobs: build_knobs.freeze,
            document: roots.lazy.filter_map { |r| GraphIO.document_of(r) rescue nil }.first&.name&.then { |n| "#{n}".freeze }, # (a new String: a name from document text carries GraphIO::FileGuard's mark)
          }
        end

        # Params the sound panes leave out while a node feeds them (note
        # plumbing: a voice's gate, frequency, phase, ...).
        NOTE_PARAMS = %i[gate trigger velocity choke frequency phase reset release_at timeline_jumps timeline_phase].freeze

        # The knobs +node+ reads (knobs_read, depth 3) that neither its
        # shown params (a knob's own label, a param_knobs entry outside
        # NOTE_PARAMS) nor +extras+ ([[param, reader], ...]) show.
        def unshown_knobs(node, extras, pk = param_knobs(node))
          read = knobs_read(node)
          return [] if read.empty?
          info = (node.respond_to?(:param_info) ? node.param_info : {}) rescue {}
          seen = extras.map { |_, rd| rd.knob.name }
          info.each { |name, v| seen << v.label if v.label.is_a?(Symbol) }
          pk.each { |name, kn| seen << kn unless NOTE_PARAMS.include?(name) }
          read - seen
        end

        # The row the inspector opens on in +nodes+ (of drum voice +voice+,
        # or every row): the first filter whose params read a knob, else the
        # first filter (the maintainer: designing a sound starts at its
        # filter; not an envelope in FILTER), else the first SOURCE row, else the
        # first shown row; nil without rows.
        #
        # A kit's voice (+voice+ given and the row is that voice's) opens on
        # its body instead (sound-design-2; sound-design-nav-1's question 2):
        # its resonator (a `ping` or `resonate` row; +objects+ are the rows'
        # nodes), else its first SOURCE row (an oscillator, noise, or ROM
        # sample), so a 909 kick opens on its ping, not its click's highpass.
        def default_node(nodes, voice = nil, objects: nil)
          mine = nodes.each_index.select { |i| nodes[i].section != :plumbing && (voice.nil? || nodes[i].voice.nil? || nodes[i].voice == voice) }
          if voice
            own = mine.select { |i| nodes[i].voice == voice }
            body = ->(i) { objects ? objects[i].is_a?(GraphNode::Resonator) : %w[ping resonate].include?(nodes[i].label) }
            found = own.find(&body) || own.find { |i| nodes[i].section == :source }
            # (a body the kit's voices share, a row of no voice: the 808's
            # metal bank under its hats and cymbal)
            shared = mine.select { |i| nodes[i].voice.nil? }
            found ||= objects && upstream_body(own, shared, nodes, objects, body)
            return found if found
          end
          filters = mine.select { |i| nodes[i].section == :filter && nodes[i].what.nil? }
          filters.find { |i| !nodes[i].knobs.empty? } || filters.first || mine.find { |i| nodes[i].section == :filter } ||
            mine.find { |i| nodes[i].section == :source } || mine.first || (nodes.empty? ? nil : 0)
        end

        # The first of rows +among+ upstream of rows +own+ (through main
        # inputs; +objects+ are the rows' nodes) that +body+ accepts or that
        # is in SOURCE, or nil.
        def upstream_body(own, among, nodes, objects, body)
          row = {}
          objects.each_with_index { |o, i| row[o.__id__] ||= i }
          seen = {}
          queue = own.map { |i| objects[i] }
          steps = 0
          until queue.empty? || (steps += 1) > 400
            n = queue.shift
            next if seen[n.__id__]
            seen[n.__id__] = true
            i = row[n.__id__]
            return i if i && among.include?(i) && (body.(i) || nodes[i].section == :source)
            next unless n.respond_to?(:sources)
            n.sources.each do |name, src|
              next if src.is_a?(Numeric) || (n.respond_to?(:port_role) && n.port_role(name) != :main)
              queue << GraphNode.climb_tee_tree(src)
            end
          end
          nil
        end

        # The knob each param of +node+ reads through arithmetic (`cut *
        # lfo`, `2 ** env * cut`), when it reads exactly one: { param =>
        # knob name } (params given a knob directly name it in their
        # ParamValue#label instead).
        def param_knobs(node)
          return {}.freeze unless node.respond_to?(:params)
          (node.params rescue {}).each_with_object({}) { |(name, src), h|
            next if src.is_a?(Numeric)
            s = GraphNode.climb_tee_tree(src)
            next if s.is_a?(GraphNode::Knob::Reader) || s.is_a?(GraphNode::Knob)
            found = knobs_in(s, 3, arithmetic: true)
            h[name] = found.first if found.length == 1
          }.freeze
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
        #
        # +extras+ ([[param, knob reader], ...]: knobs read only through
        # hidden arithmetic that join this node's row, Classify) are added
        # as knob params (detail "knob"), after the node's own.
        def snapshot(node, extras = nil)
          snap =
            if node.respond_to?(:param_snapshot) then node.param_snapshot
            else GraphNode::Traversable::Params.new(node_class: node.class, name: nil, values: node.respond_to?(:param_info) ? node.param_info : {}.freeze, preview: nil)
            end
          lits = literal_params(node, snap.values)
          snap = snap.with(values: snap.values.merge(lits).freeze) unless lits.empty?
          return snap if extras.nil? || extras.empty?
          more = extras.each_with_object({}) { |(name, rd), h|
            key = snap.values.key?(name) ? rd.knob.name : name
            h[key] = GraphNode::Traversable.describe_param(rd).with(detail: KNOB)
          }
          snap.with(values: snap.values.merge(more).freeze)
        end

        # The detail of a knob param joined to a row (see .snapshot).
        KNOB = 'knob'.freeze

        # The literal arguments of +node+'s recorded call missing from
        # +values+ (see .snapshot), as { name => ParamValue }.
        def literal_params(node, values)
          lb = Arrangement::LiteralBinding
          found = lb.literals(node)
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
          return out unless node.respond_to?(:params)
          node.params.each_value do |src|
            next if src.is_a?(Numeric)
            knobs_in(src, depth - 1).each { |k| out << k unless out.include?(k) }
          end
          out
        end

        # The knob names +src+ is or reads through +depth+ nodes (only
        # through Multipliers, Mixers, BinaryOperations, and ProcNodes with
        # +arithmetic+: a
        # glide reading a knob for its time doesn't make the frequency it
        # moves that knob's).
        def knobs_in(src, depth, arithmetic: false)
          out = []
          frontier = [src]
          (depth + 1).times do
            nxt = []
            frontier.each do |s|
              s = GraphNode.climb_tee_tree(s)
              k = s.is_a?(GraphNode::Knob::Reader) ? s.knob : s.is_a?(GraphNode::Knob) ? s : nil
              if k
                out << k.name if k.name && !out.include?(k.name)
                next
              end
              next if arithmetic && !(s.is_a?(GraphNode::Multiplier) || s.is_a?(GraphNode::Mixer) || s.is_a?(GraphNode::BinaryOperation) || s.is_a?(GraphNode::ProcNode))
              nxt.concat(s.sources.values.reject { |v| v.is_a?(Numeric) }) if s.respond_to?(:sources)
            end
            frontier = nxt
            break if frontier.empty?
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

require_relative 'inspect/classify'
