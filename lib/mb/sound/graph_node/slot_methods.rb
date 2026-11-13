module MB
  module Sound
    module GraphNode
      # The slot DSL method (racks R3; design/notes/racks.md, Slots).
      # Included in GraphNode and Channels.
      module SlotMethods
        # A named hole whose content swaps live (rack slots).  The block
        # builds the default content from the signal (a bundle gets the
        # whole bundle), and a Session swaps it on an exact frame (`swap
        # :"dub/color", arack { it.diode(800) }`; spill-over by default,
        # `fade:` crossfades, `fade: 0` cuts).  Inside a rack's block the
        # slot belongs to the rack (:"dub/color"; :"bass/dub/color" per
        # instance once the rack plays in several players); elsewhere to
        # the player (:"bass/color").
        # Returns the slot's output (a bundle for several channels).
        #
        #     arack :dub do |sig|
        #       sig.slot(:color) { |s| s.softclip }.delay(3.n16, feedback: 0.4, wet: 0.3)
        #     end
        #     swap :"dub/color", arack { |s| s.diode(900, resonance: 0.6) }, fade: 1.n8
        def slot(name, &block)
          raise ArgumentError, "Slot names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "slot #{name.inspect} needs a block making its default content: sig.slot(#{name.inspect}) { |s| s.softclip }" unless block

          app = MB::Sound::Rack.application
          start = app&.start&.[](name)
          if start && !(start.is_a?(MB::Sound::Rack) || start.respond_to?(:call))
            raise ArgumentError, "#{app.rack.label}: slot #{name.inspect} takes a rack or block (got #{start.class})"
          end
          if app
            raise ArgumentError, "#{app.rack.label} has two slots named #{name.inspect}" if app.slots.key?(name)
            raise ArgumentError, "#{app.rack.label}: slot #{name.inspect} has the name of a knob" if app.knobs.key?(name)
          end

          s = Slot.new(self, name: name, content: start || block, application: app)
          app.slots[name] = s if app
          s.receiver = self
          s.result = s.returned
        end
      end
    end
  end
end
