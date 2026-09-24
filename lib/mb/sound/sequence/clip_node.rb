module MB
  module Sound
    module Sequence
      # Base class for graph nodes that play a Clip in time with a Transport.
      # Subclasses turn the clip's note-on and note-off edges into a signal
      # (triggers, gates, note numbers, envelopes).  Create these with the
      # output methods on Clip (e.g. Clip#env or Clip#number).
      #
      # Edges land on the exact sample where they occur, not just at buffer
      # boundaries.
      #
      # A node playing a non-looping clip returns nil (ending the graph) once
      # the clip and any #tail have finished.
      class ClipNode
        include GraphNode
        include GraphNode::SampleRateHelper

        # The Clip being played.
        attr_reader :clip

        # The Transport that sets the tempo.
        attr_reader :transport

        # The current playback position, in whole notes (a Rational).
        attr_reader :position

        def initialize(clip, transport: nil, sample_rate: 48000)
          @clip = clip
          @transport = transport || Sequence.transport
          @sample_rate = sample_rate.to_f
          @position = 0r
          @buf = nil
        end

        # Restarts playback from the beginning of the clip.
        def restart
          @position = 0r
          self
        end

        # Returns +count+ samples of output, or nil once a non-looping clip has
        # finished.
        def sample(count)
          return nil if done?

          # Rational math keeps note edges on exact samples no matter how
          # long the clip has been playing.
          per_sample = @transport.whole_notes_per_second / @sample_rate.to_r
          from = @position
          to = from + count * per_sample
          @position = to

          edges = @clip.edges(from, to).map { |time, type, event, cycle|
            offset = ((time - from) / per_sample).floor
            [MB::M.clamp(offset, 0, count - 1), type, event, cycle]
          }

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          render(@buf, edges)
          @buf.not_inplace!
        end

        # Returns true once a non-looping clip has finished playing, including
        # the #tail.
        def done?
          !@clip.looping? && @position >= @clip.length + @transport.whole_notes_per_second * tail
        end

        # Extra seconds to keep producing output after a non-looping clip ends
        # (e.g. for an envelope's release).
        def tail
          0
        end

        def sources
          {}
        end

        def to_s
          "#{super} #{@clip}"
        end

        private

        # Fills +buf+ given +edges+ as [sample offset, :on/:off, event, cycle].
        def render(buf, edges)
          raise NotImplementedError
        end

        # Outputs a single-sample impulse at the start of each event, scaled
        # from velocity to +:range+.
        class Trigger < ClipNode
          def initialize(clip, range:, transport: nil, sample_rate: 48000)
            super(clip, transport: transport, sample_rate: sample_rate)
            @range = range
            @node_type_name = 'Clip Trigger'
          end

          private

          def render(buf, edges)
            buf.fill(0)
            edges.each do |offset, type, event, _cycle|
              next unless type == :on
              v = MB::M.scale(event.velocity, 0.0..1.0, @range)
              buf[offset] = v if v.abs > buf[offset].abs
            end
          end
        end

        # Base for nodes whose output holds a level between edges.
        class Held < ClipNode
          def initialize(clip, initial:, transport: nil, sample_rate: 48000)
            super(clip, transport: transport, sample_rate: sample_rate)
            @level = initial.to_f
          end

          # Held values (note numbers, velocities) never end on their own, so
          # that e.g. an oscillator keeps playing through an envelope's
          # release.  Gates, triggers, and envelopes end the graph instead.
          def done?
            false
          end

          private

          def render(buf, edges)
            start = 0
            edges.each do |offset, type, event, cycle|
              buf[start...offset] = @level if offset > start
              start = offset
              @level = next_level(type, event, cycle, @level).to_f
            end
            buf[start...buf.length] = @level if start < buf.length
          end

          # Returns the output level after the given edge.
          def next_level(type, event, cycle, level)
            raise NotImplementedError
          end
        end

        # Outputs 1.0 while any event is playing and 0.0 otherwise.
        class Gate < Held
          def initialize(clip, transport: nil, sample_rate: 48000)
            super(clip, initial: 0, transport: transport, sample_rate: sample_rate)
            @active = {}
            @node_type_name = 'Clip Gate'
          end

          # Unlike other held values, a gate ends when a non-looping clip ends.
          def done?
            !@clip.looping? && @position >= @clip.length
          end

          private

          def next_level(type, event, cycle, _level)
            key = [event.object_id, cycle]
            type == :on ? @active[key] = true : @active.delete(key)
            @active.empty? ? 0 : 1
          end
        end

        # Outputs the velocity of the most recent event, scaled to +:range+.
        class Velocity < Held
          def initialize(clip, range:, transport: nil, sample_rate: 48000)
            first = clip.events.first&.velocity || 0
            @range = range
            super(clip, initial: MB::M.scale(first, 0.0..1.0, range), transport: transport, sample_rate: sample_rate)
            @node_type_name = 'Clip Velocity'
          end

          private

          def next_level(type, event, _cycle, level)
            type == :on ? MB::M.scale(event.velocity, 0.0..1.0, @range) : level
          end
        end

        # Outputs the value (e.g. note number) of the most recent event,
        # starting with the first event's value so oscillators don't start at
        # 0Hz.
        class Number < Held
          def initialize(clip, transport: nil, sample_rate: 48000)
            super(clip, initial: clip.events.first&.value || 0, transport: transport, sample_rate: sample_rate)
            @node_type_name = 'Clip Number'
          end

          private

          def next_level(type, event, _cycle, level)
            type == :on ? event.value : level
          end
        end

        # An ADSR envelope that triggers at the start of each event and
        # releases at the end of the most recently started event.
        class Envelope < ClipNode
          def initialize(clip, attack:, decay:, sustain:, release:, velocity:, transport: nil, sample_rate: 48000)
            super(clip, transport: transport, sample_rate: sample_rate)
            @velocity = velocity
            @release_time = release.to_f
            @env = MB::Sound::ADSREnvelope.new(
              attack_time: attack,
              decay_time: decay,
              sustain_level: sustain,
              release_time: release,
              sample_rate: @sample_rate
            )
            @current = nil
            @node_type_name = 'Clip Envelope'
          end

          # Waits for the release to finish after a non-looping clip ends.
          def tail
            @release_time + 0.01
          end

          def sample_rate=(rate)
            super
            @env.sample_rate = @sample_rate
          end

          private

          def render(buf, edges)
            start = 0
            edges.each do |offset, type, event, cycle|
              buf[start...offset] = @env.sample(offset - start) if offset > start
              start = offset

              key = [event.object_id, cycle]
              if type == :on
                @env.trigger(MB::M.scale(event.velocity, 0.0..1.0, @velocity))
                @current = key
              elsif key == @current
                @env.release
                @current = nil
              end
            end
            buf[start...buf.length] = @env.sample(buf.length - start) if start < buf.length
          end
        end
      end
    end
  end
end
