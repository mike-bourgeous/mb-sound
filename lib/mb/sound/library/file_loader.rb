module MB
  module Sound
    module Library
      # Reads a library file: Ruby on a shelf (presets/fx/reverb.rb,
      # presets/ins/reese.rb, any file name) holding entries one statement
      # each, read like a graph document (Prism-walked through
      # GraphIO::Loader's rules: values, recorded DSL calls, build blocks;
      # no eval, no flow control):
      #
      #     library 1                                   # the format (optional)
      #     reverb :big_plate, room_size: 0.6, decay: 3.5, damping: 0.4, seed: 2,
      #       tags: %i[bright big], about: 'A big bright plate'
      #     chorus :slow_juno, rates: [0.3], min: 0.00166, max: 0.00535, tags: %i[gentle]
      #     instrument :glass_keys, tags: %i[keys bright], about: 'Two detuned triangles' do |midi|
      #       cut = knob :cut, (300.hz..8000.hz).at(2400.hz)
      #       midi.synth { |v| (v.hz.triangle + v.hz.transpose(0.07).triangle).lp4(cut) * v.amp_env * 0.3 }
      #     end
      #     chain :dub, tags: %i[echo] do |sig|
      #       sig + sig.delay(3.n16, feedback: 0.4, wet: 0.3)
      #     end
      #     clip :walk_a, seq(A2, C3, E3, G3).n8.loop, tags: %i[bass walking]
      #
      # The verbs: every Presettable family (reverb, chorus, resonator,
      # envelope, env_curve, lofi, squeeze, mastering, sq80; the line a
      # class body uses), +instrument+ (an irack: notes in, audio out),
      # +chain+ (an arack: an effect chain), +note_fx+ (an mrack), and
      # +clip+.  Each takes +tags:+ and +about:+; racks take port
      # declarations like their constructors (`chain :pump, side: :audio
      # do |sig, side:| ... end`) and knobs inside (`knob :space, 0.3`).
      # Local variables may hold values shared by later lines.
      class FileLoader < GraphIO::Loader
        # Rack verbs: [rack constructor, main input type, output type].
        RACKS = {
          instrument: [:irack, :notes, :audio],
          chain: [:arack, :audio, nil],
          note_fx: [:mrack, :notes, nil],
        }.freeze

        # Keywords every entry line takes.
        ENTRY_KEYS = %i[tags about facets aliases].freeze

        # The entries of the library file at +path+ on +shelf+ (an Array).
        def self.load(path, shelf:)
          new(File.read(path), path: path).entries(shelf)
        end

        # Parses the file and returns its entries.  Raises GraphIO::LoadError
        # (with the line) for anything outside the format.
        def entries(shelf)
          tree = parse
          @document = GraphIO::Document.new(path: @path)
          @shelf = shelf
          fresh_limits!
          scope = Scope.new
          @assigns = {}
          stmts = tree.statements.body
          out = []
          stmts.each_with_index do |st, i|
            if st.is_a?(Prism::CallNode) && st.receiver.nil? && st.name == :library
              raise error(st, 'library goes first') unless i == 0
              v = st.arguments&.arguments&.first
              version = v.is_a?(Prism::IntegerNode) ? v.value : nil
              raise error(st, "library needs a format version (library #{Library::FORMAT})") unless version
              raise error(st, "the file is library format #{version}, newer than this mb-sound reads (#{Library::FORMAT}); update mb-sound") if version > Library::FORMAT
              next
            end
            if st.is_a?(Prism::LocalVariableWriteNode)
              eval_node(st, scope)
              @assigns[st.name] = st.slice
              next
            end
            unless st.is_a?(Prism::CallNode) && st.receiver.nil? && verb?(st.name)
              raise error(st, "a library file holds entries (#{verbs.join(', ')}) and local variables#{GraphIO.suggest(st.respond_to?(:name) ? st.name : '', verbs)}")
            end
            out << entry(st, scope)
          end
          @loaded = true
          out
        end

        private

        def verbs
          Library.families.values.select { |f| f.owner.is_a?(Module) && f.owner.respond_to?(:preset_family_name) }.map(&:name) + RACKS.keys + [:clip]
        end

        def verb?(name)
          RACKS.key?(name) || name == :clip || (f = Library.families[name]) && f.owner.respond_to?(:preset_family_name)
        end

        def entry(node, scope)
          args, kwargs = call_args(node, scope)
          name = args.shift
          raise error(node, "#{node.name} needs a name (#{node.name} :name, ...)") unless name.is_a?(Symbol)
          raise error(node, "#{name}: entry names are words (#{name.inspect})") unless name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
          meta = kwargs.slice(*ENTRY_KEYS)
          kwargs = kwargs.except(*ENTRY_KEYS)
          tags = Array(meta[:tags])
          raise error(node, "#{name}: tags: are words (%i[dark wide])") unless tags.all? { |t| t.is_a?(Symbol) || t.is_a?(String) }
          about = meta[:about]
          raise error(node, "#{name}: about: is a String") unless about.nil? || about.is_a?(String)
          location = "#{@path}:#{node.location.start_line}"
          common = { name: name, tags: tags, about: about && String.new(about), facets: meta[:facets] || {}, shelf: @shelf, location: location, source: source_of(node) }

          if RACKS.key?(node.name)
            rack_entry(node, scope, name, args, kwargs, common)
          elsif node.name == :clip
            raise error(node, "clip #{name} needs a clip (clip :#{name}, seq(C3, E3).n8)") unless args.length == 1 && kwargs.empty? && node.block.nil?
            value = args[0]
            raise error(node, "clip #{name}: #{describe(value)} isn't a clip") unless value.is_a?(MB::Sound::Sequence::Clip) || value.respond_to?(:to_clip)
            value = value.named(name) if value.respond_to?(:named) && value.respond_to?(:name) && value.name.nil?
            Entry.new(kind: :clip, family: :clip, builder: ->(*) { value }, **common)
          else
            raise error(node, "#{node.name} #{name}: settings are keywords (#{node.name} :#{name}, decay: 3)") unless args.empty?
            raise error(node, "#{node.name} #{name} takes no block") if node.block
            owner = Library.families[node.name].owner
            keys = owner.preset_keys
            if keys && !(bad = kwargs.keys - keys).empty?
              raise error(node, "#{node.name} #{name.inspect}: unknown setting#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{GraphIO.suggest(bad[0], keys)}")
            end
            family = node.name
            Array(meta[:aliases]).each { |a| Library.index.add_alias(family, a, name) }
            Entry.new(
              kind: Library.families[family].kind, family: family, settings: kwargs,
              params: -> { PresetHelpers.params_for(owner.preset_params, kwargs) },
              builder: PresetHelpers.builder(family, name), **common
            )
          end
        end

        # The statement's text, after the top-level local variables it
        # reads (what collect and promote copy).
        def source_of(node)
          reads = []
          stack = [node]
          until stack.empty?
            n = stack.pop
            reads << n.name if n.is_a?(Prism::LocalVariableReadNode)
            n.compact_child_nodes.each { |c| stack << c }
          end
          used = @assigns.select { |k, _| reads.include?(k) }.values
          (used + [node.slice]).join("\n")
        end

        def rack_entry(node, scope, name, args, kwargs, common)
          ctor, main, out = RACKS[node.name]
          raise error(node, "#{node.name} #{name} needs a block (#{node.name} :#{name} do |#{main == :audio ? 'sig' : 'midi'}| ... end)") unless node.block.is_a?(Prism::BlockNode)
          raise error(node, "#{node.name} #{name}: ports are keywords (side: :audio)") unless args.empty?
          block = build_proc(node.block, scope)
          rack = begin
            Rack.new(name, in: main, out: out, constructor: ctor, block: block, ports: kwargs, quiet: true)
          rescue ArgumentError => e
            raise error(node, "#{node.name} #{name}: #{e.message}")
          end
          path = @path
          params = -> { Library.rack_params(node.block) }
          Entry.new(
            kind: Library.rack_kind(rack), family: :preset, settings: { rack: ctor, ports: kwargs }, params: params,
            builder: ->(*a, **k, &b) { Library.place(rack, source: path).call(*a, **k, &b) }, **common
          ).tap { |e| Library.remember_rack(e, rack) }
        end
      end
    end
  end
end
