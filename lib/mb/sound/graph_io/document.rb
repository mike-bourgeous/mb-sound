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
        # Header calls, in order: graph first, then inputs and params.
        HEADER = %i[graph inputs param].freeze

        # Options of a param (MIDI::ControlSpec-shaped: range, description,
        # cc number, curve; unit is informational).
        PARAM_KEYS = %i[range description cc curve unit].freeze

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
        # made for it; the change lands at the next buffer).  Returns value.
        def set(name, value)
          name = name.to_sym
          raise ArgumentError, "no param #{name}#{GraphIO.suggest(name, @params.keys)}" unless @params.key?(name)
          (@knob_nodes[name] || []).each { |c| c.constant = value }
          @params[name][:value] = value
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
          knobs = @params.transform_keys(&:to_s).transform_values { |s| s[:value] }
          knob_nodes = (@doc&.knob_nodes || {}).each_with_object({}.compare_by_identity) { |(n, nodes), h| nodes.each { |node| h[node] = n.to_s } }
          writer = GraphNode::Recipe::RubyWriter.new(@graph, inputs: @inputs, seeds: true, knobs: knobs, knob_nodes: knob_nodes)
          body = writer.to_s
          moving = moving_knobs
          unless moving.empty?
            writer.problems << "knob #{moving.map(&:inspect).join(', ')} has moves (ramps, follows, or queued changes), and documents keep only knob values for now"
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
          knob_params = @params.select { |k, _| used.include?(k.to_s) }
          baked = @params.reject { |k, _| used.include?(k.to_s) }.transform_values { |s| s[:value] }
          options = @options.merge(baked)

          header = []
          header << '# mb-sound graph document: a Ruby subset that MB::Sound.preset and'
          header << '# MB::Sound::GraphIO.load read without running it (no eval).'
          header << graph_line(writer, options)
          input_names = writer.inputs.keys
          header << "inputs #{input_names.map { |n| ":#{n}" }.join(', ')}" unless input_names.empty?
          knob_params.each { |k, spec| header << param_line(writer, k, spec) }
          (header + [''] + lines).join("\n") + "\n"
        end

        private

        # Names of the graph's knobs that ramp, follow, or have changes
        # queued; a document can only keep their values.
        def moving_knobs
          return [] unless @graph.respond_to?(:graph)

          @graph.graph.filter_map { |n|
            k = n.is_a?(GraphNode::Knob::Reader) ? n.knob : n
            k.spec.name if k.is_a?(GraphNode::Knob) && k.moving?
          }.uniq
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
