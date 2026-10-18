module MB
  module Sound
    class Session
      # Decisions made by params read ahead of time (midi-consol-2; see
      # GraphNode::Knob::ValueAt and MIDI::Param): a knob read for a future
      # timeline position answers what is known when it is asked, so the
      # answer depends on when the reader asked (a generator computing its
      # next cycle on the scheduler thread).  The Session logs every such
      # decision, takes save the log, and a replaying Session answers from
      # it, so takes replay the same decisions at any buffer size and
      # thread timing.
      module Decisions
        # A logged decision: the knob (or other param) +name+, the session
        # +epoch+ (seeks counted from the start), the timeline position
        # +pos+, and the +value+ decided.
        Decision = Data.define(:name, :epoch, :pos, :value)

        # Records a decision (see the module comment).
        def log_decision(name, pos, value)
          row = Decision.new(name: name, epoch: epoch, pos: pos.to_r, value: value)
          @decision_lock.synchronize { @decision_log << row }
          row
        end

        # The decisions logged since index +from+ (see #decision_log_length).
        def decision_log(from = 0)
          @decision_lock.synchronize { @decision_log[from..] || [] }
        end

        # The number of decisions logged so far.
        def decision_log_length
          @decision_lock.synchronize { @decision_log.length }
        end

        # Answers decisions from +rows+ ([name, epoch, pos, value], epochs
        # counted from +base_epoch+) instead of deciding again (a take
        # replay; see Take::Replay#decisions).
        def replay_decisions!(rows, base_epoch: 0)
          table = {}
          rows.each { |name, ep, pos, value| table[[name, ep + base_epoch, pos.to_r]] = value }
          @decision_lock.synchronize { @replayed_decisions = table.freeze }
        end

        # The recorded decision for param +name+ at timeline position +pos+
        # in the current epoch, or nil (not replaying, or none recorded).
        def replayed_decision(name, pos)
          table = @replayed_decisions
          return nil if table.nil? || table.empty?
          table[[name, epoch, pos.to_r]]
        end

        # Knob segments (GraphNode::Knob::Hold/Ramp/Follow) for the turns of
        # +knob+ waiting in the change queue that land at or before timeline
        # position +pos+, for Knob#value_at.  The block gives the frame of a
        # landing position.  Reads the queue without the render lock (a
        # copy of the Array; changes are immutable once queued).
        def queued_knob_segments(knob, pos)
          list = @changes.dup
          list.filter_map { |c|
            next unless c.kind == :turn && c.subject == knob.name && c.time && c.time <= pos
            data = c.entry&.data || {}
            frame = yield(c.time)
            next if frame.nil?
            turn_segment(knob, data, frame)
          }
        rescue ArgumentError
          []
        end

        private

        def init_decisions
          @decision_lock = Mutex.new
          @decision_log = []
          @replayed_decisions = nil
        end

        # The knob segment a queued turn with journal +data+ starts on
        # +frame+ (see #queued_knob_segments).
        def turn_segment(knob, data, frame)
          k = GraphNode::Knob
          return k::Follow.new(frame, nil, nil, [], data[:follow], nil) if data.key?(:follow)

          value = knob.spec.clamp(data[:value])
          frames = if data[:over]
                     knob_frames(data[:over])
                   else
                     smooth = data.key?(:smooth) ? data[:smooth] : knob.spec.smooth
                     (smooth.to_f * knob.sample_rate).round
                   end
          return k::Hold.new(frame, value) if frames <= 1

          curve = data[:curve]
          curve = MB::Sound::Curve[curve] unless curve.nil? || curve.is_a?(MB::Sound::Curve)
          curve = nil if curve.respond_to?(:name) && curve.name == :linear
          from = data[:from] && knob.spec.clamp(data[:from])
          k::Ramp.new(frame, frames, value, curve, from)
        end
      end
    end
  end
end
