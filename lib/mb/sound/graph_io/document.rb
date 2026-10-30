require 'digest'
require 'time'

module MB
  module Sound
    module GraphIO
      # A graph document's header and the objects a load bound: the format
      # version and metadata (`graph 2, name: ..., saved: ...`), the inputs
      # (`inputs :midi`), and the knobs (`param :drive, 1.0, range: ...`).
      # GraphIO.document_of(graph) returns the Document of a loaded graph,
      # and GraphIO.dump reuses it when the graph is saved again.
      class Document
        # Header calls, in order: graph first, then inputs (typed since
        # format 4: `inputs sig: :audio, side: :audio`), outputs (format 4,
        # optional: `outputs :audio`), params, knobs, and a bundle's assets.
        HEADER = %i[graph inputs outputs param knob clock asset].freeze

        # The rack kinds (MB::Sound::Rack#kind) a rack document's `kind:`
        # takes.
        RACK_KINDS = %i[note_fx instrument effect listener modulator].freeze

        # Options of a param (MIDI::ControlSpec-shaped: range, description,
        # cc number, curve; unit is informational).
        PARAM_KEYS = %i[range description cc curve unit clamp].freeze

        # Options of a knob (GraphNode::Knob::Spec, as the console's `knob`
        # command takes them, plus a description).
        KNOB_KEYS = %i[range curve unit cc takeover smooth description clamp].freeze

        # Options only a rack document's knob lines (its knobs) take (see
        # MB::Sound::RackMethods#rack_knob).
        RACK_KNOB_KEYS = %i[share follow].freeze

        # Metadata keys GraphIO.dump writes (others are kept as given).
        META_KEYS = %i[name kind saved mb_sound from options].freeze

        attr_accessor :format, :meta, :inputs, :params, :path, :knob_nodes, :input_objects

        # The MB::Sound::Param of a `param` line named +name+ with +value+
        # and header keywords +spec+ (range:, description:, cc:, curve:,
        # unit:).  A range written high to low (an inverted controller's,
        # saved by older scripts) declares the span low to high; documents
        # keep it as written.
        def self.declaration(name, value, spec)
          opts = spec.slice(*PARAM_KEYS)
          r = opts[:range]
          if r.is_a?(Range) && r.begin.is_a?(Numeric) && r.end.is_a?(Numeric) && r.begin > r.end
            opts[:range] = r.end..r.begin
          end
          MB::Sound::Param.declare(name, value, **opts)
        end

        # The declared params: { name => MB::Sound::Param } (param and knob
        # lines alike).
        def declarations
          @params.to_h { |k, spec| [k, spec[:param] || Document.declaration(k, spec[:value], spec)] }
        end

        # Clocks the graph's clips play on (`clock :tide, 31.1.seconds`,
        # time-automation): { name => { base:, speed: } }, defined in the
        # Session that plays the graph (Session::Clocks#adopt_clocks).
        def clocks
          @clocks ||= {}
        end

        # Port types of the inputs ({ sig: :audio, side: :audio }; format 4
        # writes them, older documents' `inputs :midi` are :notes, others
        # :audio), the defaults of optional ports ({ depth: 0.5 }), and the
        # output types (`outputs :audio`; empty when not written).
        attr_accessor :input_types, :input_defaults, :outputs

        # A rack document's Rack, once loaded (see #rack?).
        attr_accessor :rack

        # A bundle's assets: SHA-256 sums by file name (`asset
        # "assets/pad.flac", sha256: "..."`), checked when the files are read.
        attr_reader :assets

        # Set documents: the Session the set was loaded into, and the flow
        # (a Form, not playing: `play_form doc.form`), or nil.
        attr_accessor :session, :form

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
          @input_types = {}
          @input_defaults = {}
          @outputs = []
          @rack = nil
          @comment_inputs = nil
          @assets = {}
          @verified = {}
        end

        # Checks asset +name+ (read from +real+, its real path) against its
        # SHA-256 sum, if the header lists it (see FileGuard).  Raises
        # FileError if the file changed.
        def verify(name, real)
          sum = @assets[name]
          return unless sum

          stat = File.stat(real)
          key = [real, stat.size, stat.mtime]
          return if @verified[name] == key

          actual = Digest::SHA256.file(real).hexdigest
          unless actual == sum
            raise FileError.new("asset #{name.inspect} doesn't match the document (SHA-256 #{actual[0, 12]}..., expected #{sum[0, 12]}...): the file changed since the bundle was saved")
          end
          @verified[name] = key
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

        # True for a rack document (`graph 4, ..., rack: :arack`): loading it
        # gives a Rack (applied when its inputs are given), and its knob
        # lines are the rack's knobs.
        def rack?
          !@meta[:rack].nil?
        end

        # What the graph is and where it came from (the header's
        # `description:`, e.g. from a script's synth_script description),
        # or nil.
        def description
          @meta[:description]
        end

        # Sets param +name+ of a loaded graph to +value+ (every Constant
        # made for it, landing at the next buffer; a knob turns there,
        # gliding over its Spec's +smooth+ time).  Returns value.
        def set(name, value)
          name = name.to_sym
          raise ArgumentError, "no param #{name}#{GraphIO.suggest(name, @params.keys)}" unless @params.key?(name)
          if (b = @params[name][:bound])
            raise ArgumentError, "param #{name} was bound to #{b.is_a?(Symbol) ? "knob #{b.inspect} (turn #{b.inspect} instead)" : 'a node when loaded'}"
          end
          # (a typed value, 3000.hz for a frequency param: its base-unit number)
          value = MB::Sound::Param.magnitude(value) unless value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels)
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
          if kind == :set && @session
            a = @session.arrangement
            return "#<GraphIO::Document #{name.inspect} set: tracks #{a.tracks.keys.join(', ')}; scenes #{a.scenes.keys.join(', ')}#{'; a flow (play_form doc.form)' if @form}>"
          end
          "#<GraphIO::Document #{name.inspect} inputs: #{@inputs.inspect} params: #{param_values.inspect}>"
        end
        alias to_s inspect
      end

      # Writes graph documents (see GraphIO.dump).
      class Writer
        def initialize(graph, name: nil, kind: nil, inputs: {}, params: {}, options: {}, from: nil, meta: {}, assets: nil)
          @graph = graph
          @assets = assets
          @doc = GraphIO.document_of(graph)
          @name = name || @doc&.name
          @kind = kind || @doc&.kind || guess_kind(inputs)
          @inputs = inputs.transform_keys(&:to_sym)
          @inputs = @doc.input_objects.merge(@inputs) if @doc && @inputs.empty?
          @params = normalize_params(params.empty? && @doc ? @doc.params : params)
          @options = options
          @options = @doc.meta[:options] || {} if @doc && options.empty?
          @from = from || @doc&.meta&.[](:from)
          @meta = (@doc ? @doc.meta.slice(:description, :tags) : {}).merge(meta) # (a loaded document keeps its description)
        end

        # The document text.  Raises GraphIO::DumpError if part of the graph
        # can't be written (the writer's FIXMEs).
        def to_s
          plain = @params.reject { |_, spec| spec[:knob] }
          knobs = plain.transform_keys(&:to_s).transform_values { |s| s[:value] }
          knob_nodes = (@doc&.knob_nodes || {}).each_with_object({}.compare_by_identity) { |(n, nodes), h| nodes.each { |node| h[node] = n.to_s } }
          graph_knobs, knob_problems = self.graph_knobs
          graph_knobs.each { |name, k| knob_nodes[k] = name.to_s }
          writer = GraphNode::Recipe::RubyWriter.new(@graph, inputs: @inputs, seeds: :marked, knobs: knobs, knob_nodes: knob_nodes, assets: @assets, define_racks: true)
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
          known = @doc&.input_types || {}
          header << GraphIO.inputs_line(writer.inputs.to_h { |n, o| [n, known[n.to_sym] || GraphIO.input_type(o)] }) unless writer.inputs.empty?
          knob_params.each { |k, spec| header << param_line(writer, k, spec) }
          graph_knobs.each do |name, k|
            next unless used.include?(name.to_s)
            header.concat(knob_lines(writer, k))
          end
          writer.clocks_used.each do |name|
            c = MB::Sound::Session.existing&.clock_named(name)
            spec = @doc&.clocks&.[](name)
            if c
              header << "clock #{[name.inspect, *c.line_args].join(', ')}"
            elsif spec
              header << "clock #{[name.inspect, MB::Sound::Clock.base_ruby(spec[:base]), *(spec[:speed].nil? || spec[:speed] == 1 ? [] : ["speed: #{spec[:speed].inspect}"])].join(', ')}"
            else
              raise DumpError.new("can't save this graph yet: its clips play on clock #{name.inspect}, which isn't defined (clock #{name.inspect}, 19.7.seconds)", problems: ["clock #{name.inspect} isn't defined"], code: body)
            end
          end
          (@assets&.entries || []).each do |e|
            header << "asset #{e.name.inspect}#{", sha256: #{e.sha256.inspect}" if e.sha256}"
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
              k = ValueSource.knob_of(n) or next
              # A rack's knobs print inside its block (knob(:space, ...))
              next if k.rack_knob

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
          parts = spec.call_args(value: value, cc: knob.cc, literal: writer.method(:literal))
          desc = @params.dig(knob.name, :description) || spec.param.description
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
          GraphIO.graph_line(parts)
        end

        # The `param` line: the MB::Sound::Param of +spec+ (a loaded line's,
        # else declared here, which checks it) written at the current value.
        def param_line(writer, name, spec)
          decl = spec[:param] || Document.declaration(name.to_sym, spec[:value], spec)
          decl.document_line(spec[:value], writer: writer)
        end
      end
    end
  end
end
