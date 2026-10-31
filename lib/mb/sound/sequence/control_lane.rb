module MB
  module Sound
    module Sequence
      # A controller lane of a Clip (midi-import-1): the values of one MIDI
      # controller (+:cc+ with its +number+), the pitch bend (+:bend+,
      # -1..1), channel pressure (+:pressure+), or one key's pressure
      # (+:poly_pressure+ with the note +number+), at exact clip positions
      # (Rational whole notes), played by MIDI::ClipSource as controller
      # Events on the clip's channel, so `v.mod`, `v.cc(1)`, `v.bend`, and
      # `v.pressure` read them like live MIDI.
      #
      # +curve+ is how the lane moves between its points:
      #
      # :step (default) - a jump at each point, as recorded (a MIDI file's
      #   controller events one for one);
      # nil - a monotone cubic through the points (Gesture's curve:
      #   Fritsch-Carlson slopes, never overshooting), sent as a value at
      #   every multiple of +resolution+ between them (1/512 of a whole
      #   note by default: 2.6 ms at 180 BPM), so a fitted lane plays
      #   smoothly at full Float precision rather than in 7-bit steps;
      # :linear - straight lines, sent the same way.
      #
      # Clip#fit_controls makes curve lanes from step lanes (Gesture.fit).
      # Lanes are frozen values; positions lie in [0, clip length).
      class ControlLane
        # Lane types and the controller Event each sends.
        TYPES = %i[cc bend pressure poly_pressure].freeze

        # How curve lanes move (see the class description).
        CURVES = [:step, nil, :linear].freeze

        # The spacing of a curve lane's values between its points (whole
        # notes).
        RESOLUTION = 1/512r

        attr_reader :type, :number, :points, :curve, :resolution

        # A bend lane's pitch bend range in semitones (nil: the receiver's,
        # 2 by default), sent as RPN 0 when the clip launches, seeks, or
        # swaps in (a MIDI file's RPN 0 setting; see MIDI::Stream's bend
        # range tracking).
        attr_reader :range

        # The largest distance of the original steps from a fitted curve
        # (0..1 of the controller's range; nil unless made by a fit).
        attr_reader :error

        # +points+ are [[position, value], ...] (positions Rational whole
        # notes, values 0..1, or -1..1 for :bend); a later point at the same
        # position replaces an earlier one.
        def initialize(type, number, points, curve: :step, resolution: RESOLUTION, error: nil, range: nil)
          raise ArgumentError, "A controller lane is one of #{TYPES.map(&:inspect).join(', ')} (got #{type.inspect})" unless TYPES.include?(type)
          if %i[cc poly_pressure].include?(type)
            raise ArgumentError, "A #{type} lane needs a number from 0 to 127 (got #{number.inspect})" unless number.is_a?(Integer) && number.between?(0, 127)
          elsif !number.nil?
            raise ArgumentError, "A #{type} lane has no number (got #{number.inspect})"
          end
          raise ArgumentError, "A lane's curve: is :step, :linear, or nil (cubic) (got #{curve.inspect})" unless CURVES.include?(curve)
          resolution = resolution.to_r
          raise ArgumentError, "A lane's resolution is a positive length in whole notes (got #{resolution})" unless resolution > 0
          unless range.nil? || (type == :bend && range.is_a?(Numeric) && range.real? && range >= 0 && range < 128)
            raise ArgumentError, "Only a bend lane has a range: (semitones 0...128; got #{range.inspect} for #{type})"
          end

          lo = type == :bend ? -1.0 : 0.0
          by_pos = {}
          points.each do |pos, value|
            unless pos.is_a?(Numeric) && pos.real? && !pos.is_a?(Float) && pos >= 0
              raise ArgumentError, "Lane positions are whole notes from 0 as exact numbers (got #{pos.inspect})"
            end
            raise ArgumentError, "Lane values are numbers (got #{value.inspect})" unless value.is_a?(Numeric) && value.real?
            by_pos[pos.to_r] = MB::M.clamp(value.to_f, lo, 1.0)
          end
          raise ArgumentError, 'A controller lane needs at least one point' if by_pos.empty?

          @type = type
          @number = number
          @points = by_pos.sort_by(&:first).map { |p, v| [p, v].freeze }.freeze
          @positions = @points.map(&:first).freeze
          @curve = curve
          @resolution = resolution
          @error = error
          @range = range
          @shapes = curve == :step || @points.length < 2 ? nil : MB::Sound::Gesture.segment_shapes(@positions.map(&:to_f), @points.map(&:last), curve == :linear ? :linear : :cubic).freeze
          freeze
        end

        # Controllers never kept as lanes (MIDI imports and captures):
        # bank select, data entry and (N)RPN selection (RPN 0, the bend
        # range, goes on an imported bend lane), and channel mode messages.
        SKIPPED_CC = [0, 32, 6, 38, *96..101, *120..127].freeze

        # Lane selections other than an Array (MIDI::Import#clip's and
        # captures' +cc:+): true and :steps keep lanes as recorded, :fit
        # fits curves (Clip#fit_controls), false and nil keep none.
        SELECTIONS = [true, :steps, :fit, false, nil].freeze

        # The lane key [type, number] of controller Event +e+ (a MIDI::Event),
        # or nil for notes, skipped CCs (SKIPPED_CC), and the sustain pedal
        # when +sustain+ (it holds notes instead).
        def self.key_for(e, sustain:)
          case e.type
          when :cc
            return nil if SKIPPED_CC.include?(e.note) || (sustain && e.note == 64)
            [:cc, e.note]
          when :bend then [:bend, nil]
          when :channel_pressure then [:pressure, nil]
          when :poly_pressure then [:poly_pressure, e.note]
          end
        end

        # True if +key+ is in selection +cc+ (see SELECTIONS; an Array names
        # CC numbers and :bend/:pressure/:poly_pressure).
        def self.selected?(key, cc)
          return false unless cc
          return true unless cc.is_a?(Array)
          cc.include?(key[0] == :cc ? key[1] : key[0])
        end

        # True if +cc+ is a lane selection (SELECTIONS or an Array of CC
        # numbers and :bend/:pressure/:poly_pressure).
        def self.selection?(cc)
          SELECTIONS.include?(cc) || (cc.is_a?(Array) && cc.all? { |c| (c.is_a?(Integer) && c.between?(0, 127)) || %i[bend pressure poly_pressure].include?(c) })
        end

        # Lanes for the controller events of +events+ ([pos, MIDI::Event]
        # pairs, sorted by pos) in the window [+start+, +stop+), at clip
        # positions +pos+ (a lambda of an event position), each lane's
        # value from before the window chased to the window's start (a
        # point at pos(start) unless one is there), selected by +cc+ (see
        # .selected?).  Sorted by type and number.  The window's start maps
        # wherever +pos+ puts it: a timeline-phase loop wraps (see
        # MIDI::Capture), so its lanes are rotated to begin at 0.
        # +length+ (the clip's, for wrapping positions) gives clip position
        # 0 the value in effect where the window maps to it.
        def self.from_events(events, start, stop, cc:, sustain:, channel: nil, length: nil, &pos)
          before = {}
          inside = Hash.new { |h, k| h[k] = [] }
          events.each do |t, e|
            next unless e.respond_to?(:type) && e.channel
            next if channel && e.channel != channel
            key = key_for(e, sustain: sustain) or next
            next unless selected?(key, cc)
            break if t >= stop
            if t < start
              before[key] = e.value
            else
              inside[key] << [t, e.value]
            end
          end
          keys = (before.keys + inside.keys).uniq.sort_by { |type, n| [TYPES.index(type), n || 0] }
          keys.map { |key|
            pts = inside.fetch(key, [])
            chased = before.key?(key) && pts.none? { |t, _| t == start }
            pts = [[start, before[key]]] + pts if chased
            mapped = pts.map { |t, v| [pos.call(t), v] }
            if length && !mapped.empty? && mapped.none? { |p, _| p == 0 }
              # (a wrapped loop: clip position 0 gets the value in effect
              # at the window time that maps to 0)
              t0 = start + (length - pos.call(start)) % length
              at = pts.reverse_each.find { |t, _| t <= t0 }
              if at
                mapped << [0r, at[1]]
                # (the chased point is then redundant if the lane already
                # holds its value where it lands)
                if chased
                  c = mapped.first
                  prev = mapped.select { |p, _| p < c[0] }.max_by(&:first)
                  mapped.shift if prev && prev[1] == c[1]
                end
              end
            end
            new(key[0], key[1], mapped)
          }
        end

        # A short name: :cc1, :bend, :pressure, :poly_pressure60.
        def name
          @number ? :"#{@type}#{@number}" : @type
        end

        # Curve names in #to_spec and .from_spec (:cubic is nil).
        CURVE_NAMES = { step: :step, linear: :linear, cubic: nil }.freeze

        # A lane from a name (see #name) and a spec: [[position, value],
        # ...] for a step lane, or { points: [...], curve: :cubic |
        # :linear | :step, resolution: } (what `events(..., controls:)`
        # takes and graph documents write; see #to_spec).
        def self.from_spec(name, spec)
          m = name.to_s.match(/\A(cc|poly_pressure)(\d+)\z/)
          type, number = m ? [m[1].to_sym, m[2].to_i] : [name.to_s.to_sym, nil]
          unless TYPES.include?(type)
            raise ArgumentError, "Controller lanes are named cc1..cc127, bend, pressure, or poly_pressure60 (got #{name.inspect})"
          end
          spec = { points: spec } if spec.is_a?(Array)
          raise ArgumentError, "Lane #{name}: points [[position, value], ...] or { points:, curve: } (got #{spec.inspect})" unless spec.is_a?(Hash) && spec[:points].is_a?(Array)
          unknown = spec.keys - %i[points curve resolution range]
          raise ArgumentError, "Lane #{name}: unknown keys #{unknown.map(&:inspect).join(', ')} (points, curve, resolution, range)" unless unknown.empty?
          curve = spec.fetch(:curve, :step)
          raise ArgumentError, "Lane #{name}: curve: is #{CURVE_NAMES.keys.map(&:inspect).join(', ')} (got #{curve.inspect})" unless CURVE_NAMES.key?(curve)
          unless spec[:points].all? { |pt| pt.is_a?(Array) && pt.length == 2 }
            raise ArgumentError, "Lane #{name}: points are [position, value] pairs"
          end
          new(type, number, spec[:points], curve: CURVE_NAMES[curve], resolution: spec.fetch(:resolution, RESOLUTION), range: spec[:range])
        end

        # The spec .from_spec reads: the points for a step lane at the
        # default resolution, else a Hash.
        def to_spec
          pts = @points.map { |p, v| [p, v] }
          return pts if @curve == :step && @resolution == RESOLUTION && @range.nil?
          spec = { points: pts }
          spec[:curve] = CURVE_NAMES.key(@curve) unless @curve == :step
          spec[:resolution] = @resolution unless @resolution == RESOLUTION
          spec[:range] = @range if @range
          spec
        end

        # The lane's identity in a clip (one lane per key): [type, number].
        def key
          [@type, @number]
        end

        # True for lanes sent as recorded.
        def stepped?
          @curve == :step
        end

        # A copy with points from the block (called with each [position,
        # value]; returning [position, value] or nil to drop it), keeping
        # the curve and resolution.  Returns nil when no point is left.
        def map_points(curve: @curve)
          list = @points.filter_map { |p, v| yield(p, v) }
          list.empty? ? nil : ControlLane.new(@type, @number, list, curve: curve, resolution: @resolution, range: @range)
        end

        # A copy with +points+, keeping everything else.
        def with_points(points, curve: @curve, error: @error, resolution: @resolution)
          ControlLane.new(@type, @number, points, curve: curve, resolution: resolution, error: error, range: @range)
        end

        # The lane's value at +pos+ (whole notes within one pass of the
        # clip), or nil before its first point.
        def value_at(pos)
          idx = @positions.bsearch_index { |p| p > pos }
          idx = (idx || @positions.length) - 1
          return nil if idx < 0
          return @points[idx][1] if @shapes.nil? || idx >= @points.length - 1
          segment_value(idx, pos)
        end

        # The lane's last value (what it holds at the end of a pass).
        def last_value
          @points[-1][1]
        end

        # [[position, value], ...] of the values the lane sends at
        # positions in [from, to) of one pass: its points, and for curve
        # lanes the values at multiples of #resolution between them.
        def edges(from, to)
          return EMPTY unless to > from
          out = nil
          i = @positions.bsearch_index { |p| p >= from } || @positions.length
          if @shapes && i > 0 && i < @positions.length
            # Grid values of the segment holding +from+
            out = grid_values(i - 1, from, to, out)
          end
          while i < @positions.length && @positions[i] < to
            (out ||= []) << @points[i]
            out = grid_values(i, from, to, out) if @shapes && i < @positions.length - 1
            i += 1
          end
          out || EMPTY
        end

        EMPTY = [].freeze

        # The first position at or after +pos+ where the lane sends a value
        # (within one pass), or nil.
        def next_at(pos)
          i = @positions.bsearch_index { |p| p >= pos } || @positions.length
          return nil if i >= @positions.length
          if @shapes && i > 0
            # Inside segment i - 1: its next grid value comes first
            g = grid_after(pos, inclusive: true)
            return g if g < @positions[i]
          end
          @positions[i]
        end

        # The lane as knob keyframes for `turn`: { time => value } with
        # times as Durations from the clip's start (0 for the first) and
        # values mapped onto +range+ (the knob's range; the lane's own
        # values without one), e.g. a controller-only clip's volume ramp
        # as a knob gesture:
        #
        #     ramp = midi_clip('volume ramp.mid', cc: :fit).control(7)
        #     turn :vol, ramp.keyframes(0.0..1.0), curve: ramp.gesture_curve
        def keyframes(range = nil)
          lo = @type == :bend ? -1.0 : 0.0
          @points.to_h { |p, v|
            u = (v - lo) / (1.0 - lo)
            [p.zero? ? 0 : Duration.new(p), range ? range.begin.to_f + (range.end.to_f - range.begin.to_f) * u : v]
          }
        end

        # The `turn` curve: that matches the lane's (:step for step lanes,
        # nil for cubic, :linear).
        def gesture_curve
          @curve
        end

        # A MIDI::Event sending +value+ at stream +time+ on +channel+.
        def event(value, channel:, time:)
          case @type
          when :cc then MIDI::Event.cc(@number, value, channel: channel, time: time)
          when :bend then MIDI::Event.bend(value, channel: channel, time: time)
          when :pressure then MIDI::Event.channel_pressure(value, channel: channel, time: time)
          else MIDI::Event.poly_pressure(@number, value, channel: channel, time: time)
          end
        end

        # The Events a launch, seek, or swap sends before the lane's value:
        # RPN 0 (bend range) for a bend lane with a #range, else none.
        def setup_events(channel:, time:)
          return EMPTY unless @range
          semis = @range.floor
          cents = ((@range - semis) * 100).round
          [
            MIDI::Event.cc_raw(101, 0, channel: channel, time: time), MIDI::Event.cc_raw(100, 0, channel: channel, time: time),
            MIDI::Event.cc_raw(6, semis, channel: channel, time: time), MIDI::Event.cc_raw(38, cents, channel: channel, time: time),
          ]
        end

        def ==(other)
          other.is_a?(ControlLane) && other.key == key && other.points == @points && other.curve == @curve && other.resolution == @resolution && other.range == @range
        end
        alias eql? ==

        def hash
          [key, @points, @curve, @resolution, @range].hash
        end

        def to_s
          "#{name}(#{@points.length} #{@curve == :step ? 'steps' : "keys #{@curve || :cubic}"})"
        end

        def inspect
          "#<ControlLane #{self}>"
        end

        private

        # The value of segment +idx+ (from point idx to idx + 1) at +pos+.
        def segment_value(idx, pos)
          a, va = @points[idx]
          b, vb = @points[idx + 1]
          u = ((pos - a) / (b - a)).to_f
          va + (vb - va) * @shapes[idx].call(u)
        end

        # The first multiple of the resolution after +pos+ (at or after it
        # if +inclusive+).
        def grid_after(pos, inclusive: false)
          k = (pos / @resolution)
          k = inclusive ? k.ceil : k.floor + 1
          k * @resolution
        end

        # Appends the grid values strictly inside segment +idx+ that lie in
        # [from, to) to +out+.
        def grid_values(idx, from, to, out)
          a = @positions[idx]
          b = @positions[idx + 1]
          g = grid_after(MB::M.max(a, from), inclusive: from > a)
          stop = MB::M.min(b, to)
          while g < stop
            (out ||= []) << [g, segment_value(idx, g)].freeze
            g += @resolution
          end
          out
        end
      end
    end
  end
end
