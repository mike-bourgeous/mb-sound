require_relative '../sequence/timeline_node'

module MB
  module Sound
    module GraphNode
      # Plays one channel of a loop Sample in time with a Transport (the
      # Session's tempo): the loop's #beats span the same length on the
      # timeline at any tempo, and its position comes from the timeline, so
      # it stays on the bar through tempo changes, seeks, and relaunches.
      # Made by Sample#follow (alias Sample#node(follow: ...)).
      #
      # +mode+ :stretch (default) keeps the pitch: the sample is stretched
      # offline to the current tempo (Sample#stretch with +stretch+'s
      # options, mode: :slice by default; one stretch per BPM_STEP of
      # tempo, cached) and read sample by sample at the timeline's
      # position.  :resample plays
      # the original at the speed the tempo asks (pitch follows, like a
      # turntable or varispeed), with cubic (Catmull-Rom) interpolation and
      # no band-limiting (speeding up aliases a little).
      #
      # +align+ :timeline (default) lines the loop up with bar 1 like a
      # looping clip; :launch counts from the graph's launch (a bar line
      # for `bg ..., on: :bar`).  While the timeline is paused the output
      # is silent.  Never ends (use #until).
      #
      # +clock+ (a Clock, or a clock's name; see MB::Sound::Clock and
      # Sample#clocked) plays the loop on a clock instead of the session
      # tempo: one loop per period on a period clock (19.7.seconds; no
      # tempo needed), its #beats at the clock's tempo on tempo and ratio
      # clocks.  Its phase comes from the clock (session run frames: scene
      # drops, seeks, and replays keep it), counted per sample from each
      # clock cell, so the same at any buffer size.  :stretch restretches
      # when the clock's rate changes (a speed knob) by more than
      # CLOCK_STEP; :resample bends the pitch with it (tape).
      #
      # The stretch for a new tempo is made on the render thread the first
      # time that tempo plays (the slice stretch of a two-bar loop takes
      # 3-15 ms; spectral modes much longer: call #prepare for tempos
      # coming up).  A plan boundary.
      class LoopPlayer
        include GraphNode
        include SampleRateHelper
        include Sequence::TimelineNode
        node_traits memory: :short, timeline: true, fresh: 'it finds its place from the timeline in a rebuilt graph; its stretcher\'s slices start fresh (not moved yet)'

        MODES = [:stretch, :resample].freeze
        ALIGNS = [:timeline, :launch].freeze

        # Stretches are made for tempos rounded to this many BPM, so tempo
        # ramps reuse them (every whole, half, and quarter BPM is exact;
        # in between the read runs up to 1/8 BPM fast or slow, about 2
        # cents at 100 BPM).
        BPM_STEP = 0.25r

        # The most stretches kept per player.
        CACHE = 24

        # Clocked :stretch players restretch when the loop's length on the
        # clock changes by more than this ratio (a speed knob moving), like
        # BPM_STEP for tempo followers (1/2000: under a cent).
        CLOCK_STEP = 1r / 2000

        # The Sample played, and the channel.
        attr_reader :loop_sample, :channel

        # :stretch or :resample (see the class description).
        attr_reader :follow_mode

        # The loop's length on the timeline (whole notes, a Rational).
        attr_reader :whole_notes

        # Why the stretch is what it is (Sample#follow's choice, e.g.
        # "spectral: tonal, spectral flatness 0.000"), or nil.
        attr_reader :stretch_reason

        def initialize(sample, channel: 0, mode: :stretch, stretch: { mode: :slice }, align: :timeline, transport: nil, sample_rate: 48000, reason: nil, clock: nil)
          raise ArgumentError, "Give a Sample to follow the tempo (got #{sample.class})" unless sample.is_a?(Sample)
          raise ArgumentError, "mode: is one of #{MODES.inspect} (got #{mode.inspect})" unless MODES.include?(mode)
          raise ArgumentError, "align: is one of #{ALIGNS.inspect} (got #{align.inspect})" unless ALIGNS.include?(align)
          clock = MB::Sound::Clock.coerce(clock) unless clock.nil?
          beats = sample.beats
          if beats.nil? && !(clock.is_a?(MB::Sound::Clock) && clock.unit == :cycles)
            raise ArgumentError, "#{sample.name || 'The sample'} has no tempo to follow from: give one (Sample[path, bpm: 98] or sample.with(bpm: 98)) or detect it (Sample[path, detect: true]), or play it on a loop period (sample.clocked(19.7.seconds))"
          end

          @loop_sample = sample
          @channel = Integer(channel)
          @follow_mode = mode
          @stretch_options = stretch.dup.freeze
          @stretch_reason = mode == :stretch ? reason : nil
          @align = align
          @transport = transport
          @sample_rate = sample_rate.to_f
          @whole_notes = beats && beats.to_r.rationalize(Rational(1, 100_000)) / sample.meter[1]
          @clock = clock
          @clock_ctx = nil
          @clock_rf = nil
          @clock_zero = nil
          @clock_launch = nil
          @pos = nil
          @zero = 0r
          @source_data = sample.data(@channel)
          @stretches = {}
          @buf = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @node_type_name = 'LoopPlayer'
          @graph_node_name = sample.name
          prepare if mode == :stretch && clock.nil?
        end

        # The clock this loop plays on (a Clock or a clock's name), or nil
        # (the session tempo).
        def clocking
          @clock
        end

        # Plays this loop on +clock+ from now on (see Sequence::Clocked.apply).
        def reclock(clock)
          @clock = clock
          @clock_rf = nil
          self
        end

        # Resyncs to the clock at timeline time +time+ (see
        # Session#render_player).
        def clock_resync(time)
          clock_anchor(time) if @clock
          self
        end

        # Makes (and caches) the stretches for +bpms+ (numbers; the
        # transport's tempo by default), so changing to them later costs
        # nothing on the render thread.  Returns self.
        def prepare(*bpms)
          bpms = [transport.bpm] if bpms.empty?
          bpms.flatten.each { |b| stretched(ratio_for(Sequence::TempoMap.whole_notes_per_second(b))) }
          self
        end

        def sample(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          return BufferHelper.zero(@buf) if timeline_paused?
          return sample_clocked(count) if @clock

          @pos ||= 0r
          wnps = transport.whole_notes_per_second
          step = transport.whole_notes_per_frame(@sample_rate)
          base = ((@pos - @zero) % @whole_notes) / @whole_notes
          phase = Numo::DFloat.new(count).seq * (step / @whole_notes).to_f + base.to_f
          phase -= phase.floor

          if @follow_mode == :stretch
            data = stretched(ratio_for(wnps))
            n = data.length
            idx = Numo::Int64.cast((phase * n + 1e-6).floor) % n # (positions on whole samples stay there)
            @buf[true] = data[idx]
          else
            @buf[true] = cubic(@source_data, phase * @source_data.length)
          end

          @pos += step * count
          @buf
        end

        def sources
          {}
        end

        def plan_unsupported_reason
          'loop players are a plan boundary for now'
        end

        def to_s
          len = @whole_notes ? "#{MB::M.sigfigs(@whole_notes.to_f * 4, 4)} beats" : "#{MB::M.sigfigs(@loop_sample.seconds, 4)} s"
          "LoopPlayer #{@loop_sample.name || 'sample'}#{" ch#{@channel}" unless @loop_sample.mono?} (#{@follow_mode == :stretch ? "#{@stretch_options[:mode] || :cyclic} stretch" : 'resample'}, #{len}#{", #{@clock.is_a?(MB::Sound::Clock) ? @clock : "clock #{@clock.inspect}"}" if @clock}#{"; #{@stretch_reason}" if @stretch_reason})"
        end

        private

        # The stretch ratio for a tempo of +wnps+ whole notes per second,
        # the tempo rounded to BPM_STEP.
        def ratio_for(wnps)
          bpm = (Sequence::TempoMap.bpm_of(wnps) / BPM_STEP).round * BPM_STEP
          bpm = BPM_STEP if bpm <= 0
          Sequence::TempoMap.seconds_at(@whole_notes, bpm).to_f / @loop_sample.seconds
        end

        # The channel's data stretched by +ratio+ (cached).
        def stretched(ratio)
          key = ratio.round(12)
          d = @stretches.delete(key)
          d ||= (ratio - 1).abs < 1e-12 ? @source_data : @loop_sample.stretch(ratio, **@stretch_options).data(@channel)
          @stretches[key] = d
          @stretches.delete(@stretches.keys.first) while @stretches.length > CACHE
          d
        end

        # Catmull-Rom interpolation of +x+ (looping) at positions +pos+.
        def cubic(x, pos)
          n = x.length
          i = pos.floor
          t = pos - i
          i = Numo::Int64.cast(i)
          x0 = Numo::DFloat.cast(x[(i - 1 + n) % n])
          x1 = Numo::DFloat.cast(x[i % n])
          x2 = Numo::DFloat.cast(x[(i + 1) % n])
          x3 = Numo::DFloat.cast(x[(i + 2) % n])
          a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3
          b = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
          c = -0.5 * x0 + 0.5 * x2
          ((a * t + b) * t + c) * t + x1
        end

        def timeline_start(time, _origin)
          @pos = time
          @zero = @align == :launch ? (timeline_launch || time) : 0r
          clock_anchor(time, launch: @align == :launch ? (timeline_launch || time) : nil) if @clock
        end

        # The loop's length in clock units: one cycle on a period clock,
        # its whole notes on tempo and ratio clocks.
        def clock_length(c)
          c.unit == :cycles ? 1r : @whole_notes
        end

        # Lines up with the clock at timeline time +time+ (the next sample
        # read): the run frame there, and with +launch+ (align: :launch)
        # the clock position the loop starts from.
        def clock_anchor(time, launch: nil)
          ctx = clock_ctx
          c = resolved_clock(ctx)
          @clock_ctx = ctx
          if ctx.is_a?(MB::Sound::Session)
            @clock_rf = ctx.run_frame_of(time)
            if launch && @clock_launch != launch
              @clock_launch = launch
              @clock_zero = c.position(ctx.run_frame_of(launch), ctx)
            end
          else
            @clock_rf ||= 0r
          end
          @clock_zero ||= 0r
        end

        def clock_ctx
          span = MB::Sound::Session.span
          span ? span.session : (@clock_ctx.is_a?(MB::Sound::Clock::Free) ? @clock_ctx : MB::Sound::Clock::Free.new(rate: @sample_rate, transport: transport))
        end

        def resolved_clock(ctx)
          MB::Sound::Clock.resolve(@clock, ctx)
        end

        # A buffer on the clock: the phase of each sample from the clock
        # cell it falls in (exact base, whole-sample offsets), so the same
        # floats at any buffer size.
        def sample_clocked(count)
          clock_anchor(transport.position) if @clock_rf.nil?
          ctx = @clock_ctx
          c = resolved_clock(ctx)
          len = clock_length(c)
          a = @clock_rf
          phase = Numo::DFloat.zeros(count)
          step0 = nil
          c.pieces(a, a + count, ctx).each do |r0, r1, _pos0, step|
            bp_rf, bp_pos, _ = c.breakpoint(r0, ctx)
            i0 = (r0 - a).to_i
            n = (r1 - r0).to_i
            next if n <= 0
            base = (((bp_pos - @clock_zero) % len) / len).to_f
            inc = (step / len).to_f
            phase[i0...(i0 + n)] = (Numo::DFloat.new(n).seq + (r0 - bp_rf).to_f) * inc + base
            step0 ||= step
          end
          phase -= phase.floor
          @clock_rf = a + count

          if @follow_mode == :stretch
            # The loop's length in seconds at the clock's rate now
            seconds = step0 && step0 > 0 ? len / (step0 * ctx.clock_rate) : @loop_sample.seconds.to_r
            data = stretched(clock_ratio(seconds))
            n = data.length
            idx = Numo::Int64.cast((phase * n + 1e-6).floor) % n
            @buf[true] = data[idx]
          else
            @buf[true] = cubic(@source_data, phase * @source_data.length)
          end
          @buf
        end

        # The stretch ratio for a loop lasting +seconds+ (quantized to
        # CLOCK_STEP steps around 1, so a moving speed reuses stretches).
        def clock_ratio(seconds)
          r = seconds.to_r / @loop_sample.seconds.to_r
          steps = (Math.log(r.to_f) / Math.log(1 + CLOCK_STEP.to_f)).round
          steps.zero? ? 1.0 : (1 + CLOCK_STEP.to_f) ** steps
        end
      end
    end
  end
end
