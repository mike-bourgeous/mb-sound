module MB
  module Sound
    class Notes
      # The note number of the newest held note (like Notes::Number), gliding
      # from one note to the next in the pitch domain (note numbers, i.e.
      # log frequency) along a smoothstep curve of +time+ seconds (the same
      # shape as GraphNode#smooth), instead of stepping.  Made by
      # NotePitch#glide.
      #
      # When it glides:
      # - Notes that start while another is held (legato), and the return to
      #   an older held note when the newest is released, always glide.
      # - With +legato: false+ (default, "always" portamento), every note
      #   after the first glides from the previous pitch, even after a gap.
      #   With +legato: true+ only legato notes glide (a note-on marked
      #   MIDI::Event#legato? counts, as an allocator's mono lane sends).
      # - A :glide event (MIDI::Event.glide, sent by an allocator to idle
      #   lanes for polyphonic glide) or CC 84 (portamento control) makes
      #   the next note-on glide from its note, legato or not.  It never
      #   changes a sounding note.
      # - The first note, and notes after content jumps (chased), jump,
      #   unless +from:+ gives a start pitch (a Pitch such as `440.hz` or
      #   A4, or a MIDI note number): the output holds it until the first
      #   note, which glides from there (e.g. the old portamento filters
      #   that started at the MIDI default of 440 Hz).  With +time+ 0 the
      #   first note jumps, so a filter after the glide does the gliding.
      #   An Interval (e.g. `-7.st`, `2.oct`) is relative instead: the first
      #   note glides from that far away from itself (unison swarms start
      #   their copies scattered this way; see Pitch#swarm).
      #
      # +overshoot+ (default 0) makes glides pass their target by that
      # fraction of the glide's distance (0.1 = 10%) late in the glide and
      # settle back onto it by the end, with zero slope at both ends (the
      # smoothstep plus a bump k × t³ × (1 - t)², with k found for the
      # overshoot; see .overshoot_k).
      #
      # +shape+ (default nil: the smoothstep above, unchanged) gives the
      # glide another curve from the tweening library (anything
      # MB::Sound::Curve.from takes: :squiggle, :elastic, :back, :bounce,
      # :steps, :s, a Curve, a Proc, ...).  With a named shape,
      # +overshoot+ and +cycles+ (when given) set that curve's options
      # (e.g. the squiggle's size and wiggles; see Curve); otherwise the
      # curve's defaults apply.
      #
      # +time+ is seconds (a number or length), a graph node of seconds
      # (read on the note-on's sample), or :gm: CC 5 (Notes#portamento_time,
      # 2 ms..5 s) with CC 65 (portamento on/off, off by default as in GM2)
      # deciding whether notes glide; CC 84 glides regardless of CC 65.
      class Glide < Number
        # The glide time as given (seconds, a node, or :gm).
        attr_reader :time

        # True if only legato notes glide (see the class description).
        attr_reader :legato

        # The start pitch as given (see the class description), or nil.
        attr_reader :from

        # The overshoot fraction (see the class description).
        attr_reader :overshoot

        # The glide's MB::Sound::Curve, or nil for the default smoothstep
        # (see the class description).
        attr_reader :curve

        # Returns the bump scale k for which the glide curve
        # t²(3 - 2t) + k t³(1 - t)² peaks at 1 + +overshoot+ (found by
        # bisection; 0 for no overshoot).  The bump only passes the target
        # once k > 3, so tiny overshoots still need k near 3.
        def self.overshoot_k(overshoot)
          MB::Sound::Curve.back_k(overshoot)
        end

        def initialize(stream, time:, legato: false, from: nil, overshoot: nil, shape: nil, cycles: nil, notes: nil, sample_rate: 48000)
          super(stream, notes: notes, sample_rate: sample_rate)

          @curve = nil
          if shape.nil?
            raise ArgumentError, 'Glide cycles need a shape (e.g. shape: :squiggle)' unless cycles.nil?
            overshoot ||= 0
            raise ArgumentError, "Glide overshoot must be a number from 0 to 1 (got #{overshoot.inspect})" unless overshoot.is_a?(Numeric) && (0..1).cover?(overshoot)
            @overshoot = overshoot.to_f
            @overshoot_k = Glide.overshoot_k(@overshoot)
          else
            options = { overshoot: overshoot, cycles: cycles }.compact
            @curve = shape.is_a?(Symbol) || shape.is_a?(String) ? MB::Sound::Curve.named(shape, **options) : MB::Sound::Curve.from(shape)
            if !options.empty? && !(shape.is_a?(Symbol) || shape.is_a?(String))
              raise ArgumentError, "Glide overshoot and cycles go with a shape name, not a #{shape.class} (give them to the curve)"
            end
            @overshoot = @curve.options[:overshoot].to_f
            @overshoot_k = 0.0
          end

          @time = time
          @legato = !!legato
          @gm = time == :gm
          @time_node = nil

          case time
          when :gm
            @gm_time = GM_CONTROLS[:portamento_time]
            @gm_raw = @gm_time.default
            @gm_on = false
          when Numeric, Length
            @seconds = Length.seconds(time, sample_rate: @sample_rate).to_f
          else
            raise ArgumentError, "Glide time must be seconds, a length, a node, or :gm (got #{time.inspect})" unless time.respond_to?(:sample)
            @time_node = time.get_sampler
          end

          @from = from
          @from_note = nil
          @from_offset = nil
          if from.is_a?(Interval)
            @from_offset = from.to_semitones.to_f
          elsif !from.nil?
            raise ArgumentError, "Glide start must be a Pitch, a note number, or an Interval (got #{from.inspect})" unless from.is_a?(Numeric) || from.is_a?(MB::Sound::Pitch)
            @number = @from_note = number_of(from)
          end

          @value = @number
          @gliding = false
          @had_note = false
          @node_type_name = "Notes Glide#{' (legato)' if @legato}#{" #{@curve}" if @curve}"
        end

        # The current output note number.
        def value
          @value
        end

        def sample(count)
          if @time_node
            @time_buf = @time_node.sample(count.round)
            return nil if @time_buf.nil?
          end
          super
        end

        def sources
          @time_node ? { stream: @stream, time: @time_node } : super
        end

        private

        def render(buf, items)
          @segment_start = 0
          super
        end

        def fill(buf, from, to)
          @segment_start = to
          unless @gliding
            buf[from...to] = @number
            @value = @number
            return
          end

          # The same operations as t * t * (3 - 2 * t) * (number - start) +
          # start, in place to save allocations (glides are often long, and
          # unison swarms run one per copy)
          n = to - from
          t = Numo::DFloat.new(n).seq(@position + 1)
          t.inplace / @length
          t.inplace.clip(0.0, 1.0)
          return fill_curve(buf, from, to, t) if @curve

          shaped = t * -2
          shaped.inplace + 3
          sq = t * t
          shaped.inplace * sq
          if @overshoot_k != 0
            # + k t³ (1 - t)²
            bump = t * -1
            bump.inplace + 1
            bump.inplace * bump
            sq.inplace * t
            bump.inplace * sq
            bump.inplace * @overshoot_k
            shaped.inplace + bump
          end
          shaped.inplace * (@number - @start)
          shaped.inplace + @start
          buf[from...to] = shaped
          @position += n
          @value = buf[to - 1]
          @gliding = false if @position >= @length
        end

        # #fill for a glide with a curve (see the class description) at
        # positions +t+ (0..1).
        # The curve comes from its value table in C (Curve#lookup), as cheap
        # as the plain smoothstep for any curve.
        def fill_curve(buf, from, to, t)
          shaped = @curve.lookup(t)
          shaped.inplace * (@number - @start)
          shaped.inplace + @start
          buf[from...to] = shaped
          @position += to - from
          @value = buf[to - 1]
          @gliding = false if @position >= @length
        end

        # The output at the current position (see #fill).
        # Constant only while not gliding (see Node::Held#steady_level).
        def steady_level
          return nil if @gliding
          @value = @number
        end

        def current
          return @number unless @gliding

          t = MB::M.clamp(@position.to_f / @length, 0.0, 1.0)
          return @start + (@number - @start) * @curve.call(t) if @curve

          @start + (@number - @start) * (t * t * (3 - 2 * t) + @overshoot_k * t**3 * (1 - t)**2)
        end

        def note_on(event)
          target = number_of(event.note)
          legato = @stack.length > 1 || event.legato?
          from = @from_note
          @from_note = nil
          if @from_offset
            from ||= target + @from_offset
            @from_offset = nil
          end

          glide = from || (@had_note && enabled? && (legato || !@legato))
          @had_note = true
          glide_to(target, from || current, glide)
        end

        def uncovered(entry)
          glide_to(number_of(entry.note), current, enabled?)
        end

        def chase(event)
          @had_note = true
          @from_note = nil
          @from_offset = nil
          glide_to(number_of(event.note), nil, false)
        end

        def other(event)
          case event.type
          when :glide
            @from_note = number_of(event.note) if event.note
          when :cc
            case event.note
            when 84 then @from_note = event.raw.to_f
            when 5 then @gm_raw = event.raw if @gm
            when 65 then @gm_on = event.raw >= 64 if @gm
            when 121 then @gm_on = false if @gm # RP-15 resets portamento
            end
          end
        end

        # True if notes glide at all (always, except :gm with CC 65 off).
        def enabled?
          !@gm || @gm_on
        end

        # The glide time in samples for a note starting now.
        def glide_samples
          seconds = if @gm
                      @gm_time.value(@gm_raw)
                    elsif @time_node
                      @time_buf[MB::M.min(@segment_start, @time_buf.length - 1)]
                    else
                      @seconds
                    end
          (seconds.to_f * @sample_rate).round
        end

        # Moves to note +target+, gliding from +start+ if +glide+ and the
        # glide time is at least two samples.
        def glide_to(target, start, glide)
          @number = target
          length = glide ? glide_samples : 0

          if length > 1 && start != target
            @start = start
            @length = length
            @position = 0
            @gliding = true
          else
            @gliding = false
          end
        end
      end
    end
  end
end
