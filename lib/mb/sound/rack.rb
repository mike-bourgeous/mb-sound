require 'did_you_mean'
require 'set'

module MB
  module Sound
    # A rack: a reusable piece of graph with typed ports, named or
    # anonymous (the racks project, phase R1; design/notes/racks.md).  A
    # Rack is a frozen value that behaves like a Proc: apply it to a real
    # source with Ruby's own verbs, and each application builds a fresh
    # subgraph from the block.
    #
    #     wobble = mrack { it.arp(:up, 16).echo(3.n16, 2, pitch: 7) }
    #     midi.then(&wobble).synth { |v| v.hz.saw * v.amp_env }
    #     wobble.(clip)                      # Proc-style
    #     clip.stream.through(wobble)        # Stream#through
    #
    #     arack :dub, side: :audio do |sig, side:|
    #       sig.duck(side).delay(3.n16, feedback: 0.4, wet: 0.3)
    #     end
    #     bass.then(&rack(:dub).with(side: :drums))   # a bus name as a port value
    #
    #     dreamy = wobble >> mrack { it.humanize(1.n64) }   # Proc#>> order
    #
    # Ports have three types (Traversable::PORT_TYPES): :notes (streams,
    # clips, Notes), :audio (nodes and bundles), and :control (nodes read as
    # values, numbers, knob names).  The main input's type is fixed by the
    # constructor (MB::Sound::RackMethods: mrack, irack, arack, lrack,
    # modrack, or rack(in:)); the output's type comes from what the block
    # returns, checked against +out:+ when given.  The main input and the
    # output give the rack's #kind (:note_fx, :instrument, :effect,
    # :listener, :modulator); extra ports never change it.
    #
    # Extra ports are declared in the constructor call (`keys: :notes`) and
    # taken as block keywords (`|sig, keys:|`); a mismatch raises when the
    # rack is defined, with did_you_mean.  A keyword with a default makes
    # its port optional (`|sig, depth: 0.5|`).  #with binds ports, returning
    # a new Rack; an unbound required port raises when applied (through
    # MB::Sound.live_error: live, the input passes through unchanged).
    #
    # The block gets the bound values themselves, coerced to the port's
    # type (a number on a control port becomes a constant, a Symbol on an
    # audio port reads that bus or track, on a control port that knob), so
    # no node sits at a port and plans fuse across rack edges.  A method a
    # port value doesn't have raises NoMethodError with a hint about the
    # port's type ("a notes port: streams carry notes; .synth makes audio")
    # as well as Ruby's did_you_mean suggestions.
    class Rack
      # The console constructors (MB::Sound::RackMethods), aliases included.
      CONSTRUCTORS = Set[
        :rack, :mrack, :note_rack, :irack, :instrument_rack, :arack, :audio_rack, :lrack, :amrack, :listener_rack,
        :modrack, :mod_rack,
      ].freeze

      # Kinds by [main input type, output type] (output nil: unknown yet).
      KINDS = {
        [:notes, :notes] => :note_fx, [:notes, :audio] => :instrument, [:notes, :control] => :instrument,
        [:audio, :audio] => :effect, [:audio, :notes] => :listener, [:audio, :control] => :listener,
        [:control, :audio] => :modulator, [:control, :control] => :modulator, [:control, :notes] => :modulator,
      }.freeze

      # The kind of a rack whose output isn't known before it is applied.
      DEFAULT_KINDS = { notes: :note_fx, audio: :effect, control: :modulator }.freeze

      # Parameter names that in: :auto reads as port types.
      AUTO_TYPES = {
        notes: %i[stream streams events notes midi keys clip seq],
        audio: %i[sig signal audio input inp mix side sidechain voice carrier],
        control: %i[ctl control mod amount depth cv value],
      }.freeze

      # Default name of the main input when the block's parameter has none
      # (`it`), by type: how racks print their blocks.
      MAIN_NAMES = { notes: :stream, audio: :sig, control: :ctl }.freeze

      # What a rack knob (MB::Sound::RackMethods#rack_knob) knows about where
      # it came from: the Rack, the knob's own name (:space), the
      # Application that made it (one per Rack#call; instances are told
      # apart by it), +share+ (joins the Session knob of its own name), and
      # +follow+ (the Session knob it follows through its own range), and
      # its description.
      KnobInfo = Data.define(:rack, :knob, :application, :share, :follow, :description) do
        # The rack's name, or nil for an anonymous rack.
        def rack_name
          rack&.name
        end
      end

      # What a rack pane (and `help rack(:x)`) shows of a rack or one of
      # its instances: a deep-frozen value, safe to hand to painter threads
      # (Session::Racks#rack_info, Rack#info).
      #
      # - name: the rack's name (Symbol) or nil
      # - path: the instance path (:"bass/dub", :dub) or nil for a rack
      #   not playing
      # - kind: :note_fx, :instrument, :effect, :listener, :modulator
      # - signature: "audio(sig) + audio(side) -> audio"
      # - ports: frozen Array of frozen Hashes { name:, type:, role:
      #   (:main or :side), required: }, the main input first
      # - latency: samples the rack delays its main input by (the longest
      #   path through nodes reporting #latency: dynamics lookahead,
      #   limiters), or nil if unknown
      # - knobs: frozen Array of the instance's Session knob names (a
      #   rack not playing: its knob names)
      # - knob_specs: frozen { knob name => Knob::Spec }
      # - slots: frozen Array (slots come in phase R3)
      RackInfo = Data.define(:name, :path, :kind, :signature, :ports, :latency, :knobs, :knob_specs, :slots) do
        def to_s
          "#{path || name || 'rack'} #{kind} #{signature}#{latency.to_i > 0 ? ", latency #{latency} samples" : ''}#{knobs.empty? ? '' : ", knobs #{knobs.join(', ')}"}"
        end
      end

      # A named rack in a document whose definition differs from the
      # session's rack of that name (see GraphIO.place_rack): the value a
      # chooser gets (the console prompt, #ask, or later a UI picker).
      # +options+ are the choices: :session (keep the session's rack),
      # :saved (replace it with the document's, for every later
      # application), :rename (load the document's as +rename_to+ for this
      # document only).
      Conflict = Data.define(:name, :session_rack, :saved_rack, :source, :rename_to) do
        def options
          Conflict::CHOICES
        end

        def to_s
          "rack #{name.inspect} in #{source.to_s.empty? ? 'the document' : source} differs from the session's"
        end

        # Asks on the console (one line): s, v, or r (Enter keeps the
        # session's).  Returns the choice, or nil without an answer.
        def ask(input: $stdin, output: $stdout)
          output.print "#{self}: keep the session's [s], replace it with the saved copy [v], or load the saved copy as #{rename_to.inspect} [r]? "
          output.flush
          case input.gets&.strip&.downcase
          when nil then nil
          when '', 's', 'session' then :session
          when 'v', 'saved' then :saved
          when 'r', 'rename' then :rename
          end
        end
      end
      Conflict::CHOICES = %i[session saved rename].freeze

      # Latencies of racks by Rack (identity; see #latency).
      LATENCIES = ObjectSpace::WeakMap.new

      # One application of a rack (Rack#call) while its block builds: the
      # knobs made so far by name.  Rack.application is the innermost one
      # on this thread.
      class Application
        attr_reader :rack, :knobs

        # Knob start values by name (see Rack#using).
        attr_reader :start

        def initialize(rack, start: {})
          @rack = rack
          @knobs = {}
          @start = start
        end

        def inspect
          "#<Rack::Application #{@rack.label} knobs: #{@knobs.keys.join(', ')}>"
        end
      end

      # A typed port: its name, type (:notes, :audio, :control), whether
      # it's required, and the main input or an extra port.  Port.for(type)
      # gives the class for a type; each coerces values given to it and
      # explains wrong-type method calls on its values.
      class Port
        attr_reader :name, :required

        def initialize(name, required: true, main: false)
          @name = name
          @required = required
          @main = main
          freeze
        end

        # The Port class for +type+.
        def self.for(type)
          { notes: Notes, audio: Audio, control: Control }.fetch(type) {
            raise ArgumentError, "Port types are :notes, :audio, or :control (got #{type.inspect})#{Rack.suggest(type, [:notes, :audio, :control])}"
          }
        end

        def main?
          @main
        end

        def type
          self.class::TYPE
        end

        # "audio(sig)", "notes(keys)".
        def to_s
          "#{type}(#{@name})"
        end

        def inspect
          "#<#{self.class.name.delete_prefix('MB::Sound::')} #{@name}#{' (optional)' unless @required}>"
        end

        # A hint for a NoMethodError of method +name+ on a value of this
        # port, or nil.
        def hint(_name)
          nil
        end

        # Raises TypeError for +value+ (got the wrong type).
        def mismatch(rack, value, want)
          got = GraphNode::Traversable.port_type_of(value)
          extra = Port.for(got).new(:x).cross_hint(type) if value.respond_to?(:sample) || got == :notes
          raise TypeError, "#{rack.label} port #{@name}: wants #{want}, got #{value.class.name || value.class} (#{got})#{"; #{extra}" if extra}"
        end

        # How to get from this type to +want+ (for errors).
        def cross_hint(want)
          nil
        end

        # Notes ports: Streams, Notes, Clips (as clip.notes, so every
        # stream transform and voice signal is there), Sources.
        class Notes < Port
          TYPE = :notes

          def coerce(value, rack)
            case value
            when MIDI::Stream, MB::Sound::Notes then value
            when Sequence::Clip then value.notes
            when MIDI::Source then MIDI::Stream.new(value)
            else mismatch(rack, value, 'notes (a Stream, Clip, or Notes)')
            end
          end

          def hint(name)
            "#{@name} is a notes port: streams carry notes; .synth makes audio, .notes gives one voice's signals"
          end

          def cross_hint(want)
            want == :audio ? 'notes become audio through .synth (or a kit: tr808(stream))' : nil
          end
        end

        # Audio ports: graph nodes and bundles; Symbols read a bus or
        # track (bus(:name)).
        class Audio < Port
          TYPE = :audio

          def coerce(value, rack)
            case value
            when GraphNode, GraphNode::Channels, GraphNode::MultiOutput then value
            when Symbol then MB::Sound::Session.current.bus_tap(value)
            when Array
              value.all? { |v| v.is_a?(GraphNode) } ? GraphNode::Channels.new(value) : mismatch(rack, value, 'audio (a graph node, bundle, or bus name)')
            else mismatch(rack, value, 'audio (a graph node, bundle, or bus name)')
            end
          end

          def hint(name)
            note = MIDI::Stream.method_defined?(name) ? "; #{name} is a note transform (it needs a notes port)" : ''
            "#{@name} is an audio port: audio carries samples#{note}"
          end
        end

        # Control ports: nodes read as values, numbers (constants), and
        # knob names.
        class Control < Port
          TYPE = :control

          def coerce(value, rack)
            case value
            when GraphNode then value
            when Numeric then value.constant
            when Symbol then MB::Sound.knob(value)
            else mismatch(rack, value, 'control (a number, graph node, or knob name)')
            end
          end

          def hint(name)
            note = MIDI::Stream.method_defined?(name) ? "; #{name} is a note transform (it needs a notes port)" : ''
            "#{@name} is a control port: controls are values read every sample#{note}"
          end
        end
      end

      # The rack's name (a Symbol), or nil for an anonymous rack.
      attr_reader :name

      # The main input Port.
      attr_reader :input

      # The extra ports: { name => Port }.
      attr_reader :ports

      # The declared output type (:notes, :audio, :control), or nil.
      attr_reader :out

      # The ports bound with #with: { name => value }.
      attr_reader :bound

      # The block that builds an instance.
      attr_reader :block

      # The constructor that made the rack (:mrack, :arack, :rack, ...),
      # for printing.
      attr_reader :constructor

      # For composed racks (#>>, #<<): the parts in the order they apply.
      attr_reader :parts

      # Creates a rack.  See MB::Sound::RackMethods#rack for the arguments.
      # +constructor+ is the method name that prints it back.
      #
      # +settings+ are an application's (see #using): +seed+ (the seed its
      # block builds under), +drawn+ (true if the application drew it),
      # +knobs+ (knob start values by name), and +application+ (the
      # Application of the call that applied the rack, for printing its
      # knobs' current values).
      def initialize(name = nil, in:, out: nil, constructor: :rack, block: nil, bound: {}, parts: nil, listener: false, ports: {}, quiet: false, settings: {})
        main_type = binding.local_variable_get(:in)
        raise ArgumentError, "Rack names are Symbols (got #{name.inspect})" unless name.nil? || name.is_a?(Symbol)

        @name = name
        @settings = settings.dup.freeze
        @constructor = constructor
        @parts = parts&.freeze
        @listener = listener
        @bound = bound.dup.freeze

        if parts
          @block = nil
          @input = parts.first.input
          @ports = {}.freeze
          @out = parts.last.out
          freeze
          return
        end

        raise ArgumentError, 'A rack needs a block that builds its graph from its input (mrack { it.arp(:up) })' unless block

        @block = block
        params = block.parameters
        positional = params.select { |t, _| t == :req || t == :opt }
        keywords = params.select { |t, _| t == :key || t == :keyreq }.to_h { |t, n| [n, t] }
        keyrest = params.any? { |t, _| t == :keyrest }
        if positional.empty? && !params.any? { |t, _| t == :rest }
          raise ArgumentError, 'A rack block takes its main input as its first parameter (mrack { |stream| ... } or mrack { it... })'
        end
        main_param = positional.first&.[](1)

        if main_type == :auto
          main_type, ports = infer(main_param, keywords, ports, quiet: quiet)
        end
        raise ArgumentError, "in: must be :notes, :audio, :control, or :auto (got #{main_type.inspect})#{Rack.suggest(main_type, [:notes, :audio, :control, :auto])}" unless DEFAULT_KINDS.key?(main_type)
        unless out.nil? || DEFAULT_KINDS.key?(out)
          raise ArgumentError, "out: must be :notes, :audio, or :control (got #{out.inspect})#{Rack.suggest(out, [:notes, :audio, :control])}"
        end

        @input = Port.for(main_type).new(main_param || MAIN_NAMES[main_type], main: true)
        @out = out

        # Extra ports: declared in the call and taken as block keywords
        ports.each_key do |p|
          next if keywords.key?(p) || keyrest
          raise ArgumentError, "#{label}: port #{p.inspect} isn't a keyword of the block (|#{[main_param || 'it', *keywords.keys.map { "#{_1}:" }].join(', ')}|)#{Rack.suggest(p, keywords.keys)}"
        end
        keywords.each_key do |k|
          next if ports.key?(k)
          raise ArgumentError, "#{label}: block keyword #{k}: isn't a declared port (declare it: #{constructor}(#{name ? "#{name.inspect}, " : ''}#{k}: :notes) { ... })#{Rack.suggest(k, ports.keys)}"
        end
        @ports = ports.to_h { |p, type|
          [p, Port.for(type).new(p, required: keywords[p] != :key)]
        }.freeze

        @bound.each_key { |k| check_port_name(k) }
        freeze
      end

      # :note_fx, :instrument, :effect, :listener, or :modulator, from the
      # main input and the declared output (or +out+, e.g. the type an
      # application returned).
      def kind(out = @out)
        return :listener if @listener
        KINDS[[@input.type, out]] || DEFAULT_KINDS[@input.type]
      end

      # A label for messages: "rack :dub" or "anonymous arack".
      def label
        @name ? "rack #{@name.inspect}" : "anonymous #{@constructor}"
      end

      # "audio(sig) + notes(keys) -> audio" ("?" for an output not known
      # until applied; +out+ overrides).
      def signature(out = @out)
        ins = [@input.to_s, *@ports.values.map { |p| p.required ? p.to_s : "#{p}?" }]
        "#{ins.join(' + ')} -> #{out || (@listener ? 'notes|control' : '?')}"
      end

      def to_s
        "#{@name ? "#{@name} " : ''}#{kind} #{signature}"
      end

      def inspect
        "#<Rack #{self}>"
      end

      # A new Rack with +ports+ bound to values (Proc#curry-like): values
      # are anything the port's type takes (nodes, streams, numbers, bus,
      # track, or knob names), coerced when the rack is applied.
      #
      #     voice.then(&rack(:harmonizer).with(keys: midi))
      def with(**ports)
        ports.each_key { |k| check_port_name(k) }
        if @parts
          raise ArgumentError, "#{label} is composed (>>); bind ports on its parts before composing"
        end
        copy(bound: @bound.merge(ports))
      end

      # A new Rack whose applications build with these settings (racks R2
      # round 3; how graph documents save each instance so it reloads
      # exactly): +seed:+ the random seed the block builds under (without
      # it each application draws one from the root generator), and knob
      # start values by knob name (`space: 0.7`; knobs not given start
      # at their defaults).
      #
      #     bass.then(&rack(:dub).using(seed: 1234, space: 0.7))
      def using(seed: nil, **knobs)
        raise ArgumentError, "#{label} is composed (>>); set its parts" if @parts
        raise ArgumentError, "seed: must be an Integer (got #{seed.inspect})" unless seed.nil? || seed.is_a?(Integer)
        bad = knobs.reject { |_, v| v.is_a?(Numeric) && v.real? }
        raise ArgumentError, "knob values are numbers (got #{bad.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})" unless bad.empty?
        clash = knobs.keys & [@input.name, *@ports.keys]
        raise ArgumentError, "#{clash.join(', ')} #{clash.length > 1 ? 'are ports' : 'is a port'}; bind ports with .with" unless clash.empty?
        # A seed a graph document marked as drawn (`seed: drawn_seed(N)`,
        # given back by its loader through Recipe.given_drawn_seed) stays a
        # drawn seed, so the graph saves it the same way again
        drawn = !seed.nil? && GraphNode::Recipe.state.drawn == seed
        copy(settings: { seed: seed || @settings[:seed], drawn: drawn || (seed.nil? && @settings[:drawn]) || nil, knobs: (@settings[:knobs] || {}).merge(knobs) }.compact)
      end

      # The settings of an applied rack (see #initialize and #using).
      attr_reader :settings

      # Builds an instance on +input+ (a source of the main input's type),
      # with extra +ports+ (merged over #with's).  Each call builds a fresh
      # subgraph.  Returns the block's result (a Stream, a Notes when the
      # input was a Notes, a node, or a bundle).
      def call(input, **ports)
        return @parts.reduce(input) { |x, part| part.call(x) } if @parts

        values = @bound.merge(ports)
        values.each_key { |k| check_port_name(k) }
        missing = @ports.select { |k, p| p.required && !values.key?(k) }.keys
        unless missing.empty?
          err = ArgumentError.new("#{label} needs port#{'s' if missing.length > 1} #{missing.map { |k| "#{k}: (#{@ports[k].type})" }.join(', ')}; bind with .with(#{missing.first}: ...) or pass it to the call")
          MB::Sound.live_error(err)
          return input
        end

        main = @input.coerce(input, self)
        kw = @ports.keys.select { |k| values.key?(k) }.to_h { |k| [k, @ports[k].coerce(values[k], self)] }
        values_by_port = { @input => main }.merge(kw.to_h { |k, v| [@ports[k], v] })

        # Every application builds under its own seed (given with #using,
        # else drawn, bypassing the recorder: it isn't a seed of `then`),
        # so a graph document can save it and reload the instance exactly
        seed = @settings[:seed]
        drawn = seed.nil? || !!@settings[:drawn]
        seed = MB::Sound::Internal.root_rng.rand(1 << 62) if seed.nil?
        app = Application.new(self, start: @settings[:knobs] || {})
        applied = (ports.empty? ? self : with(**ports)).send(:copy, settings: @settings.merge(seed: seed, drawn: drawn, application: app))
        result = GraphNode::Recipe.call(main, :then, [applied], {}, @block, kind: :build) { |blk|
          explain_errors(values_by_port) {
            r = Rack.applying(app) { MB::Sound.with_seed(seed) { kw.empty? ? blk.call(main) : blk.call(main, **kw) } }
            # A note rack on a Notes gives a Notes (console midi stays mono-capable)
            r = MB::Sound::Notes.new(r, sustain: main.sustain?, sample_rate: main.sample_rate) if main.is_a?(MB::Sound::Notes) && r.is_a?(MIDI::Stream)
            r
          }
        }

        check_output(result)
        Rack.registry_use(self, result, app) if @name
        result
      end
      alias [] call

      # A copy of this rack named +name+ (a Symbol, or nil for anonymous;
      # not registered anywhere): how a document's rack loads under a new
      # name (`racks: :rename`).
      def renamed(name)
        raise ArgumentError, "#{label} is composed; rename its parts" if @parts
        copy(name: name)
      end

      # Builds the block on stand-ins for every port, without recording
      # the application (its calls are recorded as top-level calls, so
      # the instance prints as the block's body): for rack documents
      # (GraphIO::Writer) and help.  Returns [result, stand-ins by port
      # name ({ sig: node, side: node }), the Application (its knobs)].
      def build_on_stand_ins
        raise ArgumentError, "#{label} is composed; save or inspect its parts" if @parts

        stand = { @input.name => Rack.stand_in(@input.type) }
        @ports.each_value { |p| stand[p.name] = Rack.stand_in(p.type) }
        kw = @ports.keys.to_h { |k| [k, stand[k]] }
        app = Application.new(self)
        # (seed 0, restored after, so inspecting or saving a rack never moves
        # the random seeds graphs draw)
        result = MB::Sound.with_seed(0) {
          Rack.applying(app) { kw.empty? ? @block.call(stand[@input.name]) : @block.call(stand[@input.name], **kw) }
        }
        [result, stand, app]
      end

      # The knobs of the rack (KnobInfo-backed Knob Specs by knob name),
      # from a stand-in build (see #build_on_stand_ins): what `help
      # rack(:x)` and rack documents list.
      def knob_specs
        _, _, app = build_on_stand_ins
        app.knobs.transform_values(&:spec)
      end

      # Remembers the values of this rack's knobs (every instance's, in
      # the current Session) as snapshot :"name/+snap+" (a named rack's
      # variation; see KnobMethods#snap).  Returns the journal entry.
      #
      #     rack(:dub).snap :wide
      #     recall :"dub/wide", over: 1.bar, only: [:space]
      def snap(snap, **opts)
        raise ArgumentError, "#{label}: snapshots belong to named racks" unless @name
        names = Session.current.racks.knob_names(@name)
        raise ArgumentError, "#{label} has no knobs in the session yet (apply it in a graph that plays)" if names.empty?
        MB::Sound.snap(Session::Name.join(@name, snap), knobs: names, **opts)
      end

      # Recalls this rack's snapshot +snap+ (see #snap and
      # KnobMethods#recall for the options, including +only:+ and
      # +except:+).
      def recall(snap, **opts)
        raise ArgumentError, "#{label}: snapshots belong to named racks" unless @name
        MB::Sound.recall(Session::Name.join(@name, snap), **opts)
      end

      # The samples this rack delays its main input by, from a stand-in
      # build (see RackInfo#latency); remembered per Rack value.
      def latency
        return LATENCIES[self] if LATENCIES.key?(self)
        value = begin
          result, = build_on_stand_ins
          Rack.latency_of(result)
        rescue StandardError
          nil
        end
        LATENCIES[self] = value
      end

      # A frozen RackInfo for this rack (+path+ and +knobs+ for one
      # instance; see Session::Racks#rack_info).
      def info(path: nil, knobs: nil, specs: nil, out: nil)
        specs ||= (knob_specs rescue {})
        ports = [{ name: @input.name, type: @input.type, role: :main, required: true }.freeze]
        @ports.each_value { |p| ports << { name: p.name, type: p.type, role: :side, required: p.required }.freeze }
        RackInfo.new(
          name: @name, path: path, kind: kind(@out || out), signature: signature(@out || out).freeze, ports: ports.freeze, latency: latency,
          knobs: (knobs || specs.keys).map(&:to_sym).freeze, knob_specs: specs.dup.freeze, slots: [].freeze
        )
      end

      # The Session knobs of this rack's knobs (names), every instance's.
      def knobs
        return [] unless @name
        Session.current.racks.knob_names(@name)
      end

      # A Proc applying the rack, for Kernel#then and other Proc users
      # (`midi.then(&rack)`).
      def to_proc
        rack = self
        proc { |input, **ports| rack.call(input, **ports) }
      end

      # Composition with Proc semantics: `a >> b` applies a, then b.  +other+
      # may be a Rack or anything callable (a Proc, a Transform::Spec).
      def >>(other)
        Rack.compose(self, other)
      end

      # `a << b` applies b, then a (Proc#<<).
      def <<(other)
        Rack.compose(other, self)
      end

      # The rack as Ruby: its constructor call and block source (composed
      # racks as `a >> b`).
      def to_ruby
        return @parts.map { |p| p.is_a?(Rack) ? p.to_ruby : GraphNode::Recipe.block_source(p, nil).to_s }.join(' >> ') if @parts

        args = []
        args << @name.inspect if @name
        args << "in: #{@input.type.inspect}" if @constructor == :rack
        args << "out: #{@out.inspect}" if @out && !%i[irack instrument_rack].include?(@constructor)
        @ports.each_value { |p| args << "#{p.name}: #{p.type.inspect}" }
        src = GraphNode::Recipe.block_source(@block, @constructor) || '{ |*| nil # FIXME(graph-io): the rack block\'s source wasn\'t found }'
        text = "#{@constructor}#{"(#{args.join(', ')})" unless args.empty?} #{src}"
        unless @bound.empty?
          text = "(#{text})" if text.include?(' do')
          text += ".with(#{@bound.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})"
        end
        text
      end

      # The default values of optional ports as source text ({ depth:
      # "0.5" }), read from the block's source with Prism (blocks loaded
      # from rack documents keep theirs); nil text where the source isn't
      # found.
      def port_defaults
        optional = @ports.values.reject(&:required).map(&:name)
        return {} if optional.empty? || @block.nil?
        return @block.graph_io_defaults.slice(*optional) if @block.respond_to?(:graph_io_defaults)

        found = {}
        src = GraphNode::Recipe.block_source(@block, @constructor)
        if src
          require 'prism'
          walk = ->(n) {
            return if n.nil? || !found.empty?
            if n.is_a?(Prism::BlockParametersNode) || n.is_a?(Prism::ParametersNode)
              list = n.is_a?(Prism::BlockParametersNode) ? n.parameters : n
              list&.keywords&.each { |k| found[k.name] = k.value.slice if k.respond_to?(:value) }
              return
            end
            n.compact_child_nodes.each { |c| walk.(c) }
          }
          walk.(Prism.parse("rack #{src}").value) # (a bare `{ |sig| }` would parse as a Hash)
        end
        optional.to_h { |k| [k, found[k]] }
      rescue StandardError
        optional.to_h { |k| [k, nil] }
      end

      # Block parameter names, in order: the main input's, then the extra
      # ports' (for printing an application's block).
      def param_names
        [@input.name, *@ports.keys]
      end

      # The block's parameter list as text: "sig, side:, depth: 0.5" (an
      # optional port's default from the block's source, see
      # #port_defaults; nil when it isn't found).
      def param_list
        defaults = port_defaults
        [@input.name.to_s, *@ports.values.map { |p| "#{p.name}:#{" #{defaults[p.name] || 'nil'}" unless p.required}" }].join(', ')
      end

      # True for racks made with #>> or #<<.
      def composed?
        !@parts.nil?
      end

      # Racks are values: equal when made the same way.
      def ==(other)
        other.is_a?(Rack) && other.name == @name && other.block.equal?(@block) && other.bound == @bound && other.parts == @parts
      end
      alias eql? ==

      def hash
        [@name, @block, @bound, @parts].hash
      end

      private

      # A copy of this rack with +changes+ (name:, bound:, settings:).
      def copy(name: @name, bound: @bound, settings: @settings)
        Rack.new(name, in: @input.type, out: @out, constructor: @constructor, block: @block, bound: bound,
          listener: @listener, ports: @ports.transform_values(&:type), quiet: true, settings: settings)
      end

      public

      class << self
        # A composed rack: +a+ then +b+ (Racks, or callables wrapped as
        # anonymous racks of the neighbor's type).
        def compose(a, b)
          a = wrap(a, b)
          b = wrap(b, a)
          if a.out && b.input.type != a.out && !(sample?(a.out) && sample?(b.input.type))
            raise TypeError, "#{a.label} outputs #{a.out} but #{b.label} takes #{b.input.type}"
          end
          parts = (a.composed? ? a.parts : [a]) + (b.composed? ? b.parts : [b])
          Rack.new(nil, in: parts.first.input.type, parts: parts)
        end

        # " (did you mean? x)" for +name+ among +names+, or ''.
        def suggest(name, names)
          return '' unless name.is_a?(Symbol) || name.is_a?(String)
          found = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s)
          found.empty? ? '' : " (did you mean? #{found.join(', ')})"
        end

        # Records a use of named rack +rack+ (see Session::Racks).
        def registry_use(rack, result, app = nil)
          s = MB::Sound::Session.existing
          s&.racks&.used(rack, result, app)
        end

        # The samples +result+ (a rack instance: a node or bundle) delays
        # its input by: the longest path through nodes reporting #latency
        # (an Integer of samples; for a node's outputs, its owner's).
        # Notes and other values give nil.
        def latency_of(result)
          roots = case result
                  when GraphNode::Channels then result.to_a
                  when GraphNode, GraphNode::MultiOutput then [result]
                  else return nil
                  end
          roots.map { |r| GraphNode.longest_path(r) { |n| node_latency(n) } }.max || 0
        end

        # Runs the block with +app+ as the innermost rack application on
        # this thread (see #application; knobs made inside belong to it).
        def applying(app)
          stack = (Thread.current[:mb_sound_rack_applications] ||= [])
          stack.push(app)
          begin
            yield
          ensure
            stack.pop
          end
        end

        # The innermost rack Application building on this thread, or nil.
        def application
          Thread.current[:mb_sound_rack_applications]&.last
        end

        # A stand-in value for a port of +type+ (see
        # Rack#build_on_stand_ins): a silent node for audio and control, an
        # empty note stream (as Notes) for notes.
        def stand_in(type)
          case type
          when :audio, :control then GraphNode::Constant.new(0, sample_rate: 48000)
          when :notes then MB::Sound::Notes.new(MIDI::Stream.new(MIDI::ClipSource.new(Sequence::Clip.new([], length: 1))))
          end
        end

        private

        def node_latency(n)
          l = n.latency if n.respond_to?(:latency) && n.method(:latency).arity == 0
          if l.nil?
            # Outputs of a multi-output node whose sources don't include it
            # (dynamics outputs) carry its latency
            owner = n.respond_to?(:owner) ? n.owner : n.instance_variable_get(:@owner)
            srcs = n.respond_to?(:sources) ? n.sources.values : []
            l = owner.latency if owner.respond_to?(:latency) && owner.method(:latency).arity == 0 && srcs.none? { |x| x.equal?(owner) }
          end
          l.is_a?(Numeric) ? l : 0
        rescue StandardError
          0
        end

        def sample?(t)
          t == :audio || t == :control
        end

        def wrap(x, other)
          return x if x.is_a?(Rack)
          raise ArgumentError, "Racks compose with racks and callables (got #{x.class})" unless x.respond_to?(:call) || x.respond_to?(:apply)

          type = other.is_a?(Rack) ? (other.out || other.input.type) : :notes
          fn = x.respond_to?(:apply) ? ->(s) { x.apply(MIDI::Stream.for(s)) } : x
          Rack.new(nil, in: type, block: ->(input) { fn.call(input) }, constructor: :rack)
        end
      end

      private

      def check_port_name(k)
        return if @ports.key?(k)
        raise ArgumentError, "#{label} has no port #{k.inspect}#{@ports.empty? ? ' (it has no extra ports)' : " (ports: #{@ports.keys.join(', ')})"}#{Rack.suggest(k, @ports.keys)}"
      end

      # Checks the block's result against +out:+ (notes vs samples; audio
      # and control are both sample streams).
      def check_output(result)
        got = Rack.output_type(result)
        want = @out
        want = :sample if @listener
        return if want.nil?
        ok = case want
             when :notes then got == :notes
             when :sample then got == :notes || got == :audio || got == :control
             else got == :audio || got == :control
             end
        return if ok

        MB::Sound.live_error(TypeError.new("#{label} should output #{@out} but its block returned #{result.class.name || result.class} (#{got || 'not a graph value'})"))
      end

      # The block raised NoMethodError on a port's value: re-raise with a
      # hint about the port's type (did_you_mean still suggests names).
      def explain_errors(values_by_port)
        yield
      rescue NoMethodError => e
        port = values_by_port.find { |_, v| e.receiver.equal?(v) }&.first
        hint = port&.hint(e.name)
        raise unless hint

        err = NoMethodError.new("#{e.message} (in #{label}: #{hint})", e.name, e.args, receiver: e.receiver)
        err.set_backtrace(e.backtrace)
        raise err
      end

      def infer(main_param, keywords, declared, quiet:)
        unless main_param && main_param != :_1
          raise ArgumentError, "in: :auto reads the block's parameter names, and `it`/_1 blocks have none: name the parameter (|sig|) or give in: :audio"
        end

        type_of = ->(n) {
          AUTO_TYPES.find { |_, names| names.include?(n) }&.first or
            raise ArgumentError, "in: :auto can't tell the type of #{n} (#{AUTO_TYPES.map { |t, names| "#{names.join('/')} are #{t}" }.join('; ')}); declare it (#{n}: :audio)#{Rack.suggest(n, AUTO_TYPES.values.flatten)}"
        }
        main = type_of.(main_param)
        ports = declared.dup
        keywords.each_key { |k| ports[k] ||= type_of.(k) }
        unless quiet
          kw = ports.map { |k, t| "#{k}: #{t}" }
          puts "# #{@name ? "rack #{@name.inspect}" : 'rack'} inferred #{main}(#{[main_param, *kw].join(', ')}) -> #{@out || '?'}"
        end
        [main, ports]
      end

      public

      # The port type of a rack's result (nil if it isn't a graph value).
      def self.output_type(result)
        case result
        when MIDI::Stream, MB::Sound::Notes, Sequence::Clip then :notes
        when GraphNode::Channels then :audio
        when GraphNode, GraphNode::MultiOutput then GraphNode::Traversable.port_type_of(result)
        end
      end
    end
  end
end
