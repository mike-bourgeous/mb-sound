module MB
  module Sound
    module GraphNode
      class Knob
        # Knob#value_at (midi-consol-2): a knob as a MIDI::Param, read at
        # decision points (a transform's note-on, an arp step, a
        # generator's cycle start) instead of sampled per buffer.
        #
        # Rules (the Mac's G3 requirements, 2026-10-17):
        # - A position already rendered (in the span the Session is
        #   rendering, which it advances knobs for before players read) gives
        #   exactly the value rendered there.
        # - A future position gives the value as known at the call: the
        #   current value, or where a ramp in progress or a turn already
        #   queued (with a launch point) puts it at that position.  A follow
        #   (a knob following a node or another knob) is never extrapolated:
        #   while following, the answer is the latest value; a follow queued
        #   before the position answers the value before it starts.
        # - Answers for future positions are decisions: the knob remembers
        #   each one (asking again for the same position gives the same
        #   value, even after a later turn), and the Session logs them so a
        #   take replays the same decisions (see Session::Decisions).
        # - Side-effect free for the sound and callable from any thread: it
        #   takes the knob's own short lock and reads the Session's change
        #   queue without the render lock.
        #
        # Decision lead: a reader deciding +lead+ ahead of a position (a
        # generator computing cycle N + 1 while cycle N plays) sees turns
        # issued before it decides; a turn must be issued at least that far
        # before the position it should reach (design/notes/midi.md,
        # "Parameters that move").
        module ValueAt
          # How many decisions a knob remembers (oldest dropped first).
          DECISIONS = 4096

          # The knob's value at timeline position +pos+ (Rational whole
          # notes; now if nil) or at session frame +frame+ (see ValueAt).
          # +transport+ and +stream+ are the MIDI::Param protocol's (unused
          # here: a knob counts its Session's frames).
          def value_at(pos = nil, frame: nil, transport: nil, stream: nil)
            return @joined.value_at(pos, frame: frame) if @joined

            pos = pos&.to_r
            if @session && pos && (d = @session.replayed_decision(name, pos))
              return d
            end

            frame ||= frame_of_position(pos)
            snap = @lock.synchronize {
              if frame && @span_frame && frame >= @span_frame && frame < @span_frame + @span_count
                out = @span_out
                return out.is_a?(Numo::NArray) ? out[frame - @span_frame].to_f : out.to_f
              end
              return @value if frame.nil? || frame < @next_frame

              memo = pos && @decisions[pos]
              return memo if memo

              [@segment.dup, @pending.map(&:dup), @value, @next_frame]
            }

            value = known_value(frame, *snap, queued_segments(pos, frame))
            decide(pos, value) if pos
            value
          end

          # A param picking one of +choices+ by where this knob is in its
          # range (MIDI::Param::Choice: equal zones with hysteresis), read at
          # decision points like any param.  Choices are anything:
          # lock styles, modes, numbers, note lengths.
          #
          #     knob :style, 0
          #     lock knob(:style).choose(:mash, :play, :along, :chord)
          #     riff.loop.stream.arp(:up, knob(:rate).choose(8, 16, 32))
          def choose(*choices)
            choices = choices[0] if choices.length == 1 && choices[0].is_a?(Array)
            @stepped = true # (gestures keep their steps; see Gesture.fit)
            MIDI::Param::Choice.new(self, choices)
          end

          # True once something reads this knob through #choose (its value
          # picks between steps): gesture lines keep the raw steps
          # (`curve: :step`) rather than fitting curves (Session#gesture_line).
          def stepped?
            @joined ? @joined.stepped? : !!@stepped
          end

          private

          # Remembers a decision for +pos+ (see ValueAt) and logs it in the
          # Session for takes.  Returns +value+.
          def decide(pos, value)
            @lock.synchronize {
              return @decisions[pos] if @decisions.key?(pos)
              @decisions.shift while @decisions.length >= DECISIONS
              @decisions[pos] = value
            }
            @session&.log_decision(name, pos, value)
            value
          end

          # The session frame of timeline position +pos+ (nil outside a
          # Session or for nil): counted from the span being rendered, or
          # from the Session's next frame and the transport's position.
          def frame_of_position(pos)
            return nil if pos.nil? || @session.nil?

            span = Session.span
            if span && span.session.equal?(@session) && span.moving
              base_frame = span.frame
              base_pos = span.pos
              per_sample = span.per_sample.to_r
            else
              base_frame = @session.frame
              base_pos = @session.transport.position
              per_sample = @session.transport.whole_notes_per_second.to_r / @sample_rate.to_r
            end
            return base_frame if per_sample <= 0

            base_frame + ((pos - base_pos) / per_sample).floor
          end

          # Segments for the turns of this knob queued in the Session up to
          # +pos+ (see Session::Knobs#queued_knob_segments), or none.
          def queued_segments(pos, frame)
            return [] unless @session && pos
            @session.queued_knob_segments(self, pos) { |time| frame_of_position(time) }
          end

          # The value at +frame+ from the segment playing now (+segment+,
          # with the value on the last rendered frame +value+), the knob's
          # pending segments, and +queued+ ones, without rendering anything.
          def known_value(frame, segment, pending, value, next_frame, queued)
            list = (pending + queued).reject { |s| s.start > frame }.sort_by.with_index { |s, i| [s.start, i] }
            # A later segment landing on the same frame replaces an earlier one
            list = list.reverse.uniq(&:start).reverse

            current = segment
            v = segment_value(segment, MB::M.max(next_frame - 1, segment.start), value, value)
            list.each do |seg|
              v = segment_value(current, seg.start - 1, v, value) if seg.start > next_frame
              current = seg
            end
            segment_value(current, frame, v, value)
          end

          # The value of segment +seg+ on frame +f+, given +before+ (the
          # value on the frame before it starts, or where it was) and
          # +latest+ (the last rendered value, for follows).
          def segment_value(seg, f, before, latest)
            case seg
            when Hold then seg.value
            when Ramp
              from = seg.from || before
              j = f - seg.start
              return seg.to if j + 1 >= seg.length
              return from if j < 0

              t = (j + 1).to_f / seg.length
              c = seg.curve ? seg.curve.map([t])[0] : t
              if @spec.curve == :exp
                p0 = @spec.position(from)
                p1 = @spec.position(seg.to)
                scale = Math.log(@spec.range.end / @spec.range.begin)
                Math.exp(c * (scale * (p1 - p0)) + Math.log(@spec.range.begin) + p0 * scale)
              else
                c * (seg.to - from) + from
              end
            when Follow
              # Never extrapolated: the latest value while following, or the
              # value before a follow that hasn't started
              seg.start < @next_frame ? latest : before
            when Move
              @spec.clamp(@spec.value(seg.position.clamp(0.0, 1.0)))
            else
              before
            end
          end
        end

        include ValueAt
      end
    end
  end
end
