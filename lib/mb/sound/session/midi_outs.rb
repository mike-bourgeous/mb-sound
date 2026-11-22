module MB
  module Sound
    class Session
      # MIDI out tracks (MIDI::OutNode, MIDI::Destination) in a Session:
      # where scheduled MIDI is placed and how notes end when a graph stops
      # being read.
      #
      # - #write_frame: the session frame the current #process_buffer
      #   started on, which the output's next write starts with, so a
      #   destination can map a session frame onto the output's queue (and
      #   on JACK, onto the JACK frame its audio leaves on).
      # - #note_midi_out: an OutNode holding notes asks to be told after
      #   each span; #end_midi_out_span (after players render) lets each
      #   one that wasn't read to the span's end send its note-offs on the
      #   frame its reading stopped (cut stops, mutes, replaced graphs,
      #   cleared sets, panics): one mechanism instead of a hook per way a
      #   player ends.
      module MidiOuts
        # The session frame the current (or last) #process_buffer started
        # on (see MidiOuts).
        attr_reader :write_frame

        # The Player whose graph is being read (beside #player_frame), or
        # nil outside a player's read: a MIDI out track finds its level
        # knob through it.
        attr_reader :reading_player

        # Asks for +node+ (a MIDI::OutNode holding notes) to be called after
        # each span (see MidiOuts).  Render thread.
        def note_midi_out(node)
          (@midi_outs ||= []) << node unless @midi_outs&.include?(node)
        end

        private

        # Calls each noted OutNode's #end_span for the span ending before
        # session frame +span_end+, forgetting those holding nothing.
        def end_midi_out_span(span_end)
          list = @midi_outs
          return if list.nil? || list.empty?
          list.select! { |n| n.end_span(self, span_end) }
        end
      end
    end
  end
end
