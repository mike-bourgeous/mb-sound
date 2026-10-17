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
      # 2 uses (in :bass)".
      def racks
        Session.current.racks.info
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
