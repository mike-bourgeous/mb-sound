require_relative '../sequence/timeline_node'
require_relative '../sequence/timeline_hold_fade'

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
      # position (with the stretch mode :none, Sample#follow's choice for
      # files that declare themselves one-shots, the sample plays as
      # recorded from each loop start: silence after it at slower tempos,
      # cut short at faster ones).  :resample plays
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
      # With `live: true` among +stretch+'s options (mode: :spectral) the
      # phase vocoder runs as the loop plays instead (+stream+, a
      # Sample::Spectral::Stream shared by the sample's channels, made by
      # Sample#follow): it reads the loop wherever the timeline is, at
      # whatever tempo, as one endless stream, so nothing is restretched
      # or cached and tempo ramps are smooth (about 3% of one core for a
      # stereo loop at 800-sample buffers, 5% at 128; Linux, 2026-11-14).
      #
      # The stretch for a new tempo is made the first time that tempo
      # plays (the slice stretch of a two-bar loop takes 3-15 ms, spectral
      # modes 0.2-2.5 s; #prepare makes them ahead).  On a realtime
      # Session's render thread it is made on a worker instead
      # (LoopPlayer::Restretch; stretch-live-1): the player keeps playing
      # what +interim+ (among +stretch+'s options; INTERIMS) says until
      # the new stretch is ready, then crossfades to it over SWAP_FADE.
      # Offline renders make it at once, as before.  A plan boundary.
      class LoopPlayer
        include GraphNode
        include SampleRateHelper
        include Sequence::TimelineNode
        prepend Sequence::TimelineHoldFade # (holds its place while the transport is paused)
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

        # What a live player plays while the stretch for a new tempo is
        # made off the render thread (+interim+ among Sample#follow's
        # stretch options; see Restretch): :hold, the stretch it was
        # playing, read at the new speed (its pitch moves with the tempo
        # until the new one is ready); :slice, a slice stretch at the new
        # tempo made first (milliseconds; cut at the markers or onsets,
        # crossfaded like a loop sequencer's slices: SLICE_FASTER,
        # SLICE_SLOWER), :hold until that is ready; :coarse, the phase
        # vocoder without the shape lock and with half the overlap made
        # first.  Followers whose own stretch is quick (:slice, :none,
        # :cyclic) hold.
        INTERIMS = [:hold, :slice, :coarse].freeze

        # The interim for spectral followers when none is given.
        DEFAULT_INTERIM = :slice

        # The :slice interim's options sped up and slowed down: how a
        # loop sequencer's renders of sliced loops measured (each slice
        # crossfading at equal power into the next cut's lead-in from a
        # third of its slot; slowed, each slice repeated with parabolic
        # crossfades; design/notes/granular.md).
        SLICE_FASTER = { mode: :slice, slot_fade: 2/3r, fade_law: :power }.freeze
        SLICE_SLOWER = { mode: :slice, fill: :repeat, fade_law: :parabola }.freeze

        # Seconds a live player crossfades from what it played to a
        # stretch made off the render thread.
        SWAP_FADE = 0.05

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

        def initialize(sample, channel: 0, mode: :stretch, stretch: { mode: :slice }, align: :timeline, transport: nil, sample_rate: 48000, reason: nil, clock: nil, stream: nil)
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
          @loop_stretch = LoopPlayer.loop_stretch(@stretch_options.except(:live, :interim))
          @interim = LoopPlayer.interim_for(@stretch_options)
          raise ArgumentError, 'live: true needs the stream Sample#follow makes (sample.follow(stretch: { mode: :spectral, live: true }))' if stretch[:live] && mode == :stretch && stream.nil?
          @stream = mode == :stretch ? stream : nil
          @as_recorded = Sample::NONE_MODES.include?(stretch[:mode])
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
          @frames = 0 # (the player's own time, for Restretch.simulate)
          @playing = nil # (live: the data played, its ratio key, and a crossfade from the data before)
          @playing_key = nil
          @fade_from = nil
          @fade_from_key = nil
          @fade_at = 0
          @full_job = nil # (live: the stretch being made off the render thread, and the interim)
          @interim_job = nil
          @interim_data = nil
          @interim_key = nil
          @failed_key = nil
          @buf = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @node_type_name = 'LoopPlayer'
          @hold_mode = nil # (pausing in place: Sequence::TimelineHoldFade)
          @hold_k = nil
          @hold_i = nil
          @hold_buf = nil
          @graph_node_name = sample.name
          prepare if mode == :stretch && clock.nil? && @stream.nil?
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

          if @stream
            @buf[true] = @stream.pull(@channel, phase, (step / @whole_notes).to_f)
          elsif @follow_mode == :stretch
            play_stretch(ratio_for(wnps), phase)
          else
            @buf[true] = cubic(@source_data, phase * @source_data.length)
          end

          @pos += step * count
          @frames += count
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
          how = @as_recorded ? 'as recorded' : "#{@stretch_options[:mode] || :cyclic} stretch#{', live' if @stream}"
          "LoopPlayer #{@loop_sample.name || 'sample'}#{" ch#{@channel}" unless @loop_sample.mono?} (#{@follow_mode == :stretch ? how : 'resample'}, #{len}#{", #{@clock.is_a?(MB::Sound::Clock) ? @clock : "clock #{@clock.inspect}"}" if @clock}#{"; #{@stretch_reason}" if @stretch_reason})"
        end

        private

        # The stretch ratio for a tempo of +wnps+ whole notes per second,
        # the tempo rounded to BPM_STEP.
        def ratio_for(wnps)
          bpm = (Sequence::TempoMap.bpm_of(wnps) / BPM_STEP).round * BPM_STEP
          bpm = BPM_STEP if bpm <= 0
          Sequence::TempoMap.seconds_at(@whole_notes, bpm).to_f / @loop_sample.seconds
        end

        # Sample#stretch +options+ for audio a player loops: the
        # spectral stretches join their end to their start (wrap: true)
        # whether or not the sample has loop points, unless the options
        # say.
        def self.loop_stretch(options)
          mode = (options[:mode] || :cyclic).to_sym
          spectral = %i[spectral paul].include?(Sample::Spectral::MODE_ALIASES.fetch(mode, mode))
          spectral && !options.key?(:wrap) ? options.merge(wrap: true).freeze : options
        end

        # The interim (INTERIMS) for stretch options +options+ (see
        # INTERIMS: :hold for quick stretch modes).
        def self.interim_for(options)
          i = options[:interim]
          raise ArgumentError, "interim: is one of #{INTERIMS.inspect} (got #{i.inspect})" unless i.nil? || INTERIMS.include?(i)
          mode = (options[:mode] || :cyclic).to_sym
          spectral = %i[spectral paul].include?(Sample::Spectral::MODE_ALIASES.fetch(mode, mode))
          return :hold unless spectral
          i || DEFAULT_INTERIM
        end

        # Fills @buf from the stretch for +ratio+ at loop +phase+s (0..1).
        # Offline: the stretch made at once (#stretched).  Live (on a
        # realtime render thread, Restretch.background?): a stretch not
        # made yet goes to a worker, and the player plays the interim
        # meanwhile.  Both crossfade (SWAP_FADE) whenever what plays
        # changes (#play_target).
        def play_stretch(ratio, phase)
          key = ratio.round(12)
          return play_target(stretched(ratio), key, key, phase) unless Restretch.background?

          target = @stretches[key] || take_full(key)
          if target.nil? && @failed_key != key
            want(ratio, key)
            target = take_full(key)
          end
          target_key = key
          if target.nil?
            take_interim
            target = @interim_data if @interim_key == key
          end
          if target.nil?
            # (:hold: what played, at the new speed; nothing yet: silence)
            target = @playing
            target_key = @playing_key
            return BufferHelper.zero(@buf) if target.nil?
          end
          play_target(target, target_key, key, phase)
        end

        # Fills @buf from +target+ (the stretch made for +target_key+) at
        # loop +phase+s for the ratio +key+, crossfading over SWAP_FADE
        # from what played before whenever it changes: live and offline
        # alike (stretches for two tempos have unrelated phases, so until
        # stretch-attacks-1 an offline render's hard switch clicked at
        # every tempo change and every 1/4 BPM step of a ramp).
        def play_target(target, target_key, key, phase)
          unless target.equal?(@playing)
            if @playing
              @fade_from = @playing
              @fade_from_key = @playing_key
              @fade_at = 0
            end
            @playing = target
          end
          @playing_key = target_key

          read_into(@buf, @playing, @playing_key == key, phase)
          return @buf unless @fade_from

          len = (SWAP_FADE * @sample_rate).round
          g = (Numo::SFloat.new(phase.length).seq(@fade_at + 1) / len).clip(0, 1)
          g = 0.5 - 0.5 * Numo::NMath.cos(g * Math::PI)
          old = read_into(Numo::SFloat.zeros(phase.length), @fade_from, @fade_from_key == key, phase)
          @buf.inplace * g
          @buf.inplace + old * (1 - g)
          @fade_at += phase.length
          @fade_from = nil if @fade_at >= len
          @buf
        end

        # Fills +buf+ from +data+ at loop +phase+s: the nearest samples
        # when +exact+ (the stretch made for this ratio: positions on whole
        # samples stay there), else linearly interpolated (a stretch made
        # for another tempo, read at this one's speed).
        def read_into(buf, data, exact, phase)
          n = data.length
          if exact
            idx = Numo::Int64.cast((phase * n + 1e-6).floor) % n
            buf[true] = data[idx]
          else
            pos = phase * n
            i0 = pos.floor
            frac = pos - i0
            i0 = Numo::Int64.cast(i0) % n
            a = data[i0]
            b = data[(i0 + 1) % n]
            buf[true] = a + (b - a) * frac
          end
          buf
        end

        # Asks the workers for the stretch for +ratio+ (key +key+), and
        # for the interim's, unless they are making them already;
        # cancels jobs for other ratios not started yet.
        def want(ratio, key)
          return if @full_job && @full_job.ratio.round(12) == key
          @full_job&.cancel
          render = Thread.current
          if (opts = interim_options(ratio)) && @interim_key != key && !(@interim_job && @interim_job.ratio.round(12) == key)
            @interim_job&.cancel
            @interim_job = Restretch.submit(Restretch::Job.new(@loop_sample, ratio, opts, render: render), :interim, frame: @frames, rate: @sample_rate)
          end
          @full_job = Restretch.submit(Restretch::Job.new(@loop_sample, ratio, @loop_stretch, render: render), :full, frame: @frames, rate: @sample_rate)
        end

        # The finished stretch for +key+ (cached with the others), or nil;
        # a finished job for another ratio is cached too.
        def take_full(key)
          j = @full_job
          return nil unless j && j.finished? && (j.ready_frame.nil? || @frames >= j.ready_frame)
          @full_job = nil
          jk = j.ratio.round(12)
          if j.failed?
            @failed_key = jk
            MB::Sound.live_error(j.error)
            return nil
          end
          d = j.channels[@channel]
          @stretches[jk] = d
          @stretches.delete(@stretches.keys.first) while @stretches.length > CACHE
          jk == key ? d : nil
        end

        # Takes a finished interim stretch.
        def take_interim
          j = @interim_job
          return unless j && j.finished? && (j.ready_frame.nil? || @frames >= j.ready_frame)
          @interim_job = nil
          return if j.failed?
          @interim_data = j.channels[@channel]
          @interim_key = j.ratio.round(12)
        end

        # The Sample#stretch options of the interim stretch for +ratio+,
        # or nil (:hold).
        def interim_options(ratio)
          case @interim
          when :slice
            (ratio - 1).abs < 1e-12 ? nil : (ratio < 1 ? SLICE_FASTER : SLICE_SLOWER)
          when :coarse
            @loop_stretch.merge(lock: :peaks, overlap: 2)
          end
        end

        # The channel's data stretched by +ratio+ (cached).
        def stretched(ratio)
          key = ratio.round(12)
          d = @stretches.delete(key)
          d ||= (ratio - 1).abs < 1e-12 ? @source_data : @loop_sample.stretch(ratio, **@loop_stretch).data(@channel)
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
          last_inc = 0.0
          c.pieces(a, a + count, ctx).each do |r0, r1, _pos0, step|
            bp_rf, bp_pos, _ = c.breakpoint(r0, ctx)
            i0 = (r0 - a).to_i
            n = (r1 - r0).to_i
            next if n <= 0
            base = (((bp_pos - @clock_zero) % len) / len).to_f
            inc = (step / len).to_f
            phase[i0...(i0 + n)] = (Numo::DFloat.new(n).seq + (r0 - bp_rf).to_f) * inc + base
            last_inc = inc
            step0 ||= step
          end
          phase -= phase.floor
          @clock_rf = a + count

          if @stream
            @buf[true] = @stream.pull(@channel, phase, last_inc)
          elsif @follow_mode == :stretch
            # The loop's length in seconds at the clock's rate now
            seconds = step0 && step0 > 0 ? len / (step0 * ctx.clock_rate) : @loop_sample.seconds.to_r
            play_stretch(clock_ratio(seconds), phase)
          else
            @buf[true] = cubic(@source_data, phase * @source_data.length)
          end
          @frames += count
          @buf
        end

        # The stretch ratio for a loop lasting +seconds+ (quantized to
        # CLOCK_STEP steps around 1, so a moving speed reuses stretches;
        # exact for a sample played as recorded, which costs nothing to
        # make and must not drop or repeat a sample).
        def clock_ratio(seconds)
          r = seconds.to_r / @loop_sample.seconds.to_r
          return r.to_f if @as_recorded
          steps = (Math.log(r.to_f) / Math.log(1 + CLOCK_STEP.to_f)).round
          steps.zero? ? 1.0 : (1 + CLOCK_STEP.to_f) ** steps
        end
      end
    end
  end
end

require_relative 'loop_player_restretch'
