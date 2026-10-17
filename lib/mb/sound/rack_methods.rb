module MB
  module Sound
    # Console and script methods for racks (MB::Sound::Rack; design notes in
    # design/notes/racks.md): reusable pieces of graph with typed ports,
    # anonymous values or named (registered in the Session namespace).
    # MB::Sound extends itself with this module.
    #
    # The constructors fix the main input's type (the kind letters):
    #
    #     mrack  (note_rack)        notes in               -> notes (or audio: an instrument)
    #     irack  (instrument_rack)  notes in, audio out
    #     arack  (audio_rack)       audio in               -> audio (or notes/control: a listener)
    #     lrack  (amrack, listener_rack)  audio in, notes or control out
    #     modrack (mod_rack)        control in
    #     rack(name, in:, out:)     the general form (in: :auto reads the block's parameter names)
    #
    # Example (bin/sound.rb):
    #     wobble = mrack { it.arp(:up, 16).echo(3.n16, 2, pitch: 7) }
    #     bg :keys, midi.then(&wobble).synth { |v| v.hz.saw * v.amp_env }
    #
    #     arack :dub, side: :audio do |sig, side:|
    #       sig.duck(side).delay(3.n16, feedback: 0.4, wet: 0.3)
    #     end
    #     bg :bass, bass_line.then(&rack(:dub).with(side: :drums))
    #     racks                 # name => kind and ports
    #     rack(:dub).to_ruby    # its source
    module RackMethods
      # With a block, defines a rack whose main input has type +in:+
      # (:notes, :audio, :control, or :auto to read the types from the
      # block's parameter names, printing what it inferred), checking its
      # output against +out:+ if given; +ports+ declare extra ports by type
      # (`side: :audio`), taken as keywords of the block (`|sig, side:|`;
      # a default makes one optional).  A +name+ registers it (see #racks);
      # without one it is an anonymous value.  Returns the Rack.
      #
      # Without a block, returns the named rack +name+.
      #
      #     rack(:sc, in: :audio, kick: :notes) { |sig, kick:| sig * (1 - kick.amp_env(release: 0.2) * 0.5) }
      #     rack(:sc)                      # => the rack
      def rack(name = nil, in: nil, out: nil, **ports, &block)
        main = binding.local_variable_get(:in)
        if block.nil?
          raise ArgumentError, 'rack(:name) looks up a named rack; pass a block to define one (rack(:x, in: :audio) { |sig| ... })' unless name.is_a?(Symbol) && main.nil? && out.nil? && ports.empty?
          return Session.current.racks.fetch(name)
        end
        raise ArgumentError, 'rack needs in: (:notes, :audio, :control, or :auto); or use mrack, irack, arack, lrack, modrack' if main.nil?

        define_rack(name, main, out, ports, block, :rack)
      end

      # A note rack: notes in (a Stream, Clip, or Notes), notes out (or
      # audio, making it an instrument).  See #rack.
      #
      #     mrack { it.chord(:min7).strum(20.ms) }
      #     mrack(:pads) { |stream| stream.chord(:min7) }
      def mrack(name = nil, out: nil, **ports, &block)
        define_rack(name, :notes, out, ports, block, :mrack)
      end
      alias note_rack mrack

      # An instrument rack: notes in, audio out.  See #rack.
      #
      #     irack(:keys) { |stream| stream.synth { |v| v.hz.triangle * v.amp_env } }
      def irack(name = nil, **ports, &block)
        define_rack(name, :notes, :audio, ports, block, :irack)
      end
      alias instrument_rack irack

      # An audio rack: audio in, audio out (or notes/control, making it a
      # listener).  See #rack.
      #
      #     arack(:dub) { |sig| sig.reverb(:hall, mix: 0.3) }
      #     arack :pump, side: :audio do |sig, side:| sig.duck(side) end
      def arack(name = nil, out: nil, **ports, &block)
        define_rack(name, :audio, out, ports, block, :arack)
      end
      alias audio_rack arack

      # A listener rack: audio in, notes or control out (follower,
      # detectors; the detectors themselves come in later phases).  See
      # #rack.
      #
      #     lrack(:level) { |sig| sig.abs.filter(:lowpass, cutoff: 10) }
      def lrack(name = nil, **ports, &block)
        define_rack(name, :audio, nil, ports, block, :lrack, listener: true)
      end
      alias amrack lrack
      alias listener_rack lrack

      # A modulator rack: control in (a node, number, or knob name).  See
      # #rack.
      #
      #     modrack(:wobble) { |ctl| ctl * 0.5 + 0.5 }
      def modrack(name = nil, out: nil, **ports, &block)
        define_rack(name, :control, out, ports, block, :modrack)
      end
      alias mod_rack modrack

      # The named racks: name => "effect audio(sig) + audio(side) -> audio,
      # macros space 0.3 (0..1), 2 uses (in :bass)".
      def racks
        Session.current.racks.info
      end

      # Inside a rack's block, a knob scoped to the rack (a macro; racks R2,
      # proposal 2.6): the same GraphNode::Knob as the console's #knob, so
      # turn, over:, learn, snap/recall, takes, plans, and ACID XML work
      # unchanged.  Takes #knob's options (+range:+, +curve:+, +unit:+,
      # +cc:+, +takeover:+, +smooth:+).
      #
      # Names: macro :space in rack :dub is the Session knob :"dub/space"
      # once a graph using it plays; when the rack plays in several
      # players each instance gets its own, :"bass/dub/space" and
      # :"keys/dub/space" (an anonymous rack's macros are always the
      # player's: :"bass/space").  Opt-in sharing:
      #
      # - +share: true+ joins the Session knob :space instead (made if
      #   there is none; a knob of that name with another range or curve
      #   goes through MB::Sound.live_error, as graph documents' knobs do).
      # - +follow: :space+ makes the macro follow Session knob :space
      #   through its own range and curve (the knob's position in its range
      #   becomes the macro's position in its own) until the macro is
      #   turned.
      #
      # Asking for a macro again by name in the same application returns
      # the same knob (`macro(:space)` needs no default then).  Returns the
      # Knob (a graph node; `.mod(lfo, depth:)` adds modulation around it).
      #
      #     arack :dub do |sig|
      #       space = macro :space, 0.3
      #       sig.delay(3.n16, feedback: space * 0.6, wet: space)
      #     end
      #     turn :"dub/space", 0.7, over: 2.bars
      def macro(name, default = nil, share: false, follow: nil, description: nil, **spec)
        raise ArgumentError, "Macro names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        app = Rack.application
        unless app
          raise ArgumentError, "macro #{name.inspect} belongs inside a rack's block (arack(:dub) { |sig| ... macro(#{name.inspect}, 0.5) ... }); outside a rack, knob #{name.inspect}, ... makes a session knob"
        end

        existing = app.macros[name]
        return existing if existing && default.nil? && spec.empty? && !share && follow.nil?
        if existing
          # The same definition again (how printed racks repeat a macro
          # used twice) reads the same knob
          same = begin
            GraphNode::Knob::Spec.new(name: existing.name, default: default, **spec) == existing.spec &&
              existing.macro.share == share && existing.macro.follow == follow
          rescue ArgumentError
            false
          end
          return existing if same
          raise ArgumentError, "#{app.rack.label} defines macro #{name.inspect} twice, differently; use macro(#{name.inspect}) to read it again"
        end
        raise ArgumentError, "#{app.rack.label} has no macro #{name.inspect} yet; give it a default (macro #{name.inspect}, 0.5, range: 0..1)" if default.nil?
        raise ArgumentError, "macro #{name.inspect}: share: and follow: don't go together (share joins knob #{name.inspect}; follow maps another knob onto the macro)" if share && follow
        raise ArgumentError, "macro #{name.inspect}: follow: names a Session knob (got #{follow.inspect})" unless follow.nil? || follow.is_a?(Symbol)
        unless share == true || share == false
          raise ArgumentError, "macro #{name.inspect}: share: is true or false (got #{share.inspect})"
        end

        rack = app.rack
        full = share ? name : (rack.name ? :"#{rack.name}/#{name}" : name)
        info = Rack::MacroInfo.new(rack: rack, macro: name, application: app, share: share, follow: follow, description: description)
        k = GraphNode::Knob.new(full, default, macro: info, **spec)
        app.macros[name] = k
      end

      private

      def define_rack(name, main, out, ports, block, constructor, listener: false)
        unless name.nil? || name.is_a?(Symbol)
          raise ArgumentError, "Rack names are Symbols (got #{name.inspect}); extra ports are keywords (#{constructor}(:name, side: :audio) { ... })"
        end

        r = Rack.new(name, in: main, out: out, constructor: constructor, block: block, ports: ports, listener: listener)
        Session.current.racks.define(r) if name
        r
      end
    end
  end
end
