module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Produces a single-sample click whenever a note-on event is received.
        # Useful for filter pinging.
        class MidiClick
          include GraphNode
          include GraphNode::SampleRateHelper

          # Initializes a MIDI note-on click generator.
          #
          # +:dsl+ - The MidiDsl event source.
          # +:range+ - The range of amplitudes for velocities 0..127.
          # +:sample_rate+ - Stored and ignored.
          def initialize(dsl:, range:, sample_rate:)
            @dsl = dsl
            @manager = @dsl.manager
            @range = range
            @sample_rate = sample_rate.to_f

            @node_type_name = 'Note Click'

            @buf = nil
            @click = []

            @manager.on_note(&method(:note_cb))
          end

          # Records the need for a click for the next call to #sample.
          def note_cb(number, velocity, onoff, timestamp)
            @click << [timestamp, MB::M.scale(velocity, 0..127, @range)] if onoff
          end

          # Returns a buffer of all zeros, except for a single sample click if
          # a MIDI note was received since the last call to #sample.
          def sample(count)
            # FIXME: this should only be called once per sound card frame
            # (GraphVoice ignores this update call, but the DSL should have a
            # better per-frame update)
            @manager.update

            if @buf.nil? || @buf.length != count
              @buf = Numo::SFloat.zeros(count)
            end

            if @click.any?
              @click.each do |t, e|
                i = (t * @sample_rate).floor
                puts "click #{e} at offset #{i}" # XXX
                @buf[i] = e
              end
              @click.clear
            elsif
              @buf.fill(0)
            end

            @buf.not_inplace!
          end
        end
      end
    end
  end
end
