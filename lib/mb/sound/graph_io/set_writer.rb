module MB
  module Sound
    module GraphIO
      # Writes a set document (`graph 1, kind: :set`): the Set layer of a
      # Session (an Arrangement) as the console commands that make it, so a
      # set can be reopened (graph-io phase 3):
      #
      #     graph 1, name: "night_bus", kind: :set, saved: ..., mb_sound: ...
      #     knob :cut, 700.0, range: 100.0..8000.0, curve: :exp, unit: "Hz"
      #
      #     bpm 124
      #     master { |mix| mix.softclip(0.5, 0.97) }
      #     track(:bass) { |clip| ... }
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
      # tracks (patches print as blocks: the patch is built once from the
      # track's clip, or the first clip a scene gives it, keeping the random
      # state, and its recipe printed with the block's parameter name), the
      # clips and kits scenes play, scenes, mute groups, sections declared
      # outside a flow, and the form playing (else the one built last).  Not
      # saved: what is playing, the journal, undo, markers, snapshots, and
      # recorded MIDI (takes keep those).  Scene blocks (code run at
      # launch) are left out with a warning; goto Procs and graphs the
      # writer can't print raise DumpError.
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
          # Patches and master blocks build in the set's Session (knob(:x))
          Session.with_context(session: @session) { text }
        end

        private

        def text
          @problems = []
          @warnings = []
          @lit = GraphNode::Recipe::RubyWriter.new(nil)
          @knobs = @session.knobs
          @knob_nodes = @knobs.each_with_object({}.compare_by_identity) { |(n, k), h| h[k] = n.to_s }
          @used = Set.new(@knobs.keys.map(&:to_s))

          body = []
          body.concat(settings)
          # Clips first: patches and graphs may use them by name
          body.concat(clips)
          body.concat(master)
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
          lines << "master_gain #{lit(@session.master_gain)}" unless @session.master_gain == Session::DEFAULT_MASTER_GAIN
          lines << "quant #{lit(@arrangement.quant)}" unless @arrangement.quant == 1
          lines
        end

        # The master chain, built again from its block with a fresh mix
        # input named after the block's parameters.
        def master
          block = @session.master_block
          return [] unless block

          names = block.parameters.map { |_, n| n }.compact
          source = GraphNode::MixSource.new(channels: @session.channels, sample_rate: 48000)
          chans = source.outputs
          if block.arity == 0 || block.arity == 1
            name = names[0] || :mix
            input = GraphNode::Channels.new(chans)
            inputs = { name => input }
            result, locals = probe(block, [input])
          else
            inputs = names.each_with_index.to_h { |n, i| [n, chans[i]] }
            result, locals = probe(block, chans)
          end
          return [] unless result

          block_lines('master', nil, names.empty? ? [:mix] : names, result, inputs, locals)
        end

        def tracks
          @arrangement.tracks.flat_map { |name, tr|
            opts = []
            opts << "q: #{lit(tr.q)}" if tr.q
            opts << "fade: #{lit(tr.fade)}" if tr.fade
            opts << "lead: #{lit(tr.lead)}" if tr.lead
            opts << "lead_max: #{lit(tr.lead_max)}" if tr.lead_max
            opts << "nudge: #{lit(tr.nudge)}" if tr.nudge
            if tr.patch
              clip = probe_clip(name, tr)
              param = tr.patch.parameters.map { |_, n| n }.compact.first || :clip
              result, locals = probe(tr.patch, [clip], "track #{name.inspect}")
              next [] unless result
              block_lines("track(#{[name.inspect, *opts].join(', ')})", nil, [param], result, { param => clip }, locals)
            else
              graph_statement("track #{[name.inspect].join}", tr.graph, opts)
            end
          }
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

        # Calls +block+ with +args+, recording what it builds and its local
        # variables.  Returns [result, { object => local name }], or nil if
        # it raised (a problem).
        def probe(block, args, what = 'master')
          inv = GraphNode::Recipe::Invocation.new(args, nil, {}, false, nil, nil)
          # Building draws seeds; the session's later draws stay as they were
          result = MB::Sound.keeping_random_state {
            # Loaded blocks keep their locals; others are read with a
            # TracePoint (the fast frame capture needs the block's own
            # recording scope, which a probe doesn't push)
            if block.respond_to?(:graph_io_locals)
              GraphNode::Recipe.trace_locals(block, inv) { block.call(*args) }
            else
              GraphNode::Recipe.trace_locals_tracepoint(block, inv) { block.call(*args) }
            end
          }
          locals = inv.locals.each_with_object({}.compare_by_identity) { |(k, v), h|
            h[v] = k.to_s if GraphNode::Recipe.graph_object?(v) && !args.any? { |a| a.equal?(v) } && !h.key?(v)
          }
          [result, locals]
        rescue StandardError => e
          @problems << "#{what} couldn't be built to save it (#{e.class}: #{e.message})"
          nil
        end

        # `head { |params| body }` for a block that built +result+.
        def block_lines(head, _opts, params, result, inputs, locals)
          writer = writer_for(result, inputs, locals)
          text = writer.to_s
          collect(writer, head)
          body = text.lines(chomp: true).reject { |l| l.start_with?('# inputs:') }
          ["#{head} { |#{params.join(', ')}|", *body.map { |l| "  #{l}" }, '}']
        end

        # `head graph, opts` with the graph's variables first.
        def graph_statement(head, graph, opts)
          writer = writer_for(graph, {}, {})
          vars, expr = writer.parts
          collect(writer, head)
          expr = expr.dup
          expr[0] = "#{head}, #{expr[0]}"
          expr[-1] = [expr[-1], *opts].join(', ')
          vars + expr
        end

        def writer_for(root, inputs, locals)
          named = (@clip_names || {}).each_with_object({}) { |(obj, n), h| h[n] = obj unless inputs.values.any? { |i| i.equal?(obj) } || root.equal?(obj) }
          GraphNode::Recipe::RubyWriter.new(
            root, inputs: named.merge(inputs.transform_keys(&:to_s)), seeds: true, knob_nodes: @knob_nodes, assets: @assets, locals: locals
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
            writer = writer_for(c, {}, {})
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
            if sc.block
              @warnings << "scene #{name.inspect} has a block (code run at launch), which set documents can't hold; it was saved without it"
            end
            parts = [name.inspect]
            sc.values.each do |k, v|
              parts << "#{@lit.key_text(k)} #{scene_value(name, k, v)}"
            end
            parts << "q: #{lit(sc.q)}" if sc.q
            parts << "fade: #{lit(sc.fade)}" if sc.fade
            parts << "others: #{lit(sc.others)}" unless sc.others == :stop
            ["scene #{parts.join(', ')}"]
          }
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
