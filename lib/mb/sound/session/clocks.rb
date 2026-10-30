module MB
  module Sound
    class Session
      # Named clocks on a Session (see MB::Sound::Clock and
      # design/notes/arrangement.md, "Clocks"), and the session time they
      # count from: run frames (frames rendered while the timeline moves:
      # never reset by seeks, paused with the timeline, so live sessions
      # and take replays agree) and the odometer (whole notes the timeline
      # advanced, the same way), which ratio clocks follow.
      #
      # The Session is the context Clock methods read (#rate,
      # #per_sample_at, #odometer_at, #tempo_point, #clock_speed_value).
      module Clocks
        # Tempo points kept (each a tempo change while the timeline moved).
        TEMPO_POINTS = 256

        # Run frames: frames rendered while the timeline moved (see
        # Clocks).
        attr_reader :run_frame

        # Whole notes the timeline advanced in total (seeks don't count).
        attr_reader :odometer

        # Defines a clock named +name+ (claiming the name in #names) from
        # +base+ (a Tempo, a Rational ratio of the session tempo, or a
        # period in seconds) with +speed:+ (a number, a knob name, a Knob,
        # or a MIDI::Param), or redefines it (clips playing on it follow
        # the new settings).  Returns the Clock.
        def define_clock(name, base, speed: 1)
          raise ArgumentError, "Clock names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          base = Clock.coerce(base)
          raise ArgumentError, "A clock is made from a tempo, a ratio, or a period, not another clock's name (#{base.inspect})" if base.is_a?(Symbol)
          base = base.base if base.is_a?(Clock)
          knob!(speed) if speed.is_a?(Symbol) # (unknown knobs raise now, with suggestions)

          existing = @clock_lock.synchronize { @clocks[name] }
          if existing
            @render_lock.synchronize { existing.respec(base: base, speed: speed) }
            return existing
          end

          return nil unless @names.claim(name, :clock)
          c = Clock.new(base, name: name, speed: speed, session: self)
          @clock_lock.synchronize { @clocks[name] = c }
          c
        end

        # The clock named +name+, raising with suggestions if there is none
        # (a Clock passes through).
        def clock!(name)
          return name if name.is_a?(Clock)
          @clock_lock.synchronize { @clocks[name] } or raise ArgumentError, "No clock #{name.inspect}#{clock_suggestion(name)}; define it with `clock #{name.inspect}, 19.7.seconds` (or 138.75.bpm, or 5/4r)"
        end

        # The clock named +name+, or nil.
        def clock_named(name)
          @clock_lock.synchronize { @clocks[name] }
        end

        # The clocks (a Hash from name to Clock).
        def clocks
          @clock_lock.synchronize { @clocks.dup }
        end

        # The clocks for listings: name => "19.7 s period, phase 0.42".
        def clock_info
          clocks.transform_values { |c|
            ph = clock_phase(c)
            "#{c.describe}#{", #{ph}" if ph}"
          }
        end

        # Where clock +c+ is now, in words: "cycle 3 + 0.42" for periods,
        # "bar 5 + 0.25" for tempos and ratios (4/4 bars of the clock).
        def clock_phase(c)
          pos = c.position(@run_frame, self)
          whole = pos.floor
          frac = (pos - whole).to_f
          c.unit == :cycles ? "cycle #{whole + 1} + #{format('%.2f', frac)}" : "bar #{whole + 1} + #{format('%.2f', frac)}"
        rescue StandardError
          nil
        end

        # Frames per second for clocks (the output's rate, or 48000).
        def clock_rate
          (output_open? ? sample_rate : 48000).to_r
        end

        # Whole notes per frame of the session timeline at run frame +rf+.
        def per_sample_at(rf)
          tempo_point(rf)[2]
        end

        # The odometer at run frame +rf+ (exact).
        def odometer_at(rf)
          t = tempo_point(rf)
          t[1] + (rf.to_r - t[0]) * t[2]
        end

        # The tempo point [run frame, odometer, whole notes per frame] in
        # effect at run frame +rf+ (the current tempo for run frames after
        # the last moving span).
        def tempo_point(rf)
          pts = @tempo_points
          live = current_tempo_point
          return live if pts.empty? || rf >= live[0]
          i = pts.bsearch_index { |p| p[0] > rf }
          i.nil? ? pts.last : (i > 0 ? pts[i - 1] : pts.first)
        end

        # The run frame of the next tempo change after +rf+, or nil.
        def next_tempo_point(rf)
          p = @tempo_points.find { |x| x[0] > rf }
          p && p[0]
        end

        # The value of a clock's speed source +speed+ at run frame +rf+:
        # a knob (by name or node) at the session frame of that run frame,
        # or a MIDI::Param at its timeline position.
        def clock_speed_value(speed, rf)
          frame, pos = session_point_of(rf)
          ValueSource.value_at(speed, pos, frame: frame, transport: @transport, knobs: self)
        end

        # The run frame where a clock defined now starts counting (its
        # first cell).
        def clock_start_frame
          @run_frame
        end

        # The run frame of timeline position +pos+ in the span being
        # rendered (or now, outside a render).
        def run_frame_of(pos)
          span = Session.span
          if span && span.session.equal?(self) && span.per_sample > 0
            span.run + (pos.to_r - span.pos) / span.per_sample
          else
            @run_frame.to_r
          end
        end

        # Defines the clocks graph documents in +sound+ (a graph, bundle,
        # or Array) declare with `clock` header lines that this Session
        # doesn't have yet (GraphIO::Document#clocks), so their clips find
        # them.  A clock of the same name with other settings goes through
        # MB::Sound.live_error (live: the Session's clock stays).  Returns
        # the names defined.
        def adopt_clocks(sound)
          roots = sound.is_a?(Array) ? sound : [sound]
          roots = roots.flat_map { |r| r.respond_to?(:outputs) && !r.is_a?(GraphNode) ? [r, *r.outputs] : [r] }
          docs = roots.filter_map { |r| GraphIO.document_of(r) }.uniq
          defined = []
          docs.each do |doc|
            doc.clocks.each do |name, spec|
              existing = clock_named(name)
              if existing
                same = Clock.new(spec[:base], speed: spec[:speed] || 1)
                unless existing.kind == same.kind && existing.base_exact == same.base_exact && existing.speed == (spec[:speed] || 1)
                  MB::Sound.live_error(ArgumentError.new("The document's clock #{name.inspect} (#{same.describe}) doesn't match the session's (#{existing.describe}); rename one of them"))
                end
                next
              end
              define_clock(name, spec[:base], speed: spec[:speed] || 1) and defined << name
            end
          end
          defined
        end

        # Takes: the run frame and odometer a replay starts from (see
        # Take#start_state).
        def restore_run(run_frame, odometer)
          @run_frame = Integer(run_frame)
          @odometer = odometer.to_r
          @tempo_points = []
          self
        end

        private

        def init_clocks
          @clocks = {}
          @clock_lock = Mutex.new
          @run_frame = 0
          @odometer = 0r
          @tempo_points = []
          @tempo_live = nil
        end

        def clock_suggestion(name)
          names = clocks.keys
          return ' (there are no clocks yet)' if names.empty?
          s = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s)
          s.empty? ? " (clocks: #{names.map(&:inspect).join(', ')})" : " (did you mean #{s.map { |x| x.to_sym.inspect }.join(' or ')}?)"
        end

        # The tempo point for the current tempo from the current run frame.
        def current_tempo_point
          ps = @transport.whole_notes_per_second / clock_rate.to_r
          tp = @tempo_live
          return tp if tp && tp[2] == ps && tp[0] <= @run_frame
          [@run_frame, @odometer, ps]
        end

        # [session frame, timeline position] of run frame +rf+ in the span
        # being rendered (else now).
        def session_point_of(rf)
          span = Session.span
          if span && span.session.equal?(self)
            off = rf.to_r - span.run
            [span.frame + off.floor, span.pos + off * span.per_sample]
          else
            [@frame, @transport.position]
          end
        end

        # At the start of a span: notes a tempo change and moves
        # variable-speed clocks' cells over the span's run frames.
        def begin_clock_span(count, per_sample)
          last = @tempo_points.last
          if last.nil? || last[2] != per_sample
            @tempo_points.pop if last && last[0] == @run_frame
            @tempo_points << [@run_frame, @odometer, per_sample].freeze
            @tempo_points.shift while @tempo_points.length > TEMPO_POINTS
          end
          @tempo_live = @tempo_points.last
          return if @clocks.empty?
          @clocks.each_value { |c| c.advance(@run_frame, count, self) if c.variable? }
        end

        # At the end of a span: run frames and the odometer move if the
        # timeline moved.
        def end_clock_span(count, whole_notes, moving)
          return unless moving
          @run_frame += count
          @odometer += whole_notes
          if (@run_frame % 48000) < count && !@clocks.empty?
            keep = @run_frame - 4 * 48000
            @clocks.each_value { |c| c.trim(keep) if c.variable? }
          end
        end
      end
    end
  end
end
