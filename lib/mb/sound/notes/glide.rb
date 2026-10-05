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
      # - The first note, and notes after content jumps (chased), jump.
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

        def initialize(stream, time:, legato: false, notes: nil, sample_rate: 48000)
          super(stream, notes: notes, sample_rate: sample_rate)

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

          @value = @number
          @gliding = false
          @had_note = false
          @from_note = nil
          @node_type_name = "Notes Glide#{' (legato)' if @legato}"
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

          n = to - from
          t = (Numo::DFloat.new(n).seq(@position + 1) / @length).clip(0.0, 1.0)
          shaped = t * t * (3 - 2 * t)
          buf[from...to] = shaped * (@number - @start) + @start
          @position += n
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
          @start + (@number - @start) * t * t * (3 - 2 * t)
        end

        def note_on(event)
          target = number_of(event.note)
          legato = @stack.length > 1 || event.legato?
          from = @from_note
          @from_note = nil

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
