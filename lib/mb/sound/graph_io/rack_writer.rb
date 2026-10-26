require 'time'

module MB
  module Sound
    module GraphIO
      # Writes rack documents (GraphIO.dump of a MB::Sound::Rack; racks R2,
      # proposal 2.8): a graph document whose inputs are the rack's ports,
      # whose knob lines are its knobs, and whose body is the rack's block
      # as the recorder prints it, built once on stand-ins for the ports
      # (Rack#build_on_stand_ins).
      #
      #     graph 4, name: "dub", kind: :effect, rack: :arack, saved: ...
      #     inputs sig: :audio, side: :audio
      #     outputs :audio
      #     knob :space, 0.3
      #
      #     sig.duck(side).delay(3.n16, feedback: space * 0.6, wet: space)
      #
      # GraphIO.load gives the Rack back (each application makes its own
      # knobs from the knob lines), or applies it when inputs are given.
      class RackWriter
        def initialize(rack, name: nil, from: nil, meta: {}, assets: nil)
          raise DumpError.new("#{rack.label} is composed (>>); save its parts") if rack.composed?

          @rack = rack
          @doc = GraphIO.rack_document(rack)
          @name = name || @doc&.name || rack.name&.to_s
          @from = from || @doc&.meta&.[](:from)
          @meta = (@doc ? @doc.meta.slice(:description, :tags) : {}).merge(meta)
          @assets = assets
        end

        def to_s
          result, stand, app = @rack.build_on_stand_ins
          rack_knobs = app.knobs
          knob_nodes = rack_knobs.each_with_object({}.compare_by_identity) { |(n, k), h| h[k] = n.to_s }
          inputs = stand.transform_keys(&:to_s)
          # (no seeds: each application of a rack draws its own)
          writer = GraphNode::Recipe::RubyWriter.new(result, inputs: inputs, seeds: false, knob_nodes: knob_nodes, assets: @assets, define_racks: true)
          body = writer.to_s
          problems = writer.problems.dup
          if (clash = rack_knobs.keys.find { |n| stand.key?(n) })
            problems << "knob #{clash.inspect} has the name of a port"
          end
          unless problems.empty?
            raise DumpError.new("can't save this rack yet: #{problems.uniq.join('; ')}", problems: problems.uniq, code: body)
          end

          lines = body.lines(chomp: true)
          lines.shift while lines.first&.start_with?('# inputs:')

          out = @rack.out || Rack.output_type(result)
          fields = {}
          fields[:name] = @name.to_s if @name
          fields[:kind] = @rack.kind(out)
          fields[:rack] = @rack.constructor
          fields[:saved] = Time.now.utc.iso8601
          fields[:mb_sound] = GraphIO.library_version
          fields[:from] = @from if @from
          fields.merge!(@meta.reject { |k, _| fields.key?(k) })

          header = []
          header << '# mb-sound rack document: a Ruby subset that MB::Sound.preset and'
          header << '# MB::Sound::GraphIO.load read without running it (no eval).'
          header << GraphIO.graph_line(fields.map { |k, v| "#{k}: #{writer.literal(v)}" })
          defaults = @rack.port_defaults
          types = { @rack.input.name => @rack.input.type }
          @rack.ports.each_value { |p| types[p.name] = p.required ? p.type : [p.type, defaults[p.name]] }
          header << GraphIO.inputs_line(types)
          header << "outputs #{out.inspect}" if out
          rack_knobs.each do |n, k|
            header << "knob #{GraphNode::Recipe::RubyWriter.knob_args(k, writer.method(:literal), name: n).join(', ')}"
          end
          (@assets&.entries || []).each do |e|
            header << "asset #{e.name.inspect}#{", sha256: #{e.sha256.inspect}" if e.sha256}"
          end
          (header + [''] + lines).join("\n") + "\n"
        end
      end
    end
  end
end
