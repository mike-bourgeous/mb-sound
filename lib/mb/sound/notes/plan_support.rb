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
          :@delay, :@delay_buf, :@time_node, :@time_buf, :@spec, :@first_fill, :@uniform, :@render_offset, :@segment_start, :@adding, :@from,
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

          nil
        end

        # The events op, smoothed (Op::Smooth) for controllers with a
        # Notes::Smoother.
        def plan_describe(p)
          v = p.events(self)
          @smoother ? p.smooth(v, @smoother, plan_jumps) : v
        end

        # The jump offsets of the block being planned for Op::Smooth (see
        # #smooth_jump), an Array the feed refills each block.
        def plan_jumps
          @plan_jumps ||= []
        end

        # The EventList for output +port+ (nil: the main output), made on
        # first use.
        def plan_event_list(port = nil)
          (@plan_lists ||= {})[port] ||= Plan::EventList.new
        end

        # True once the stream is over, or when its last event comes before
        # the end of the next +count+ samples (see Plan::EventList: the node
        # may start ending the graph).  Ending inside a planned block would
        # be exact, but check mode couldn't replay it (the stream doesn't
        # keep events every reader has passed), so that block runs unfused.
        def plan_finished?(count)
          return true if ended?

          last = @stream.music_end
          !last.nil? && last < @stream.advance(@reader.cursor, count, @sample_rate)
        end

        # One planned block: the node's #sample without the buffer (see
        # the class description).  A FeedGroup reads the events once for
        # all the nodes of a region on one stream.
        def plan_feed(count)
          from = @reader.cursor
          to = @stream.advance(from, count, @sample_rate)
          plan_feed_events(count, from, to, plan_relevant(@reader.events(from, to)), ended?)
        end

        # The rest of #plan_feed, for the block from stream time +from+ to
        # +to+ with its +events+ (read through this node's reader, without
        # those #plan_relevant leaves out), and whether the reader has
        # +ended+ after reading them.
        def plan_feed_events(count, from, to, events, ended)
          chase = take_chase(to)

          unless events.empty? && chase.nil? && plan_steady(count)
            step(count)
            rec = (@plan_recorder ||= Plan::Recorder.new(plan_event_list)).start(count)
            render(rec, items(events, chase, from, @rate_r, count))
          end

          plan_smoother_feed(count) if @smoother
          @tail += count if ended
          nil
        end

        # The reader, stream, and sample rate a FeedGroup uses (for
        # internal use).
        def plan_reader = @reader
        def plan_stream = @stream

        # Groups +feeders+ (Notes nodes in one region) by stream and sample
        # rate into FeedGroups (see Plan::Region).
        def self.plan_group(feeders)
          feeders.group_by { |n| [n.plan_stream.__id__, n.sample_rate] }.values.map { |g| g.length > 1 ? FeedGroup.new(g) : g[0] }
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
            # The smoother runs as #sample would run it (Op::Smooth isn't
            # run for a skipped lane)
            @smoother&.process(plan_event_list.render(count), nil, plan_jumps)
            true
          else
            sample(count) && true
          end
        end

        def plan_snapshot
          ivars = instance_variables.reject { |iv|
            PLAN_SKIP.include?(iv) || iv.start_with?('@plan_') || instance_variable_get(iv).respond_to?(:sample)
          }
          Plan::Snapshot.capture(self, ivars, [@reader.cursor, @smoother&.plan_snapshot])
        end

        def plan_restore(snapshot)
          snapshot.restore(self)
          @reader.cursor = snapshot.plain[1][0]
          @smoother&.plan_restore(snapshot.plain[1][1])
        end

        # True if +event+ may change this node's output or state (events
        # that don't only split the output into pieces of the same values,
        # so leaving them out of a feed changes nothing; e.g. controllers
        # for note nodes).  Every event by default.
        def plan_relevant?(event)
          true
        end

        # The class whose #plan_relevant? this node uses (nodes with the same
        # one share a FeedGroup's filtered events; nodes whose relevant
        # events depend on their settings return their own key).
        def plan_relevance_key
          self.class.plan_relevance_key
        end

        def self.plan_relevance_key
          @plan_relevance_key ||= instance_method(:plan_relevant?).owner
        end

        # +events+ without the ones #plan_relevant? leaves out (the same
        # Array if none).
        def plan_relevant(events)
          return events if events.empty?

          i = 0
          while i < events.length
            break unless plan_relevant?(events[i])
            i += 1
          end
          return events if i == events.length

          events.select { |e| plan_relevant?(e) }
        end

        private

        # The smoother's part of a feed (Node#smooth_output before its
        # kernel): its rate, its first value, and this block's jumps.
        def plan_smoother_feed(count)
          @smoother.sample_rate = @sample_rate if @smoother.sample_rate != @sample_rate
          list = plan_event_list
          @smoother.plan_start(list.first_value) if @smoother.plan_unstarted?
          jumps = plan_jumps
          jumps.clear
          if @jumps && !@jumps.empty?
            jumps.concat(@jumps)
            @jumps.clear
          end
        end

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

            plan_event_list.steady!(count, v)
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

      [
        Gate, Number, Velocity, Lift, Trigger, KeyTrigger, Choke, EnvelopeInputs, Glide, FadeIn, PolyPressure,
        Bend, Control, Pressure,
      ].each { |c| c.send(:plan_events!) }

      class ChannelNode
        # Events #handle acts on: reset all controllers and #update's.
        def plan_relevant?(event)
          event.reset_controllers? || plan_updates?(event)
        end
      end

      class Bend
        def plan_updates?(event) = event.type == :bend
      end

      class Control
        def plan_updates?(event) = event.cc?(@spec.number)

        # Relevant events depend on the controller number, so each node
        # filters its own (see FeedGroup).
        def plan_relevance_key
          @plan_relevance_key ||= Object.new
        end
      end

      class Pressure
        def plan_updates?(event) = event.type == :channel_pressure
      end

      class PolyPressure
        # Note events (NoteNode) and poly pressure.
        def plan_relevant?(event)
          super || event.type == :poly_pressure
        end
      end

      class FadeIn
        def plan_unsupported_reason
          return 'a delay node (not planned yet)' if @delay.respond_to?(:sample)

          super
        end

        # Every event (pieces split at events end ramps; see Glide's).
        def plan_relevant?(event)
          true
        end

        private

        # Like #fill, recording the ramp (Plan::EventList#ramp).
        def plan_fill(list, from, to)
          @segment_start = to
          if @position.nil? || @length <= 0 || @position >= @length
            list.fill(from, to, 1.0)
            return
          end

          list.ramp(from, to, @position, @length)
          @position += to - from
        end

        public

        def plan_feed_events(count, from, to, events, ended)
          chase = take_chase(to)
          list = plan_event_list
          @delay_buf = nil

          if events.empty? && chase.nil? && (v = steady_level)
            list.steady!(count, v)
          else
            list.held!
            step(count)
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

          @tail += count if ended
          nil
        end
      end

      class Aftertouch
        include Plan::Describable

        def plan_inputs
          [@poly, @channel]
        end

        # The larger of the two (Numo::SFloat.maximum's choice).
        def plan_describe(p)
          p.max(p[@poly], p[@channel])
        end
      end

      # The Notes nodes of one plan region that read the same stream at the
      # same rate: each block their events are read once (the other
      # readers move to the same cursor, as Stream#read_for's shared read
      # does) and whether the stream ended is asked once, then each node
      # runs Node#plan_feed_events.  Nodes whose readers aren't in step
      # (e.g. a reader that started late) feed one by one.
      class FeedGroup
        # The nodes, in feed order.
        attr_reader :plan_nodes

        def initialize(nodes)
          @plan_nodes = nodes
          @lead = nodes[0]
        end

        def plan_finished?(count)
          return @lead.plan_finished?(count) if in_step?

          @plan_nodes.any? { |n| n.plan_finished?(count) }
        end

        def plan_feed(count)
          return @plan_nodes.each { |n| n.plan_feed(count) } unless in_step?

          reader = @lead.plan_reader
          from = reader.cursor
          to = @lead.plan_stream.advance(from, count, @lead.sample_rate)
          events = reader.events(from, to)
          i = 1
          while i < @plan_nodes.length
            @plan_nodes[i].plan_reader.cursor = to
            i += 1
          end
          ended = @lead.ended?

          # Nodes with the same relevant events share one filtered list
          filtered = (@filtered ||= {}.compare_by_identity).clear
          i = 0
          while i < @plan_nodes.length
            node = @plan_nodes[i]
            ev = events.empty? ? events : (filtered[node.plan_relevance_key] ||= node.plan_relevant(events))
            node.plan_feed_events(count, from, to, ev, ended)
            i += 1
          end
          nil
        end

        def to_s
          "Notes feed group (#{@plan_nodes.length} nodes)"
        end

        private

        def in_step?
          c = @lead.plan_reader.cursor
          i = 1
          while i < @plan_nodes.length
            return false unless @plan_nodes[i].plan_reader.cursor == c
            i += 1
          end
          true
        end
      end

      class NoteNode
        # Note-ons and offs, chokes, and all sound or notes off (NoteNode#handle;
        # NoteNode subclasses that use #other add theirs).
        def plan_relevant?(event)
          case event.type
          when :note_on, :note_off, :choke then true
          when :cc then event.all_sound_off? || event.all_notes_off?
          else false
          end
        end
      end

      class Glide
        # Every event: a ramp is filled in pieces split at events, and a
        # piece that reaches the glide's end ends the ramp (the rest of the
        # buffer holds the note), so other events change the samples.
        def plan_relevant?(event)
          true
        end
      end

      class Trigger
        def plan_relevant?(event)
          event.type == :note_on
        end
      end

      class Choke
        def plan_relevant?(event)
          event.type == :choke || event.all_sound_off?
        end
      end

      class KeyTrigger
        def plan_feed_events(count, from, to, events, ended)
          @from = from
          super
        end
      end

      class EnvelopeInputs
        PORTS = [nil, :trigger, :velocity, :choke].freeze

        # One planned block: #render's four outputs as EventLists.
        def plan_feed_events(count, from, to, events, ended)
          chase = take_chase(to)

          gate = plan_event_list(nil).held!
          trig = plan_event_list(:trigger).impulses!
          vel = plan_event_list(:velocity).held!
          chk = plan_event_list(:choke).impulses!

          if events.empty? && chase.nil?
            gate.fill(0, count, level)
            vel.fill(0, count, @velocity_value)
          else
            step(count)
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

          @tail += count if ended
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

        def plan_feed_events(count, from, to, events, ended)
          chase = take_chase(to)
          list = plan_event_list

          if events.empty? && chase.nil? && (v = steady_level)
            list.steady!(count, v)
          else
            list.held!
            step(count)
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

          @tail += count if ended
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
          @time = plan_note_stream.advance(@time, count, @sample_rate)
          nil
        end

        # True once the stream is over (#sample may start returning nil):
        # #stream_over?.
        def plan_finished?(count)
          last = plan_note_stream.music_end
          !last.nil? && last < @time
        end

        private

        # The Notes' note stream, kept while planned (Notes#note_stream
        # holds it weakly; it has no reader of this envelope's, so keeping
        # it holds no events back).
        def plan_note_stream
          @plan_note_stream ||= @notes.note_stream
        end

        public

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
