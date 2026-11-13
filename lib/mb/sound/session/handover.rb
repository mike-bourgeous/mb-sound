require_relative '../quiet_run'

module MB
  module Sound
    class Session
      # How one chain of nodes takes over from older chains on an exact
      # frame: the machinery behind master and bus chains (Session::Master,
      # Session::Buses) and rack slots (GraphNode::Slot, racks R3), so a
      # spill-over, a crossfade, and a cut behave the same everywhere.
      #
      # The chains are Master::Chain values (or anything with the same
      # fields): +mode+ (:spill, :fade, :cut), +started+, +feeding+,
      # +gain+/+gain_step+ (output level and its change per frame),
      # +input_from+/+input_until+ (where the input starts and stops in the
      # switch buffer), +ramp_from+ (where the gain starts changing),
      # +tail_start+/+quiet+/+tail_done+ (a spill-over tail's QuietRun).
      #
      # - :spill (the default for new chains): the old chains get silence
      #   from the switch frame, so tails ring out, and are dropped on the
      #   exact frame their tail has been quiet for QuietRun::QUIET_SECONDS
      #   (or faded over Master::TAIL_FADE_SECONDS from the frame it has
      #   rung Master::MAX_TAIL_SECONDS).
      # - :fade: both are fed; the new chain's gain rises and the old ones'
      #   falls by +step+ per frame from the switch frame.
      # - :cut: a fade over one frame.
      module Handover
        module_function

        # Starts +chain+ at frame +offset+ of the current buffer, handing
        # over from the +older+ chains by +mode+ (:spill, :fade, or :cut),
        # with +step+ the gain change per frame of a fade (1.0 for a cut).
        def start(chain, older, offset, mode, step)
          if mode == :spill
            chain.input_from = offset
            older.each do |c|
              next unless c.started && c.feeding
              c.feeding = false
              c.input_until = offset
            end
          else
            chain.gain = 0.0
            chain.gain_step = step
            chain.ramp_from = offset
            older.each do |c|
              next unless c.started
              c.gain_step = -step
              c.ramp_from = offset
            end
          end
        end

        # Returns per-frame gains for chain +c+ while it fades (holding its
        # level until frame +offset+), or nil at full level, and moves its
        # gain on by +count+ frames.
        def ramp(c, count, offset)
          return nil if c.gain >= 1 && c.gain_step >= 0

          ramp = Numo::SFloat.new(count).fill(c.gain)
          if c.gain_step != 0 && offset < count
            ramp[offset..] = Numo::SFloat.new(count - offset).seq(c.gain + c.gain_step, c.gain_step)
          end
          ramp = ramp.clip(0, 1)

          c.gain = MB::M.clamp(c.gain + c.gain_step * (count - offset), 0.0, 1.0)
          c.gain_step = 0.0 if c.gain >= 1 && c.gain_step > 0
          ramp
        end

        # Follows a spill-over chain's tail (+data+, the chain's output for
        # +count+ frames from frame +frame+ on its owner's clock): it began
        # where the chain's input stopped (Chain#input_until in the switch
        # buffer), is done once it has been quiet for
        # QuietRun::QUIET_SECONDS (a QuietRun ending on the exact frame:
        # session-2, the maintainer's "Exact frame"), and fades out over
        # Master::TAIL_FADE_SECONDS from the exact frame it has rung
        # Master::MAX_TAIL_SECONDS.  Returns how many of the frames to mix:
        # all of them, or fewer when the tail ends inside them (the chain
        # is then done: Chain#tail_done).
        def track_tail(c, data, count, rate, frame)
          unless c.tail_start
            c.tail_start = frame + (c.input_until || 0)
            c.quiet = QuietRun.new((QuietRun::QUIET_SECONDS * rate).round, from: c.tail_start)
          end

          cap = c.tail_start + (Master::MAX_TAIL_SECONDS * rate).round
          if c.gain_step >= 0 && cap < frame + count
            c.gain_step = -1.0 / (Master::TAIL_FADE_SECONDS * rate)
            c.ramp_from = MB::M.max(cap - frame, 0)
          end

          c.quiet.track_all(data, frame)
          ends = c.quiet.ends_at
          return count if ends > frame + count

          c.tail_done = true
          MB::M.max(ends - frame, 0)
        end

        # True if chain +c+ of +list+ can be dropped: it was replaced and
        # has faded out or gone quiet.
        def done?(c, list)
          return false if c.equal?(list.last) || !c.started

          faded = c.gain <= 0 && c.gain_step < 0
          silent = !c.feeding && (c.bypass? || c.tail_done)
          faded || silent
        end
      end
    end
  end
end
