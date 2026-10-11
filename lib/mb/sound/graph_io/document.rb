require 'time'

module MB
  module Sound
    module GraphIO
      # A graph document's header and the objects a load bound: the format
      # version and metadata (`graph 1, name: ..., saved: ...`), the inputs
      # (`inputs :midi`), and the knobs (`param :drive, 1.0, range: ...`).
      # GraphIO.document_of(graph) returns the Document of a loaded graph,
      # and GraphIO.dump reuses it when the graph is saved again.
      class Document
        # Header calls, in order: graph first, then inputs, params, and
        # knobs.
        HEADER = %i[graph inputs param knob].freeze

        # Options of a param (MIDI::ControlSpec-shaped: range, description,
        # cc number, curve; unit is informational).
        PARAM_KEYS = %i[range description cc curve unit].freeze

        # Options of a knob (GraphNode::Knob::Spec, as the console's `knob`
        # command takes them, plus a description).
        KNOB_KEYS = %i[range curve unit cc takeover smooth description].freeze

        # Metadata keys GraphIO.dump writes (others are kept as given).
        META_KEYS = %i[name kind saved mb_sound from options].freeze

        attr_accessor :format, :meta, :inputs, :params, :path, :knob_nodes, :input_objects

        # The Constants made for each param ({ name => [Constant, ...] }).
        # attr_accessor :knob_nodes (above)

        # Inputs named by a `# inputs: a, b` comment (to_ruby's header),
        # for documents without an inputs line.
        attr_reader :comment_inputs

        def initialize(path: nil)
          @path = path
          @format = GraphIO::FORMAT
          @meta = {}
          @inputs = []
          @params = {}
          @knob_nodes = {}
          @input_objects = {}
          @comment_inputs = nil
        end

        # Reads `# inputs: midi` from the leading comments (+comments+ are
        # [line, text] pairs).
        def read_comments(comments)
          comments.each do |_line, text|
            if (m = text.match(/\A#\s*inputs:\s*(.+)\z/))
              @comment_inputs = m[1].split(',').map { |s| s.strip.to_sym }
              break
            end
          end
        end

        # The document's name (from its header, else its file name).
        def name
          @meta[:name] || (@path && File.basename(@path).delete_suffix(GraphIO::EXTENSION))
        end

        # :effect, :synth, :graph, ... (informational).
        def kind
          @meta[:kind]
        end

        # Sets param +name+ of a loaded graph to +value+ (every Constant
        # made for it, landing at the next buffer; a knob turns there,
        # gliding over its Spec's +smooth+ time).  Returns value.
        def set(name, value)
          name = name.to_sym
          raise ArgumentError, "no param #{name}#{GraphIO.suggest(name, @params.keys)}" unless @params.key?(name)
          (@knob_nodes[name] || []).each { |c|
            c.is_a?(GraphNode::Knob) ? c.set(value, frame: c.next_frame) : c.constant = value
          }
          @params[name][:value] = value
        end

        # True if param +name+ is a knob (a `knob` line, loading as a
        # GraphNode::Knob).
        def knob?(name)
          !!@params.fetch(name.to_sym)[:knob]
        end
        alias []= set

        # A param's current value.
        def [](name)
          @params.fetch(name.to_sym)[:value]
        end

        # Param defaults (or the values a load used), by name.
        def param_values
          @params.transform_values { |s| s[:value] }
        end

        def inspect
          "#<GraphIO::Document #{name.inspect} inputs: #{@inputs.inspect} params: #{param_values.inspect}>"
        end
        alias to_s inspect
      end

      # Writes graph documents (see GraphIO.dump).
      class Writer
        def initialize(graph, name: nil, kind: nil, inputs: {}, params: {}, options: {}, from: nil, meta: {})
          @graph = graph
          @doc = GraphIO.document_of(graph)
          @name = name || @doc&.name
          @kind = kind || @doc&.kind || guess_kind(inputs)
          @inputs = inputs.transform_keys(&:to_sym)
          @inputs = @doc.input_objects.merge(@inputs) if @doc && @inputs.empty?
          @params = normalize_params(params.empty? && @doc ? @doc.params : params)
          @options = options
          @options = @doc.meta[:options] || {} if @doc && options.empty?
          @from = from || @doc&.meta&.[](:from)
          @meta = meta
        end

        # The document text.  Raises GraphIO::DumpError if part of the graph
        # can't be written (the writer's FIXMEs).
        def to_s
          plain = @params.reject { |_, spec| spec[:knob] }
          knobs = plain.transform_keys(&:to_s).transform_values { |s| s[:value] }
          knob_nodes = (@doc&.knob_nodes || {}).each_with_object({}.compare_by_identity) { |(n, nodes), h| nodes.each { |node| h[node] = n.to_s } }
          graph_knobs, knob_problems = self.graph_knobs
          graph_knobs.each { |name, k| knob_nodes[k] = name.to_s }
          writer = GraphNode::Recipe::RubyWriter.new(@graph, inputs: @inputs, seeds: true, knobs: knobs, knob_nodes: knob_nodes)
          body = writer.to_s
          writer.problems.concat(knob_problems)
          graph_knobs.each_key do |name|
            if plain.key?(name) || writer.inputs.key?(name.to_s)
              writer.problems << "knob #{name.inspect} has the name of a #{plain.key?(name) ? 'param' : 'input'}"
            end
          end
          unless writer.problems.empty?
            raise DumpError.new(
              "can't save this graph yet: #{writer.problems.uniq.join('; ')}",
              problems: writer.problems.uniq, code: body
            )
          end

          lines = body.lines(chomp: true)
          lines.shift while lines.first&.start_with?('# inputs:')
          used = writer.knobs_used
          knob_params = plain.select { |k, _| used.include?(k.to_s) }
          baked = plain.reject { |k, _| used.include?(k.to_s) }.transform_values { |s| s[:value] }
          options = @options.merge(baked)

          header = []
          header << '# mb-sound graph document: a Ruby subset that MB::Sound.preset and'
          header << '# MB::Sound::GraphIO.load read without running it (no eval).'
          header << graph_line(writer, options)
          input_names = writer.inputs.keys
          header << "inputs #{input_names.map { |n| ":#{n}" }.join(', ')}" unless input_names.empty?
          knob_params.each { |k, spec| header << param_line(writer, k, spec) }
          graph_knobs.each do |name, k|
            next unless used.include?(name.to_s)
            header.concat(knob_lines(writer, k))
          end
          (header + [''] + lines).join("\n") + "\n"
        end

        # The GraphNode::Knobs in the graph by name, and problems (two
        # knobs with one name).
        def graph_knobs
          found = {}
          problems = []
          roots = @graph.is_a?(Array) ? @graph : [@graph]
          roots.each do |root|
            next unless root.respond_to?(:graph)

            root.graph.each do |n|
              k = n.is_a?(GraphNode::Knob::Reader) ? n.knob : n
              next unless k.is_a?(GraphNode::Knob)

              if (other = found[k.name]) && !other.equal?(k)
                problems << "two different knobs are named #{k.name.inspect}"
              else
                found[k.name] = k
              end
            end
          end
          [found, problems.uniq]
        end

        private

        # The `knob` header line for +knob+ (as the console's `knob`
        # command takes it, with the knob's held value), after a comment
        # if the knob was moving: documents keep a knob's value, not its
        # moves (takes replay those), so a moving knob saves the value on
        # the last frame it rendered.
        def knob_lines(writer, knob)
          lines = []
          value = knob.moving? ? knob.value : knob.target
          if knob.moving?
            what = case knob.mode
                   when :ramp then "ramping to #{GraphNode::Knob.number(knob.target)}"
                   when :follow then "following #{GraphNode::Knob.label_of(knob.following)}"
                   else 'about to move (changes queued)'
                   end
            lines << "# #{knob.name.inspect} was #{what} when saved; documents keep knob values, so it holds #{GraphNode::Knob.number(value)}"
          end
          spec = knob.spec
          parts = [knob.name.inspect, writer.literal(value)]
          parts << "range: #{writer.literal(spec.range)}" unless spec.range == (0.0..1.0)
          parts << "curve: #{spec.curve.inspect}" unless spec.curve == :linear
          parts << "unit: #{writer.literal(spec.unit)}" if spec.unit
          cc = knob.cc
          parts << "cc: #{cc}" if cc
          parts << "takeover: #{spec.takeover.inspect}" unless spec.takeover == :pickup
          parts << "smooth: #{writer.literal(spec.smooth)}" unless spec.smooth == Session::Fades::DECLICK_SECONDS
          desc = @params.dig(knob.name, :description)
          parts << "description: #{writer.literal(desc)}" if desc
          lines << "knob #{parts.join(', ')}"
        end

        def guess_kind(inputs)
          keys = inputs.keys.map(&:to_sym)
          return :synth if keys.include?(:midi)
          return :effect if keys.include?(:input)
          :graph
        end

        def normalize_params(params)
          params.to_h { |k, v|
            spec = v.is_a?(Hash) ? v.dup : { value: v }
            [k.to_sym, spec]
          }
        end

        def graph_line(writer, options)
          fields = {}
          fields[:name] = @name.to_s if @name
          fields[:kind] = @kind if @kind
          fields[:saved] = Time.now.utc.iso8601
          fields[:mb_sound] = GraphIO.library_version
          fields[:from] = @from if @from
          fields.merge!(@meta.reject { |k, _| fields.key?(k) })
          fields[:options] = options unless options.empty?
          parts = fields.map { |k, v| "#{k}: #{writer.literal(v)}" }
          line = "graph #{GraphIO::FORMAT}, #{parts.join(', ')}"
          return line if line.length <= 120

          "graph #{GraphIO::FORMAT},\n  #{parts.join(",\n  ")}"
        end

        def param_line(writer, name, spec)
          extras = spec.slice(*Document::PARAM_KEYS).compact.map { |k, v| "#{k}: #{writer.literal(v)}" }
          ["param #{name.to_sym.inspect}, #{writer.literal(spec[:value])}", *extras].join(', ')
        end
      end
    end
  end
end
