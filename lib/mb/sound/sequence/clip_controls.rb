module MB
  module Sound
    module Sequence
      # Controller lanes of clips (midi-import-1, 2026-10-28): a clip may
      # carry ControlLanes (MIDI CCs, pitch bend, pressure at exact clip
      # positions) besides its notes, played by MIDI::ClipSource as
      # controller Events so voices read them like live MIDI (`v.mod`,
      # `v.cc(1)`, `v.bend`).  MIDI files bring them (MidiMethods#midi_clip);
      # `events(..., controls:)` writes them; transforms that keep time keep
      # them, and those that move time (stretch, rotate, shift, reverse, repeat,
      # truncate, |, &) move them along.  Note transforms (transpose,
      # legato, humanize, ...) leave them alone.  See design/notes/midi.md
      # (Clips from MIDI files).
      class Clip
        # The default tolerance of #fit_controls: one 7-bit MIDI step of
        # the controller's range.
        FIT_TOLERANCE = 1 / 127.0

        # A step at least this far from the one before (a share of the
        # controller's range: 8 7-bit steps) is a jump, not part of a ramp:
        # #fit_controls holds the old value until just before it.  (Dense
        # ramps of exported envelopes move 1-4 steps a point.)
        FIT_JUMP = 8 / 127.0

        # The longest a fitted jump takes (whole notes; shorter when the
        # steps are closer).
        FIT_JUMP_TIME = 1/128r

        # The clip's ControlLanes (frozen; empty for most clips).
        def controls
          @controls
        end

        # True if the clip has controller lanes.
        def controls?
          !@controls.empty?
        end

        # The lane for +name+ (:cc1, :bend, :pressure, a CC number), or nil.
        def control(name)
          name = :"cc#{name}" if name.is_a?(Integer)
          @controls.find { |l| l.name == name }
        end

        # A copy of this clip with +lanes+ (ControlLanes) instead of its own.
        def with_controls(lanes)
          with_events(@events, controls: lanes)
        end

        # A copy without controller lanes.
        def without_controls
          @controls.empty? ? self : with_controls([])
        end

        # A copy whose step lanes are fitted curves (Gesture.fit: the fewest
        # keys of a monotone cubic or straight lines, whichever needs fewer,
        # passing within +tolerance+ of every step, as a share of the
        # controller's range; one 7-bit step by default), sent at
        # ControlLane::RESOLUTION between keys, so a dense recorded lane
        # becomes a few printable keys that play smoothly.  A step that
        # jumps (FIT_JUMP or more) holds the value before it until just
        # before the jump.  +budget+ caps the keys per lane (default: as many
        # as the tolerance needs); +resolution+ is the spacing of the values
        # sent between keys (whole notes).  Lanes with fewer than 3 steps, and
        # curve lanes, stay as they are.
        def fit_controls(tolerance: FIT_TOLERANCE, budget: nil, resolution: ControlLane::RESOLUTION)
          with_controls(@controls.map { |l| Clip.fit_lane(l, tolerance: tolerance, budget: budget, resolution: resolution) })
        end

        # [[time, lane, value], ...] of the controller values sent at clip
        # positions [from, to) (whole notes from the start of playback,
        # across loop cycles), sorted by time (lanes in clip order at equal
        # times).  Used by MIDI::ClipSource.
        def control_edges(from, to)
          return NO_EDGES if @controls.empty? || !(to > from) || @length <= 0
          if @loop
            first = cycle_of(from)
            last = ((to / @length).ceil - 1)
          else
            return NO_EDGES if from >= @length
            first = last = 0
          end

          out = nil
          cycle = first
          while cycle <= last
            base = cycle * @length
            a = MB::M.max(from - base, 0r)
            b = MB::M.min(to - base, @length)
            @controls.each do |lane|
              lane.edges(a, b).each { |p, v| (out ||= []) << [base + p, lane, v] }
            end
            cycle += 1
          end
          return NO_EDGES unless out
          return out if @controls.length == 1
          out.each_with_index.sort_by { |(t, _l, _v), i| [t, i] }.map!(&:first)
        end

        # [[lane, value], ...] of the lanes' values just before clip
        # position +pos+ (for a launch, seek, or swap landing there; lanes
        # with a value of their own at +pos+ are left out, since
        # #control_edges sends it).  A loop's first cycle has nothing
        # before its start; later cycles see the end of the cycle before.
        def control_chase(pos)
          return EMPTY_CHASE if @controls.empty? || @length <= 0 || pos <= 0
          phase = @loop ? pos % @length : pos
          later_cycle = @loop && pos >= @length
          @controls.filter_map { |lane|
            next if lane.next_at(phase) == phase
            v = lane.value_at(phase)
            v = lane.last_value if v.nil? && later_cycle
            v && [lane, v]
          }
        end

        EMPTY_CHASE = [].freeze

        # The first clip position at or after +pos+ where a lane sends a
        # value, within +pos+'s loop cycle (nil if none; for MIDI::ClipSource's
        # quiet reads, which stop at the next cycle anyway).
        def control_horizon(pos)
          return nil if @controls.empty? || @length <= 0
          if @loop
            base = cycle_of(pos) * @length
          else
            return nil if pos >= @length
            base = 0r
          end
          phase = pos - base
          best = nil
          @controls.each do |lane|
            n = lane.next_at(phase)
            best = n if n && (best.nil? || n < best)
          end
          best && base + best
        end

        # Checks the +:controls+ given to Clip.new (ControlLanes, one per
        # key), dropping points at or after +length+.
        def self.check_controls(controls, length)
          return EMPTY_LANES if controls.nil? || controls.empty?
          raise ArgumentError, "A clip's controls are ControlLanes (got #{controls.inspect})" unless controls.is_a?(Array) && controls.all?(ControlLane)
          keys = controls.map(&:key)
          raise ArgumentError, "A clip has one lane per controller (#{keys.tally.select { |_, n| n > 1 }.keys.map(&:inspect).join(', ')} twice)" unless keys.uniq.length == keys.length
          lanes = length > 0 ? controls.filter_map { |l| l.points.all? { |p, _| p < length } ? l : l.map_points { |p, v| [p, v] if p < length } } : controls
          lanes.freeze
        end

        EMPTY_LANES = [].freeze

        # Lanes +a+ and +b+ together: lanes for the same controller merge
        # their points (+b+'s win at the same position; +a+'s curve).
        def self.merge_lanes(a, b)
          return a if b.empty?
          return b if a.empty?
          out = a.map { |l|
            other = b.find { |x| x.key == l.key }
            other ? l.with_points(l.points + other.points) : l
          }
          out + b.reject { |x| a.any? { |l| l.key == x.key } }
        end

        # +lanes+ moved +offset+ later.
        def self.shift_lanes(lanes, offset)
          lanes.map { |l| l.map_points { |p, v| [p + offset, v] } }
        end

        # +lane+ reversed within +length+: a step lane holds each value over
        # the mirrored span (the value before the first point, nil, wraps
        # from the end), a curve lane's keys are mirrored.
        def self.reverse_lane(lane, length)
          return lane.map_points { |p, v| [length - p, v] if p > 0 } unless lane.stepped?
          pts = lane.points
          list = pts.each_with_index.filter_map { |(p, v), i|
            nxt = i + 1 < pts.length ? pts[i + 1][0] : length
            [length - nxt, v] if nxt <= length
          }
          lane.with_points(list)
        end

        # +lane+ rotated +shift+ later within +length+ (wrapping), with its
        # value at the wrap point added at 0 so the rotated loop holds what
        # it held there.
        def self.rotate_lane(lane, shift, length)
          list = lane.points.map { |p, v| [(p + shift) % length, v] }
          unless list.any? { |p, _| p == 0 }
            v = lane.value_at(length - shift) || lane.last_value
            list << [0r, v]
          end
          lane.with_points(list)
        end

        # +lane+ moved +offset+ later within +length+ without wrapping (see
        # #shift), or nil if no point is left: points moved outside
        # 0...length drop, and a lane moved earlier gets the value it held
        # at the new start at 0.
        def self.shift_lane(lane, offset, length)
          list = lane.points.filter_map { |p, v|
            q = p + offset
            [q, v] if q >= 0 && q < length
          }
          if offset < 0 && list.none? { |p, _| p == 0 }
            v = lane.value_at(-offset)
            list.unshift([0r, v]) unless v.nil?
          end
          list.empty? ? nil : lane.with_points(list)
        end

        # The fitted version of step lane +lane+ (see #fit_controls).
        def self.fit_lane(lane, tolerance:, budget:, resolution: ControlLane::RESOLUTION)
          return lane unless lane.stepped? && lane.points.length >= 3
          pts = lane.points
          lo = lane.type == :bend ? -1.0 : 0.0
          span = 1.0 - lo

          # Steps that jump hold the value before them until just before
          steps = []
          pts.each_with_index do |(p, v), i|
            if i > 0
              pp, pv = pts[i - 1]
              if (v - pv).abs >= FIT_JUMP * span
                hold = p - MB::M.min((p - pp) / 2, FIT_JUMP_TIME)
                steps << [hold, pv] if hold > pp
              end
            end
            steps << [p, v]
          end

          scale = steps.map { |p, _| p.denominator }.reduce(1) { |a, d| a.lcm(d) }
          frames = steps.map { |p, v| [(p * scale).to_i, v] }
          spec = FitSpec.new(lo, span)
          g = MB::Sound::Gesture.fit(frames, spec, tolerance: tolerance, budget: budget || frames.length)
          keys = g.keys.map { |f, v| [Rational(f, scale), v] }
          lane.with_points(keys, curve: g.curve == :linear ? :linear : nil, error: g.error, resolution: resolution)
        end

        # A Knob::Spec stand-in for Gesture.fit: positions 0..1 across a
        # lane's range.
        FitSpec = Struct.new(:lo, :span) do
          def position(v)
            (v - lo) / span
          end
        end
      end
    end
  end
end
