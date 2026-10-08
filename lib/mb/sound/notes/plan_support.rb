module MB
  module Sound
    class Notes
      # The plan layer side of Notes nodes (see MB::Sound::Plan::EventList):
      # each node describes its output as an events op, and its #plan_feed
      # runs its own event handling once per planned block (reader, note
      # stack, held values, chases, #render) into an EventList instead of a
      # buffer.  Smoothed controller outputs aren't planned yet.
      class Node
        include Plan::Describable

        # The instance variables that aren't per-sample state (buffers,
        # caches, references to the stream and other nodes), left out of
        # check mode snapshots.
        PLAN_SKIP = [
          :@stream, :@notes, :@reader, :@buf, :@steady, :@steady_value, :@slots, :@smoother, :@jumps,
          :@step, :@step_count, :@step_rate, :@rate_r, :@outs, :@bufs,
          :@node_type_name, :@graph_node_name, :@internal_tee, :@handled_spies, :@curve, :@gm_time,
          :@delay, :@delay_buf, :@time_node, :@time_buf, :@spec, :@first_fill, :@uniform, :@render_offset, :@segment_start,
        ].freeze

        def plan_inputs
          []
        end

        class << self
          # True for node classes whose feed is known to match their #sample
          # (each opts in with plan_events!; subclasses don't inherit it).
          def plan_events?
            !!@plan_events
          end

          private

          def plan_events!
            @plan_events = true
          end
        end

        def plan_unsupported_reason
          return "#{Plan.class_label(self)} isn't planned yet" unless self.class.plan_events?
          return 'smoothed controller output (not planned yet)' if @smoother

          nil
        end

        def plan_describe(p)
          p.events(self)
        end

        # The EventList for output +port+ (nil: the main output), made on
        # first use.
        def plan_event_list(port = nil)
          (@plan_lists ||= {})[port] ||= Plan::EventList.new
        end

        # True once the stream is over (see Plan::EventList: the node may
        # start ending the graph).
        def plan_finished?
          ended?
        end

        # One planned block: the node's #sample without the buffer (see
        # the class description).
        def plan_feed(count)
          from = @reader.cursor
          step(count)
          to = @stream.advance(from, count, @sample_rate)
          events = @reader.events(from, to)
          chase = take_chase(to)

          unless events.empty? && chase.nil? && plan_steady(count)
            rec = (@plan_recorder ||= Plan::Recorder.new(plan_event_list)).start(count)
            render(rec, items(events, chase, from, @rate_r, count))
          end

          @tail += count if ended?
          nil
        end

        # Reads the next +count+ samples' events without making a buffer
        # (Synth's skipped lanes keep their Notes nodes in step this way).
        # Returns nil if the node has finished (as #sample would), else
        # true.  Unlike #sample, this doesn't count as a read from outside a
        # plan that fuses the node.
        def advance(count)
          count = count.round
          if @plan_member || @plan_region
            return nil if finished?
            plan_feed(count)
            true
          else
            sample(count) && true
          end
        end

        def plan_snapshot
          ivars = instance_variables.reject { |iv|
            PLAN_SKIP.include?(iv) || iv.start_with?('@plan_') || instance_variable_get(iv).respond_to?(:sample)
          }
          Plan::Snapshot.capture(self, ivars, @reader.cursor)
        end

        def plan_restore(snapshot)
          snapshot.restore(self)
          @reader.cursor = snapshot.plain[1]
        end

        private

        # Records a block without events if the output holds a steady value
        # (Node#steady_buffer's cases), returning true, else false (the
        # block is rendered).
        def plan_steady(count)
          false
        end

        class Held
          private

          def plan_steady(count)
            v = steady_level
            return false if v.nil?

            plan_event_list.held!.fill(0, count, v)
            true
          end
        end

        class Impulse
          private

          def plan_steady(count)
            plan_event_list.impulses!
            true
          end
        end
      end

      [Gate, Number, Velocity, Lift, Trigger, KeyTrigger, Choke, EnvelopeInputs, Glide].each { |c| c.send(:plan_events!) }

      class KeyTrigger
        def plan_feed(count)
          @from = @reader.cursor
          super
        end
      end

      class EnvelopeInputs
        PORTS = [nil, :trigger, :velocity, :choke].freeze

        # One planned block: #render's four outputs as EventLists.
        def plan_feed(count)
          from = @reader.cursor
          step(count)
          to = @stream.advance(from, count, @sample_rate)
          events = @reader.events(from, to)
          chase = take_chase(to)

          gate = plan_event_list(nil).held!
          trig = plan_event_list(:trigger).impulses!
          vel = plan_event_list(:velocity).held!
          chk = plan_event_list(:choke).impulses!

          if events.empty? && chase.nil?
            gate.fill(0, count, level)
            vel.fill(0, count, @velocity_value)
          else
            start = 0
            items(events, chase, from, @rate_r, count).each do |off, item|
              if off > start
                gate.fill(start, off, level)
                vel.fill(start, off, @velocity_value)
                start = off
              end

              if item.is_a?(MIDI::Source::Chase)
                chase(item.event)
                next
              end

              t = item.velocity if item.type == :note_on
              trig.impulse(off, t.to_f) if t && t > trig.impulse_at(off)
              chk.impulse(off, 1.0) if (item.type == :choke || item.all_sound_off?) && 1.0 > chk.impulse_at(off)

              handle(item)
            end

            if start < count
              gate.fill(start, count, level)
              vel.fill(start, count, @velocity_value)
            end
          end

          @tail += count if ended?
          nil
        end

        class Port
          include Plan::Describable

          def plan_inputs
            [@inputs]
          end

          def plan_describe(p)
            p[@inputs] # the inputs node is described (and fed) in the same plan
            p.events(@inputs, @output)
          end
        end
      end

      class Glide
        def plan_unsupported_reason
          return 'a glide time node (not planned yet)' if @time_node

          super
        end

        private

        # Like #fill, recording the ramp (see Plan::EventList#glide) or, for
        # curves, the rendered samples.
        def plan_fill(list, from, to)
          @segment_start = to
          unless @gliding
            list.fill(from, to, @number.to_f)
            @value = @number
            return
          end

          n = to - from
          if @curve
            t = Numo::DFloat.new(n).seq(@position + 1)
            t.inplace / @length
            t.inplace.clip(0.0, 1.0)
            shaped = @curve.lookup(t)
            shaped.inplace * (@number - @start)
            shaped.inplace + @start
            buf = Numo::SFloat.cast(shaped)
            list.buffer(from, to, buf)
            @value = buf[n - 1]
          else
            list.glide(from, to, @start, @number, @position, @length, @overshoot_k)
            @value = Plan::EventList.glide_last(n, @start.to_f, @number.to_f, @position, @length, @overshoot_k)
          end

          @position += n
          @gliding = false if @position >= @length
        end

        public

        def plan_feed(count)
          from = @reader.cursor
          step(count)
          to = @stream.advance(from, count, @sample_rate)
          events = @reader.events(from, to)
          chase = take_chase(to)
          list = plan_event_list.held!

          if events.empty? && chase.nil? && (v = steady_level)
            list.fill(0, count, v)
          else
            @segment_start = 0
            start = 0
            items(events, chase, from, @rate_r, count).each do |off, item|
              if off > start
                plan_fill(list, start, off)
                start = off
              end
              @render_offset = off
              item.is_a?(MIDI::Source::Chase) ? chase(item.event) : handle(item)
            end
            plan_fill(list, start, count) if start < count
          end

          @tail += count if ended?
          nil
        end
      end

      class Frequency
        include Plan::Describable

        def plan_inputs
          [@number, *@nodes]
        end

        # #compute: the note number plus the constant, plus each offset
        # node, through the tuning; the latest frequency kept as #value.
        def plan_describe(p)
          v = p[@number]
          v = v + @constant if @constant != 0
          @nodes.each { |node| v = v + p[node] }
          f = p.note_freq(v, Plan::CURRENT_TUNING)
          p.keep_last(f, self, :@value)
          f
        end

        def plan_snapshot
          Plan::Snapshot.capture(self, [:@value])
        end

        def plan_restore(snapshot)
          snapshot.restore(self)
        end
      end

      class NoteEnvelope
        # Notes envelopes' per-block bookkeeping (see #sample).
        def plan_feed(count)
          @start_time = @time
          @idle_at_start = idle?
          @time = @notes.note_stream.advance(@time, count, @sample_rate)
          nil
        end

        # True once the stream is over (#sample may start returning nil).
        def plan_finished?
          stream_over?
        end

        def plan_snapshot
          Plan::Snapshot.capture(self, [:@state, :@time, :@start_time, :@idle_at_start])
        end

        def plan_restore(snapshot)
          snapshot.data.each do |iv, v|
            if iv == :@state
              @state[0..] = v # plans hold this NArray
            else
              instance_variable_set(iv, v)
            end
          end
        end

        class GmTime
          include Plan::Describable

          def plan_inputs
            [@factor]
          end

          # #scale: the time filled, times the factor.
          def plan_describe(p)
            p.const(@time) * p[@factor]
          end
        end
      end
    end
  end
end
