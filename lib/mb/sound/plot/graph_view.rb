module MB
  module Sound
    module Plot
      # Draws a node graph by rank (design/notes/drawing.md): walks +node+
      # (a GraphNode, MIDI stream, or anything Traversable; a bundle draws
      # every channel) into a Plot::Graph.  Reads settings only (#sources,
      # #port_info, names, recipes), never samples.
      #
      # +ports+ ({ name => node }) names nodes drawn as a rack's input
      # ports (boxes at the left edge); +out+ adds an output box at the
      # right fed by the roots; +title+ a line above the drawing;
      # +max_boxes+ stops the walk (the inputs left unwalked show "…").
      #
      #     MB::Sound::Plot.graph(110.hz.saw.filter(:lowpass, cutoff: 800)).show
      #     110.hz.saw.lp4(1200).draw     # the same, as a node method
      def self.graph(node, ports: nil, out: false, title: nil, max_boxes: GraphView::MAX_BOXES)
        GraphView.new(node, ports: ports, out: out, title: title, max_boxes: max_boxes).graph
      end

      # The walk behind Plot.graph (mb-sound's side of the plot boundary).
      class GraphView
        # Boxes drawn at most (the walk stops; the rest is counted in the
        # drawing's note).
        MAX_BOXES = 300

        attr_reader :graph

        def initialize(node, ports: nil, out: false, title: nil, max_boxes: MAX_BOXES)
          @max = max_boxes
          @port_names = {}.compare_by_identity
          (ports || {}).each { |name, n| @port_names[key(n)[0]] = name }
          @ids = {}.compare_by_identity # node => box index
          @nodes = []
          @wires = []
          @boxes = []
          @dropped = 0
          roots = root_list(node, out)
          count_readers(roots)
          queue = []
          root_keys = roots.map { |r| key(r) }
          root_keys.each { |n, _| box_for(n, queue) }
          until queue.empty?
            n = queue.shift
            fill(n, queue)
          end
          if out
            ins = root_keys.each_with_index.map { |(n, _), k| Graph::Slot.new(name: root_keys.length > 1 ? :"in_#{k + 1}" : :in, type: output_type(n)) }
            o = @boxes.length
            @boxes << Graph::Box.new(title: 'out', ins: ins, outs: [], kind: :out)
            root_keys.each_with_index { |(n, idx), k| @wires << Graph::Wire.new(from: @ids[n], out: idx, to: o, in: k, type: output_type(n)) }
          end
          note = @dropped > 0 ? "(#{@dropped} more node#{'s' if @dropped != 1} not drawn: max_boxes #{@max})" : nil
          @graph = Graph.new(boxes: @boxes, wires: @wires, title: title, note: note)
        end

        private

        # The roots to draw: an Array's nodes, else the node; with an
        # +out+ box, a bundle's channels (each wired to the box).
        def root_list(node, out)
          return node if node.is_a?(Array)

          outs = out && node.respond_to?(:outputs) ? GraphView.outputs(node) : []
          outs.length > 1 ? outs : [node]
        end

        # [box node, output index] for graph value +x+: Tees, their
        # branches, and knob readers fold into what they read; outputs of
        # a multi-output node into the node and their index.
        def key(x)
          loop do
            case x
            when GraphNode::Tee::Branch, GraphNode::Tee
              x = x.original_source
            when GraphNode::Knob::Reader
              x = x.knob
            when GraphNode::NodeOutput
              owner = begin
                x.original_source
              rescue RuntimeError
                nil
              end
              return [x, 0] unless owner.is_a?(GraphNode::MultiOutput)

              outs = GraphView.outputs(owner)
              idx = outs.index { |o| o.equal?(x) } || 0
              return [owner, outs.length > 1 ? idx : 0]
            else
              return [x, 0]
            end
          end
        end

        # The input entries of box node +n+: [name, source, type, role,
        # active], its outputs' inputs included for multi-output nodes, its
        # own edges to and from its outputs left out.
        def inputs_of(n)
          list = entries(n).reject { |e| owned_output?(n, e[1]) }
          if n.is_a?(GraphNode::MultiOutput)
            outs = GraphView.outputs(n)
            if outs.any? { |o| o.is_a?(GraphNode::NodeOutput) && !o.is_a?(GraphNode::Tee::Branch) && !o.equal?(n) }
              outs.each do |o|
                next unless o.respond_to?(:input_port_info) && !o.equal?(n)

                entries(o).each { |e| list << e unless key(e[1])[0].equal?(n) }
              end
            end
          end
          # (the same input through several outputs shows once; other
          # inputs sharing a name get numbers)
          seen = {}
          names = Hash.new(0)
          list.filter_map { |name, src, type, role, active|
            k = [name, src.is_a?(Numeric) ? src : key(src)[0].__id__]
            next if seen[k]

            seen[k] = true
            names[name] += 1
            [names[name] > 1 ? :"#{name}_#{names[name]}" : name, src, type, role, active]
          }
        end

        def entries(n)
          return [] unless n.respond_to?(:sources)

          info = n.respond_to?(:input_port_info) ? n.input_port_info : n.sources.map { |k, v| { name: k, source: v, type: :audio, role: :main, active: true } }
          info.map { |e| [e[:name], e[:source], e[:type], e[:role], e[:active]] }
        rescue StandardError
          []
        end

        # True if +src+ is one of node +n+'s own outputs.
        def owned_output?(n, src)
          src.is_a?(GraphNode::NodeOutput) && !src.is_a?(GraphNode::Tee::Branch) && (src.original_source rescue nil).equal?(n)
        end

        # Counts the inputs reading each Constant, so a Constant read once
        # shows inline.
        def count_readers(roots)
          @readers = Hash.new(0).compare_by_identity
          seen = {}.compare_by_identity
          stack = roots.map { |r| key(r)[0] }
          until stack.empty?
            n = stack.pop
            next if seen[n] || seen.length > @max * 4

            seen[n] = true
            inputs_of(n).each do |_, src, *|
              next if src.is_a?(Numeric)

              k = key(src)[0]
              @readers[k] += 1
              stack << k
            end
          end
        end

        # A Constant (or number) shown inline on its reader's slot.
        def inline?(src)
          return true if src.is_a?(Numeric)

          k = key(src)[0]
          k.is_a?(GraphNode::Constant) && !@port_names.key?(k) && @readers[k] <= 1 && !named?(k)
        end

        # A sum's 0 or a product's 1 (left out: it changes nothing).
        def identity?(n, name, src)
          return false unless name == :constant && src.is_a?(Numeric)

          (n.is_a?(GraphNode::Mixer) && src == 0) || (n.is_a?(GraphNode::Multiplier) && src == 1)
        end

        def named?(n)
          n.respond_to?(:named?) && n.named?
        end

        def value_text(src)
          k = src.is_a?(Numeric) ? src : key(src)[0]
          v = k.is_a?(GraphNode::Constant) ? k.constant : k
          text = v.is_a?(Numeric) ? GraphView.number(v) : v.to_s
          unit = k.is_a?(GraphNode::Constant) ? k.unit : nil
          unit ? "#{text}#{unit.start_with?(' ') ? unit : " #{unit}"}" : text
        end

        def self.number(v)
          return v.to_s if v.is_a?(Integer)
          return v.to_s unless (v.is_a?(Float) || v.is_a?(Rational)) && v.finite?

          s = MB::M.sigfigs(v.to_f, 3)
          s == s.round && s.abs < 1e6 ? s.round.to_s : s.to_s
        end

        # The box index for node +n+ (made and queued for its inputs the
        # first time), or nil past max_boxes.
        def box_for(n, queue)
          return @ids[n] if @ids.key?(n)
          return nil if @boxes.length >= @max

          i = @boxes.length
          @ids[n] = i
          @nodes << n
          @boxes << nil # (filled by #fill, which knows the wires)
          queue << n
          i
        end

        # Makes node +n+'s box and the wires into it.
        def fill(n, queue)
          i = @ids[n]
          if (pname = @port_names[n])
            @boxes[i] = Graph::Box.new(title: pname.to_s, ins: [], outs: [Graph::Out.new(name: :out, type: output_type(n))], kind: :port)
            return
          end

          slots = []
          inputs_of(n).each do |name, src, type, role, active|
            fb = role == :feedback
            if src.nil?
              next
            elsif identity?(n, name, src)
              next
            elsif !fb && inline?(src)
              slots << Graph::Slot.new(name: name, type: type, value: value_text(src), feedback: false, active: active)
              next
            end

            k, idx = key(src)
            from = box_for(k, queue)
            if from.nil?
              @dropped += 1
              slots << Graph::Slot.new(name: name, type: type, value: '…', feedback: fb, active: active)
              next
            end
            slots << Graph::Slot.new(name: name, type: type, value: nil, feedback: fb, active: active)
            @wires << Graph::Wire.new(from: from, out: idx, to: i, in: slots.length - 1, type: type, feedback: fb, active: active)
          end
          # (feedback slots last: their wires come from below)
          order = slots.each_index.sort_by { |s| [slots[s].feedback ? 1 : 0, s] }
          unless order == slots.each_index.to_a
            moved = order.each_with_index.to_h { |old, new| [old, new] }
            slots = order.map { |s| slots[s] }
            @wires.map! { |w| w.to == i ? w.with(in: moved[w.in]) : w }
          end
          @boxes[i] = Graph::Box.new(title: GraphView.title(n), ins: slots, outs: outs_of(n), kind: :node)
        end

        # One output slot, or one per output of a multi-output node (as
        # #key numbers them).
        def outs_of(n)
          outs = n.is_a?(GraphNode::MultiOutput) ? GraphView.outputs(n) : []
          return [Graph::Out.new(name: :out, type: output_type(n))] if outs.length <= 1

          outs.each_with_index.map { |o, k| Graph::Out.new(name: :"out_#{k + 1}", type: o.equal?(n) ? output_type(n) : output_type(o)) }
        end

        def output_type(n)
          GraphNode::Traversable.port_type_of(n)
        end

        # A box's title in DSL words: its name, a knob's name, the
        # arithmetic's operator, the recipe's method, a tone's wave, else
        # its type in words (Traversable.words_of); never a class name.
        def self.title(n)
          t = title_words(n)
          t.to_s.strip.empty? ? class_words(n) : t
        end

        def self.title_words(n)
          return "knob #{n.name}" if n.is_a?(GraphNode::Knob)
          return n.graph_node_name.to_s if n.respond_to?(:named?) && n.named?
          return '×' if n.is_a?(GraphNode::Multiplier)
          return '+' if n.is_a?(GraphNode::Mixer)
          return n.operator.to_s if n.is_a?(GraphNode::BinaryOperation)
          return number(n.constant) if n.is_a?(GraphNode::Constant) && n.constant.is_a?(Numeric)

          # (a multi-output node's recipe is on the output the DSL returned)
          outs = n.is_a?(GraphNode::MultiOutput) ? outputs(n) : []
          name = ([n] + outs).lazy.filter_map { |x| recipe_name(x) }.first
          name ||= n.wave_type.to_s if n.is_a?(MB::Sound::Tone)
          return name if name

          words = GraphNode::Traversable.words_of(n, 0).split('/').last.split(/[:(]/).first.to_s.strip
          words.empty? || words == 'a node' ? class_words(n) : words
        rescue StandardError
          class_words(n)
        end

        # The last two parts of +n+'s class name in words ("midi stream",
        # "allocator lane"), for nodes with no type name of their own.
        def self.class_words(n)
          parts = n.class.name.to_s.split('::').last(2)
          parts.shift if parts.length > 1 && %w[Sound GraphNode].include?(parts[0])
          parts.join(' ').gsub(/([a-z\d])([A-Z])/, '\\1 \\2').downcase
        end

        # The outputs of multi-output node +n+ (none if it lists none).
        def self.outputs(n)
          Array(n.outputs.to_a)
        rescue NotImplementedError, StandardError
          []
        end

        # The DSL method that made +x+ (its recipe's call), or nil.
        def self.recipe_name(x)
          rec = x.instance_variable_defined?(:@graph_recipe) ? x.instance_variable_get(:@graph_recipe) : nil
          name = rec.respond_to?(:call) && rec.call.respond_to?(:name) ? rec.call.name.to_s : nil
          name if name&.match?(/\A[a-z_]\w*[?!]?\z/)
        end
      end
    end
  end
end
