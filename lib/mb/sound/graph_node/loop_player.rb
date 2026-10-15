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
      # The stretch for a new tempo is made on the render thread the first
      # time that tempo plays (the slice stretch of a two-bar loop takes
      # 3-15 ms; spectral modes much longer: call #prepare for tempos
      # coming up).  A plan boundary.
      class LoopPlayer
        include GraphNode
        include SampleRateHelper
        include Sequence::TimelineNode

        MODES = [:stretch, :resample].freeze
        ALIGNS = [:timeline, :launch].freeze

        # Stretches are made for tempos rounded to this many BPM, so tempo
        # ramps reuse them (every whole, half, and quarter BPM is exact;
        # in between the read runs up to 1/8 BPM fast or slow, about 2
        # cents at 100 BPM).
        BPM_STEP = 0.25r

        # The most stretches kept per player.
        CACHE = 24

        # The Sample played, and the channel.
        attr_reader :loop_sample, :channel

        # :stretch or :resample (see the class description).
        attr_reader :follow_mode

        # The loop's length on the timeline (whole notes, a Rational).
        attr_reader :whole_notes

        def initialize(sample, channel: 0, mode: :stretch, stretch: { mode: :slice }, align: :timeline, transport: nil, sample_rate: 48000)
          raise ArgumentError, "Give a Sample to follow the tempo (got #{sample.class})" unless sample.is_a?(Sample)
          raise ArgumentError, "mode: is one of #{MODES.inspect} (got #{mode.inspect})" unless MODES.include?(mode)
          raise ArgumentError, "align: is one of #{ALIGNS.inspect} (got #{align.inspect})" unless ALIGNS.include?(align)
          beats = sample.beats
          unless beats
            raise ArgumentError, "#{sample.name || 'The sample'} has no tempo to follow from: give one (Sample[path, bpm: 98] or sample.with(bpm: 98)) or detect it (Sample[path, detect: true])"
          end

          @loop_sample = sample
          @channel = Integer(channel)
          @follow_mode = mode
          @stretch_options = stretch.dup.freeze
          @align = align
          @transport = transport
          @sample_rate = sample_rate.to_f
          @whole_notes = beats.to_r.rationalize(Rational(1, 100_000)) / sample.meter[1]
          @pos = nil
          @zero = 0r
          @source_data = sample.data(@channel)
          @stretches = {}
          @buf = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @node_type_name = 'LoopPlayer'
          @graph_node_name = sample.name
          prepare if mode == :stretch
        end

        # Makes (and caches) the stretches for +bpms+ (numbers; the
        # transport's tempo by default), so changing to them later costs
        # nothing on the render thread.  Returns self.
        def prepare(*bpms)
          bpms = [transport.bpm] if bpms.empty?
          bpms.flatten.each { |b| stretched(ratio_for(b.to_r / 240)) }
          self
        end

        def sample(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          return @buf.fill(0) if timeline_paused?

          @pos ||= 0r
          wnps = transport.whole_notes_per_second
          step = wnps / @sample_rate.to_r
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
          "LoopPlayer #{@loop_sample.name || 'sample'}#{" ch#{@channel}" unless @loop_sample.mono?} (#{@follow_mode}, #{MB::M.sigfigs(@whole_notes.to_f * 4, 4)} beats)"
        end

        private

        # The stretch ratio for a tempo of +wnps+ whole notes per second,
        # the tempo rounded to BPM_STEP.
        def ratio_for(wnps)
          bpm = ((wnps * 240) / BPM_STEP).round * BPM_STEP
          bpm = BPM_STEP if bpm <= 0
          (@whole_notes * 240 / bpm).to_f / @loop_sample.seconds
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
        end
      end
    end
  end
end
