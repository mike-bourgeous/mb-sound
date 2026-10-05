module MB
  module Sound
    class Notes
      # The gate, trigger, velocity, and choke inputs of one NoteEnvelope,
      # computed together from one stream reader and one NoteStack, with
      # exactly the samples of Notes#gate, #trigger, #velocity, and #choke
      # (see Gate, Trigger, Velocity, and Choke).  The node's own output is
      # the gate; #trigger, #velocity, and #choke are Port nodes giving the
      # other buffers of the node's latest frame, so the envelope reads its
      # gate first (as Envelope#run does) and then the ports.  This
      # replaces four nodes, four readers, and their Tees per envelope.
      #
      # Like the separate nodes, buffers without events (or whose events
      # leave an output unchanged) are constant frozen buffers with
      # Notes.fast_paths on.
      class EnvelopeInputs < NoteNode
        # One of the extra outputs of an EnvelopeInputs (see there).
        class Port
          include GraphNode
          include GraphNode::SampleRateHelper

          # The output's name: :trigger, :velocity, or :choke.
          attr_reader :output

          def initialize(inputs, output)
            @inputs = inputs
            @output = output
            @node_type_name = "Notes envelope #{output}"
          end

          # The buffer of the inputs node's latest frame (sample the inputs
          # node first), or nil once it has ended (velocity keeps its last
          # value, like Notes#velocity).
          def sample(count)
            @inputs.output_buffer(@output, count.round)
          end

          def sample_rate
            @inputs.sample_rate
          end

          def sample_rate=(rate)
            @inputs.sample_rate = rate
            self
          end

          def sources
            { inputs: @inputs }
          end
        end

        # The Port nodes for the trigger, velocity, and choke outputs.
        attr_reader :trigger, :velocity, :choke

        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @velocity_value = stream.first_note&.velocity.to_f
          @trigger = Port.new(self, :trigger)
          @velocity = Port.new(self, :velocity)
          @choke = Port.new(self, :choke)
          @outs = {}
          @bufs = {}
          @ended = false
          @node_type_name = 'Notes envelope inputs'
        end

        # Ends the graph like Notes#gate (see Node).
        def ends_graph?
          true
        end

        # Used by Port: the +output+ buffer of the latest frame.
        def output_buffer(output, count)
          if @ended
            return output == :velocity ? constant_buffer(count, @velocity_value, :velocity) : nil
          end

          buf = @outs[output]
          raise ArgumentError, "#{self} #{output} read before its gate, or with another count (#{count})" if buf.nil? || buf.length != count
          buf
        end

        def sample(count)
          out = super
          @ended = out.nil?
          out
        end

        private

        def level
          @stack.held? ? 1.0 : 0.0
        end

        def note_on(event)
          @velocity_value = event.velocity.to_f
        end

        def chase(event)
          @velocity_value = event.velocity.to_f
        end

        # No events: constant buffers for every output.
        def steady_buffer(count)
          @outs[:trigger] = constant_buffer(count, 0.0, :trigger)
          @outs[:velocity] = constant_buffer(count, @velocity_value, :velocity)
          @outs[:choke] = constant_buffer(count, 0.0, :choke)
          constant_buffer(count, level)
        end

        # Fills the gate +buf+ and the other outputs' buffers like Held (gate
        # and velocity) and Impulse (trigger and choke) nodes do.  Returns
        # the gate's uniform value, if any (see Node#render).
        def render(buf, items)
          count = buf.length
          trig = writable(:trigger, count).fill(0)
          vel = writable(:velocity, count)
          chk = writable(:choke, count).fill(0)

          gate_first = vel_first = nil
          gate_uniform = vel_uniform = true
          quiet_trigger = quiet_choke = true

          fill = ->(from, to) {
            g = level
            v = @velocity_value
            if gate_first.nil?
              gate_first = g
              vel_first = v
            else
              gate_uniform = false if g != gate_first
              vel_uniform = false if v != vel_first
            end
            buf[from...to] = g
            vel[from...to] = v
          }

          start = 0
          items.each do |off, item|
            if off > start
              fill.(start, off)
              start = off
            end

            if item.is_a?(MIDI::Source::Chase)
              chase(item.event)
              next
            end

            t = item.velocity if item.type == :note_on
            if t && t > trig[off]
              trig[off] = t
              quiet_trigger = false
            end

            if (item.type == :choke || item.all_sound_off?) && 1.0 > chk[off]
              chk[off] = 1.0
              quiet_choke = false
            end

            handle(item)
          end

          fill.(start, count) if start < count

          fast = Notes.fast_paths
          @outs[:trigger] = fast && quiet_trigger ? constant_buffer(count, 0.0, :trigger) : trig
          @outs[:velocity] = fast && vel_uniform && vel_first.is_a?(Float) ? constant_buffer(count, vel_first, :velocity) : vel
          @outs[:choke] = fast && quiet_choke ? constant_buffer(count, 0.0, :choke) : chk

          gate_uniform ? gate_first : nil
        end

        # The writable buffer of +output+ for rendering.
        def writable(output, count)
          b = @bufs[output]
          b = @bufs[output] = Numo::SFloat.zeros(count) if b.nil? || b.length != count
          b
        end
      end
    end
  end
end
