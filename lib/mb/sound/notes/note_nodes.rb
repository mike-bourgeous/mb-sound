module MB
  module Sound
    class Notes
      # Base for nodes that follow the held notes of the stream with a
      # NoteStack (last-note priority when notes overlap; see Notes).
      # Note-ons push, note-offs pop, and :choke events, all sound off (CC
      # 120), and all notes off (CC 123-127) release every note.
      class NoteNode < Node::Held
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @stack = NoteStack.new
        end

        # True if a note-on read so far has no note-off yet (see
        # Notes#held?).
        def held?
          @stack.held?
        end

        private

        def handle(event)
          case event.type
          when :note_on
            @stack.note_on(event)
            note_on(event)

          when :note_off
            top = @stack.top
            note_off(event) if @stack.note_off(event)
            uncovered(@stack.top) if @stack.top && !@stack.top.equal?(top)

          when :choke
            @stack.clear

          when :cc
            @stack.clear if event.all_sound_off? || event.all_notes_off?
            other(event)

          else
            other(event)
          end
        end

        # Called for each note-on.
        def note_on(event)
        end

        # Called for each note-off of a held note.
        def note_off(event)
        end

        # Called when releasing the newest note uncovers an older held
        # NoteStack::Entry (the mono note returns to it).
        def uncovered(entry)
        end

        # Called for other events (e.g. :glide, :cc).
        def other(event)
        end
      end

      # 1 while any note is held, else 0 (see Notes#gate).
      class Gate < NoteNode
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @node_type_name = 'Notes Gate'
        end

        def ends_graph?
          true
        end

        private

        def level
          @stack.held? ? 1.0 : 0.0
        end
      end

      # The note number of the newest held note, held after it is released
      # (see Notes#number).
      class Number < NoteNode
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          first = stream.first_note
          @number = first ? number_of(first.note) : DEFAULT_NUMBER
          @node_type_name = 'Notes Number'
        end

        # The current note number (Float).
        def value
          @number
        end

        private

        def level
          @number
        end

        def note_on(event)
          @number = number_of(event.note)
        end

        def uncovered(entry)
          @number = number_of(entry.note)
        end

        def chase(event)
          @number = number_of(event.note)
        end
      end

      # The velocity (0..1) of the latest note-on (see Notes#velocity).
      class Velocity < NoteNode
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @velocity = stream.first_note&.velocity.to_f
          @node_type_name = 'Notes Velocity'
        end

        def value
          @velocity
        end

        private

        def level
          @velocity
        end

        def note_on(event)
          @velocity = event.velocity.to_f
        end

        def chase(event)
          @velocity = event.velocity.to_f
        end
      end

      # 1 while the latest note's velocity is at least +threshold+, else 0
      # (see Notes#accent).
      class Accent < Velocity
        attr_reader :threshold

        def initialize(stream, threshold:, notes: nil, sample_rate: 48000)
          @threshold = Float(threshold)
          super(stream, notes: notes, sample_rate: sample_rate)
          @node_type_name = 'Notes Accent'
        end

        def value
          @velocity >= @threshold ? 1.0 : 0.0
        end

        private

        def level
          value
        end
      end

      # The release velocity (0..1) of the latest note-off (see Notes#lift).
      class Lift < NoteNode
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @lift = MIDI::Event::DEFAULT_RELEASE / 127.0
          @node_type_name = 'Notes Lift'
        end

        def value
          @lift
        end

        private

        def level
          @lift
        end

        def note_off(event)
          @lift = event.velocity.to_f if event.velocity
        end
      end

      # A single-sample impulse at every note-on, valued at its velocity
      # (see Notes#trigger).
      class Trigger < Node::Impulse
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @node_type_name = 'Notes Trigger'
        end

        private

        def impulse(event)
          event.velocity if event.type == :note_on
        end
      end

      # The key sync trigger (see Notes#key_trigger): a Trigger without the
      # note-ons that add energy to a voice that is still sounding, that
      # is, note-ons while an envelope of the Notes with +retrigger: :add+
      # is sounding (Notes#adding_at?).  Whether one is sounding is asked
      # once per buffer, as of the buffer's start (so it doesn't depend on
      # whether the envelopes have rendered the buffer yet; see
      # NoteEnvelope#sounding_at?); after a note-on in the buffer, the :add
      # envelopes count as sounding for the rest of it.
      class KeyTrigger < Trigger
        def initialize(stream, notes:, sample_rate: 48000)
          super
          @node_type_name = 'Notes Key Trigger'
        end

        def sample(count)
          @from = @reader.cursor
          super
        end

        private

        def render(buf, items)
          @adding = @notes.adding_at?(@from)
          super
        end

        def impulse(event)
          return nil unless event.type == :note_on
          return nil if @adding

          @adding = @notes.add_envelopes?
          event.velocity
        end
      end

      # A single-sample impulse of 1 at every :choke event and all sound off
      # (CC 120) (see Notes#choke).
      class Choke < Node::Impulse
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @node_type_name = 'Notes Choke'
        end

        private

        def impulse(event)
          1.0 if event.type == :choke || event.all_sound_off?
        end
      end
    end
  end
end
