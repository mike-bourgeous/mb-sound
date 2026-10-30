module MB
  module Sound
    module GraphIO
      # Writes a set document (`graph 2, kind: :set`): the Set layer of a
      # Session (an Arrangement) as the console commands that make it, so a
      # set can be reopened (graph-io phase 3):
      #
      #     graph 2, name: "night_bus", kind: :set, saved: ..., mb_sound: ...
      #     knob :cut, 700.0, range: 100.0..8000.0, curve: :exp, unit: "Hz"
      #
      #     bpm 124
      #     master { |mix| mix.softclip(0.5, 0.97) }
      #     bus(:hall) { |sig| sig.reverb(:hall, mix: 1) }
      #     track(:bass, send: { hall: -12.db }) { |clip| ... }
      #     bass_a = acid(A1, R, ...).loop.named(:bass_a)
      #     scene :drop, bass: bass_a, cut: 2600
      #     mutes :rhythm, :drums, :bass
      #     flow do
      #       intro 4
      #       ...
      #     end
      #
      # Tempo, meter, master gain, launch quantization, the session's knobs
      # (as `knob` header lines, with their held values), the master chain,
      # buses (their chains built once from their blocks, like the
      # master's), tracks with their routing (to: a bus, send: levels as
      # held gains or the knob names they follow; trigger tracks as
      # `sidechain(:pump) { |clip| ... }`) (patches print as blocks: the patch is built once from the
      # track's clip, or the first clip a scene gives it, keeping the random
      # state, and its recipe printed with the block's parameter name), the
      # clips and kits scenes play, scenes, mute groups, sections declared
      # outside a flow, and the form playing (else the one built last).  Not
      # saved: what is playing, the journal, undo, markers, snapshots, and
      # recorded MIDI (takes keep those).  Scene blocks print as their
      # source when they hold only Loader::SCENE_COMMANDS (`scene(:gap) {
      # meter 2, 4 }`); others go through MB::Sound.live_error (DumpError
      # in scripts; left out with a warning live).  goto Procs and graphs
      # the writer can't print raise DumpError.
      #
      # Patches rebuilt from a document use the seeds the save printed, so
      # a loaded set plays the same every time, while the set it came from
      # draws new seeds for each build.
      class SetWriter < Writer
        # Warnings (parts left out).
        attr_reader :warnings

        def initialize(arrangement, name: nil, meta: {}, assets: nil, from: nil)
          @arrangement = arrangement
          @session = arrangement.session
          @graph = arrangement
          @doc = nil
          @name = name
          @kind = :set
          @inputs = {}
          @params = {}
          @options = {}
          @from = from
          @meta = meta
          @assets = assets
          @warnings = []
        end

        def to_s
          # Patches and master blocks build in the set's Session (knob(:x)),
          # one after another from one random state, so each draws its own
          # seeds (omnibus10: every block from the same state drew the same
          # seeds, so a loaded set's noises were one noise), and the save
          # leaves the random state as it was.  The builds print the seeds
          # they draw even inside MB::Sound.with_seed (bin/save_presets.rb
          # saves sets in one; Recipe::SeedRecording would take them as
          # derived): they are fresh builds for the document.
          st = GraphNode::Recipe.state
          seeded = st.seeded
          st.seeded = 0
          MB::Sound.keeping_random_state do
            Session.with_context(session: @session) { text }
          end
        ensure
          st.seeded = seeded if st
        end

        private

        def text
          @problems = []
          @warnings = []
          @lit = GraphNode::Recipe::RubyWriter.new(nil)
          @knobs = @session.knobs
          # (knobs print as the names the set's `knob` lines define; a name
          # that isn't a Ruby identifier, like a bound literal's :"bass/resonance",
          # as knob(:"bass/resonance"))
          @knob_nodes = @knobs.each_with_object({}.compare_by_identity) { |(n, k), h| h[k] = n.to_s.match?(/\A[a-z_][A-Za-z0-9_]*\z/) ? n.to_s : "knob(#{n.inspect})" }
          @used = Set.new(@knobs.keys.map(&:to_s))

          body = []
          clocks = clock_lines
          body.concat(settings)
          # Clips first: patches and graphs may use them by name
          body.concat(clips)
          body.concat(master)
          body.concat(buses)
          body.concat(tracks)
          body.concat(scenes)
          body.concat(mute_groups)
          body.concat(sections)
          body.concat(form)

          unless @problems.empty?
            raise DumpError.new("can't save this set yet: #{@problems.uniq.join('; ')}", problems: @problems.uniq, code: body.join("\n"))
          end

          header = []
          header << '# mb-sound set document: a Ruby subset that MB::Sound.preset and'
          header << '# MB::Sound::GraphIO.load read without running it (no eval).'
          header << graph_line(@lit, {})
          @knobs.each_value { |k| header.concat(knob_lines(@lit, k)) }
          header.concat(clocks)
          (@assets&.entries || []).each do |e|
            header << "asset #{e.name.inspect}#{", sha256: #{e.sha256.inspect}" if e.sha256}"
          end
          header.concat(@warnings.uniq.map { |w| "# WARNING(graph-io): #{w}" })
          (header + [''] + body).join("\n") + "\n"
        end

        def lit(v)
          @lit.literal(v)
        end

        # Tempo, meter, master gain, and quantization.
        def settings
          t = @session.transport
          lines = ["bpm #{lit(t.bpm)}"]
          bar = t.bar_length(0r)
          unless bar == 1
            r = bar.to_r
            unit = [4, 8, 16, 2, 1, 32].find { |u| (r * u).denominator == 1 }
            if unit
              lines << "meter #{(r * unit).to_i}, #{unit}"
            else
              @problems << "a bar of #{r} whole notes (no meter of 1-32 note units)"
            end
          end
          if t.meters.length > 1
            @warnings << "meter changes after bar 1 aren't saved (#{t.meters.length - 1})"
          end
          if @session.master_gain_post?
            lines << "master_gain #{lit(@session.master_gain)}, post: true"
          elsif @session.master_gain != Session::DEFAULT_MASTER_GAIN
            lines << "master_gain #{lit(@session.master_gain)}"
          end
          lines << "quant #{lit(@arrangement.quant)}" unless @arrangement.quant == 1
          lines
        end

        # The session's clocks as header lines (after the knobs their
        # speeds may read; time-automation).
        def clock_lines
          @session.clocks.filter_map do |name, c|
            "clock #{[name.inspect, *c.line_args].join(', ')}"
          rescue ArgumentError => e
            @problems << e.message
            nil
          end
        end

        # The master chain, built again from its block with a fresh mix
        # input named after the block's parameters.
        # A mastering preset prints as `master :club, lufs: -8` (with the
        # block, if any, before it in the chain).
        def master
          block = @session.master_block
          preset = @session.master_preset
          return ["master #{preset.call_ruby}"] if preset && block.nil?
          return [] unless block

          source = GraphNode::MixSource.new(channels: @session.channels, sample_rate: 48000)
          chans = source.outputs
          args = block.arity == 0 || block.arity == 1 ? [GraphNode::Channels.new(chans)] : chans
          block_statement(:master, preset ? [preset.name] : [], preset ? preset.options : {}, block, args, 'master')
        end

        # The buses (Session::Buses), each bus after the bus its output
        # feeds: `bus(:hall, to: :verb) { |sig| ... }` (the chain built once
        # from its block, like the master's), or `bus :drums, to: :master`
        # without a block.
        def buses
          defs = @session.bus_definitions
          order = []
          visit = ->(n) {
            next if order.include?(n) || !defs.key?(n)
            to = defs[n][1]
            visit.(to) unless to == :master
            order << n
          }
          defs.each_key { |n| visit.(n) }
          order.flat_map { |name|
            block, to, _description = defs[name]
            kwargs = {}
            kwargs[:to] = to unless to == :master
            # (a plain bus: `bus :drums, to: :master`; bus(:drums) alone reads one)
            next ["bus #{name.inspect}, to: #{lit(to)}"] unless block
            source = GraphNode::MixSource.new(channels: @session.channels, sample_rate: 48000)
            chans = source.outputs
            args = block.arity == 0 || block.arity == 1 ? [GraphNode::Channels.new(chans)] : chans
            block_statement(:bus, [name], kwargs, block, args, "bus #{name.inspect}")
          }
        end

        # A player's routing as track options (to:, send:), from
        # Session#route_definitions: send levels as held gains or the knob
        # names they follow.
        def route_options(name, routes)
          r = routes[name] or return {}
          opts = {}
          opts[:to] = r[:to] if r[:to]
          sends = r[:send].to_h { |bus, v|
            unless v.is_a?(Numeric) || v.is_a?(Symbol)
              @problems << "track #{name.inspect}: its send to #{bus.inspect} follows a node that isn't a session knob (set documents save gains and knob names)"
            end
            [bus, v]
          }
          opts[:send] = sends unless sends.empty?
          opts
        end

        def tracks
          routes = @session.route_definitions
          @arrangement.tracks.flat_map { |name, tr|
            opts = {}
            opts[:q] = tr.q if tr.q
            opts[:fade] = tr.fade if tr.fade
            opts[:lead] = tr.lead if tr.lead
            opts[:lead_max] = tr.lead_max if tr.lead_max
            opts[:nudge] = tr.nudge if tr.nudge
            opts[:clock] = tr.clock if tr.clock
            opts.merge!(route_options(name, routes))
            if tr.trigger && tr.patch && (opts.keys - %i[q fade nudge]).empty?
              # A trigger track (SidechainMethods#sidechain): its patch as a block
              block_statement(:sidechain, [name], opts, tr.patch, [probe_clip(name, tr)], "trigger track #{name.inspect}")
            elsif tr.patch && (sym = instrument_symbol(tr.patch))
              # A library instrument (`track :bass, :dnb_reese`; Arrangement::InstrumentPatch)
              opts[:trigger] = true if tr.trigger
              ["track #{[name.inspect, sym.inspect, *opts.map { |k, v| "#{k}: #{lit(v)}" }].join(', ')}"]
            elsif tr.patch
              opts[:trigger] = true if tr.trigger
              block_statement(:track, [name], opts, tr.patch, [probe_clip(name, tr)], "track #{name.inspect}")
            else
              opts[:trigger] = true if tr.trigger
              graph_statement("track #{name.inspect}", tr.graph, opts.map { |k, v| "#{k}: #{lit(v)}" })
            end
          }
        end

        # The Symbol naming the library instrument +patch+ plays (see
        # Arrangement::InstrumentPatch), if it names it back; nil for patch
        # blocks and bound literals (printed as their blocks).
        def instrument_symbol(patch)
          return nil if patch.respond_to?(:literal_bindings)
          entry = Arrangement::InstrumentPatch.entry_of(patch) or return nil
          Arrangement::InstrumentPatch.symbol_for(entry)
        end

        # The clip a patch is built from: the track's clip, else the first
        # clip or kit a scene gives it, else an empty one-bar loop.
        def probe_clip(name, tr)
          return tr.clip if tr.clip.is_a?(Sequence::Clip) || tr.clip.is_a?(Sequence::Kit)
          @arrangement.scenes.each_value do |sc|
            v = sc.values[name]
            return v if v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit)
          end
          Sequence::Clip.new([], length: 1, loop: true)
        end

        # `name(args, kwargs) { |params| body }` for a block (a patch or
        # the master chain), printed by building it once with +block_args+
        # as a recorded build block: the block runs through
        # Recipe.wrap_block like a synth's lane block, so its locals are
        # read by the recorder's frame capture (no TracePoint, which would
        # make YJIT drop its code while a set plays), and the RubyWriter
        # prints the call with the block's own parameter names.  Seeds come
        # from the save's running random state (see #to_s).  Returns
        # the lines, or none with a problem if the block raised.
        def block_statement(name, args, kwargs, block, block_args, what)
          call = GraphNode::Recipe::Call.new(MB::Sound, name, args, kwargs, block, :build, nil, nil, 0, nil, nil)
          # (a track's patch wrapper: its user block, built in its context)
          inner = block.respond_to?(:patch_block) ? block.patch_block : block
          call.block = inner
          wrapped = GraphNode::Recipe.wrap_block(inner, call)
          block.respond_to?(:patch_context) ? block.patch_context { wrapped.call(*block_args) } : wrapped.call(*block_args)

          # The writer prints objects through their calls: a holder whose
          # recipe is this call prints as the statement
          holder = Sequence::Clip.new([])
          holder.instance_variable_set(:@graph_recipe, GraphNode::Recipe::Record.new(holder, call))
          writer = writer_for(holder, {})
          vars, expr = writer.parts
          collect(writer, what)
          vars + expr
        rescue StandardError => e
          @problems << "#{what} couldn't be built to save it (#{e.class}: #{e.message})"
          []
        end

        # `head graph, opts` with the graph's variables first.
        def graph_statement(head, graph, opts)
          writer = writer_for(graph, {})
          vars, expr = writer.parts
          collect(writer, head)
          expr = expr.dup
          expr[0] = "#{head}, #{expr[0]}"
          expr[-1] = [expr[-1], *opts].join(', ')
          vars + expr
        end

        def writer_for(root, inputs)
          named = (@clip_names || {}).each_with_object({}) { |(obj, n), h| h[n] = obj unless inputs.values.any? { |i| i.equal?(obj) } || root.equal?(obj) }
          GraphNode::Recipe::RubyWriter.new(
            root, inputs: named.merge(inputs.transform_keys(&:to_s)), seeds: :marked, knob_nodes: @knob_nodes, assets: @assets
          )
        end

        # Adds a writer's FIXMEs (problems) and warnings, and complains about
        # free inputs it found.
        def collect(writer, what)
          writer.problems.each { |p| @problems << "#{what}: #{p}" }
          writer.warnings.each { |w| @warnings << "#{what}: #{w}" }
          given = (@clip_names || {}).values
          extra = writer.inputs.keys - given.map(&:to_s) - writer_given(writer)
          extra.each { |n| @problems << "#{what}: uses #{n}, an object without a recipe" }
        end

        def writer_given(writer)
          writer.instance_variable_get(:@given_inputs).keys.map(&:to_s)
        end

        # The clips and kits scenes play, as variables named after their
        # .named names (else clip, clip2, ...), each printed once in the
        # order they were made, referring to the ones before by name.
        def clips
          list = []
          @arrangement.scenes.each_value do |sc|
            sc.values.each_value do |v|
              list << v if (v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit)) && !list.any? { |x| x.equal?(v) }
            end
          end
          list = list.each_with_index.sort_by { |c, i| [GraphNode::Recipe.call_of(c)&.seq || 0, i] }.map(&:first)

          @clip_names = {}.compare_by_identity
          list.each { |c| @clip_names[c] = unique(c.respond_to?(:name) && c.name ? c.name.to_s : 'clip') }

          list.flat_map { |c|
            name = @clip_names[c]
            writer = writer_for(c, {})
            vars, expr = writer.parts
            collect(writer, "clip #{name}")
            expr = expr.dup
            expr[0] = "#{name} = #{expr[0]}"
            vars + expr
          }
        end

        def unique(name)
          base = name.gsub(/[^a-zA-Z0-9_]/, '_').sub(/\A_+/, '').downcase
          base = "c_#{base}" unless base.match?(/\A[a-z_]/)
          base = "#{base}_" if GraphNode::Recipe::RubyWriter::KEYWORDS.include?(base)
          n = base
          i = 2
          while @used.include?(n)
            n = "#{base}#{i}"
            i += 1
          end
          @used << n
          n
        end

        def scenes
          @arrangement.scenes.flat_map { |name, sc|
            parts = [name.inspect]
            sc.values.each do |k, v|
              parts << "#{@lit.key_text(k)} #{scene_value(name, k, v)}"
            end
            parts << "q: #{lit(sc.q)}" if sc.q
            parts << "fade: #{lit(sc.fade)}" if sc.fade
            parts << "others: #{lit(sc.others)}" unless sc.others == :stop
            block = sc.block && scene_block(name, sc.block)
            block ? "scene(#{parts.join(', ')}) #{block}".lines(chomp: true) : ["scene #{parts.join(', ')}"]
          }
        end

        # A scene block's text, if the set-document loader can run it
        # (Loader::SCENE_COMMANDS: `{ meter 2, 4 }`, `{ |t| bg :riser, ... }`),
        # else nil after MB::Sound.live_error (raising DumpError in scripts
        # and specs; in live mode a warning, and the scene is saved
        # without its block).
        def scene_block(name, block)
          src = GraphNode::Recipe.block_source(block, :scene)
          problem =
            if src.nil?
              "its source wasn't found"
            elsif !(outer = GraphNode::Recipe.outer_locals(block, src)).empty?
              "it uses #{outer.join(', ')} from the code around it"
            else
              Loader.scene_block_problem(src)
            end
          return dedent(src) unless problem

          MB::Sound.live_error(DumpError.new("scene #{name.inspect}'s block can't be saved: #{problem}"))
          @warnings << "scene #{name.inspect}'s block was left out (#{problem})"
          nil
        end

        # +text+ with the lines after the first moved left by the last
        # line's indentation (a block's source keeps its file's indents).
        def dedent(text)
          lines = text.lines(chomp: true)
          return text if lines.length < 2
          cut = lines.last[/\A */].length
          ([lines.first] + lines[1..].map { |l| l.start_with?(' ' * cut) ? l[cut..] : l.lstrip }).join("\n")
        end

        def scene_value(scene, key, v)
          return @clip_names[v] if @clip_names&.key?(v)
          if GraphNode::Recipe.graph_object?(v)
            @problems << "scene #{scene.inspect}: #{key} follows a graph node, which set documents can't hold yet"
            return 'nil'
          end
          lit(v)
        end

        def mute_groups
          @session.mute_groups.map { |g, names| "mutes #{[g, *names].map(&:inspect).join(', ')}" }
        end

        def sections
          @arrangement.sections.map { |name, s|
            parts = [name.inspect, Form.ruby_value(s.length), *s.options.map { |k, v| "#{k}: #{Form.ruby_value(v)}" }]
            "section #{parts.join(', ')}"
          }
        end

        def form
          f = @arrangement.playback&.form || @arrangement.last_form
          return [] unless f

          text = f.to_ruby
          @problems << "the flow has a goto Proc (code), which set documents can't hold" if text.include?('->(f)')
          text.lines(chomp: true)
        end
      end
    end
  end
end
