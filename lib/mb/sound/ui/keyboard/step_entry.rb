module MB
  module Sound
    module UI
      class Keyboard
        # Step entry (Tab in KEYS mode): builds a Seq note by note, with no
        # timing from the keyboard.  One row of notes and the number keys
        # for lengths, as on a step-time sequencer:
        #
        #     lower row (z s x d c ... /)  a note of the current length (Shift: accented)
        #     1-7       whole, half, quarter, 8th, 16th, 32nd, 64th
        #     8 / 9     dotted / triplet (toggles)
        #     r / t     a rest / a tie (holds the previous note one more step)
        #     a / `     accent / slide on the last step
        #     notes within CHORD seconds (or, with key releases, while a
        #     note key is held) join the last step as a chord
        #     Backspace undo a step, Delete clear, p play it, Enter done,
        #     w swap it (looping) into the armed tracks at their next
        #     launch points (also Shift-Enter where the terminal sends it
        #     apart from Enter: the kitty protocol), Tab back to playing;
        #     - + and arrows as in play mode
        #
        # The clip is real Ruby built through the DSL (`seq(C4, Rest,
        # E4.n4.acc, C4.n4 & E4.n4).n8`), so #clip prints itself back with
        # to_ruby (the pane's preview) and Enter hands a Clip to
        # Keyboard#on_finish.  Every note entered sounds for its length
        # (capped at a second) through the keyboard's output.
        class StepEntry
          # Number keys and their note divisions.
          LENGTHS = { '1' => 1, '2' => 2, '3' => 4, '4' => 8, '5' => 16, '6' => 32, '7' => 64 }.freeze

          # Seconds within which notes join the last step as a chord.
          CHORD = 0.08

          # One step: +kind+ :note, :rest, or :tie; +notes+ (MIDI numbers)
          # for notes; +div+ the division (8 for an 8th), +dotted+,
          # +triplet+; marks +accent+ and +slide+.
          Step = Data.define(:kind, :notes, :div, :dotted, :triplet, :accent, :slide) do
            def length
              l = Rational(1, div)
              l *= 3/2r if dotted
              l *= 2/3r if triplet
              l
            end
          end

          # What the pane shows: +text+ the Ruby of the clip (or nil),
          # +length+ label of the current length, +count+ steps, +total+
          # whole notes.
          View = Data.define(:text, :length, :count, :total, :steps)

          attr_reader :div, :steps

          # +tempo+ gives seconds per whole note (default: the shared
          # Transport's).
          def initialize(keyboard, tempo: nil)
            @keyboard = keyboard
            @tempo = tempo || -> { 240.0 / Sequence.transport.bpm }
            @steps = []
            @div = 8
            @dotted = false
            @triplet = false
            @last_note_at = nil
            @down = {}
            @preview = []
            @clip = nil
            @view = nil
          end

          def dotted? = @dotted
          def triplet? = @triplet

          # Handles key +k+ at +now+: true if handled, nil to let play
          # mode handle it (octave, velocity, Esc, ...).
          def key(k, now)
            ch = k.key
            if k.release?
              @down.delete(ch.is_a?(String) ? ch.downcase : ch)
              return ch.is_a?(String) && note_key?(ch) ? true : nil
            end

            if ch.is_a?(String) && (k.mods - [:shift]).empty?
              base = SHIFTED[ch] || ch.downcase
              if LOWER.key?(base)
                note(LOWER[base], k.mods.include?(:shift) || ch != base, now) unless k.repeat?
                @down[base] = true if @keyboard.releases?
                return true
              end
              return true if k.repeat?
              return command(ch, now)
            end

            case ch
            when :backspace then undo
            when :delete then clear
            when :enter then k.mods == [:shift] ? swap : finish
            when :tab then @keyboard.entry = :play
            else return nil
            end
            true
          end

          # Plays due preview notes.  Returns true if any played.
          def tick(now)
            played = false
            while (e = @preview.first) && e[0] <= now
              @preview.shift
              @keyboard.audition(e[1], e[2], e[0], e[3])
              played = true
            end
            played
          end

          # The time of the next preview note, or nil.
          def next_due
            @preview.first&.first
          end

          # Stops a preview.
          def stop_preview
            @preview.clear
          end

          # The clip built so far (a Seq), or nil without steps.
          def clip
            return nil if @steps.empty?
            @clip ||= build
          end

          # Clears the steps.
          def clear
            @steps = []
            changed
          end

          # Removes the last step.
          def undo
            @steps = @steps[0...-1]
            @last_note_at = nil
            changed
          end

          def view
            @view ||= begin
              c = clip
              View.new(text: c&.to_ruby, length: length_label, count: @steps.length, total: @steps.sum(0r, &:length), steps: @steps.dup.freeze)
            end
          end

          # The current length as Ruby ("n8", "n8.d", "n16.t").
          def length_label
            "n#{@div}#{@dotted ? '.d' : ''}#{@triplet ? '.t' : ''}"
          end

          private

          def note_key?(ch)
            LOWER.key?(SHIFTED[ch] || ch.downcase)
          end

          def command(ch, now)
            case ch
            when *LENGTHS.keys
              @div = LENGTHS[ch]
              @last_note_at = nil
            when '8'
              @dotted = !@dotted
              @triplet = false
            when '9'
              @triplet = !@triplet
              @dotted = false
            when 'r' then add(:rest)
            when 't' then add(:tie)
            when 'a' then mark(:accent)
            when '`', '~' then mark(:slide)
            when 'p' then preview(now)
            when 'w' then swap
            else
              # Upper-row note keys and other letters do nothing here
              @keyboard.say('step entry: the lower row (z..m , . /) enters notes; 1-7 lengths, r rest, t tie')
              return true
            end
            changed
            true
          end

          def note(semis, accent, now)
            n = @keyboard.note_for(semis)
            return if n > 127

            last = @steps.last
            held = @keyboard.releases? && @down.any? { |k, _| LOWER.key?(k) }
            chord = last&.kind == :note && (held || (@last_note_at && now - @last_note_at <= CHORD))
            if chord
              @steps = @steps[0...-1] + [last.with(notes: (last.notes + [n]).uniq, accent: last.accent || accent)]
            else
              @steps = @steps + [Step.new(kind: :note, notes: [n], div: @div, dotted: @dotted, triplet: @triplet, accent: accent, slide: false)]
            end
            @last_note_at = now
            step = @steps.last
            @keyboard.audition(n, accent ? ACCENT : @keyboard.velocity, now, (step.length * @tempo.call).to_f.clamp(0.08, 1.0))
            changed
          end

          def add(kind)
            @steps = @steps + [Step.new(kind: kind, notes: [], div: @div, dotted: @dotted, triplet: @triplet, accent: false, slide: false)]
            @last_note_at = nil
          end

          def mark(name)
            last = @steps.last
            return @keyboard.say('no note to mark yet') unless last&.kind == :note
            @steps = @steps[0...-1] + [last.with(name => !last.public_send(name))]
          end

          # Swaps the clip so far (looping) into the armed tracks at their
          # next launch points, keeping the steps for more edits.
          def swap
            c = clip
            return @keyboard.say('no steps yet: play notes on the lower row') unless c
            @keyboard.swap_in(c.loop)
          end

          def finish
            c = clip
            return @keyboard.say('no steps yet: play notes on the lower row') unless c
            @keyboard.finished(c)
            clear
          end

          def preview(now)
            c = clip or return
            whole = @tempo.call
            @preview = c.events.sort_by(&:start).map { |e|
              [now + (e.start * whole).to_f, e.value, (e.velocity.to_f * 127).round.clamp(1, 127), (e.length * whole).to_f]
            }
          end

          def changed
            @clip = nil
            @view = nil
          end

          # The Seq, with the commonest plain length factored out
          # (`seq(C4, E4, G4.n4).n8`).
          def build
            plain = @steps.reject { |s| s.dotted || s.triplet || (s.kind == :note && s.notes.length > 1) }
            common = plain.map(&:div).tally.max_by { |d, n| [n, d == 8 ? 1 : 0] }&.first
            items = @steps.map { |s| item(s, s.div == common && !s.dotted && !s.triplet && !(s.kind == :note && s.notes.length > 1)) }
            c = MB::Sound.seq(*items)
            common ? c.public_send(:"n#{common}") : c
          end

          # The DSL value for step +s+ (+bare+: leave its length unset).
          def item(s, bare)
            case s.kind
            when :rest then sized(Sound::Rest, s, bare)
            when :tie then sized(Sound::Tie, s, bare)
            else
              parts = s.notes.map { |n|
                v = sized(note_const(n), s, bare && s.notes.length == 1)
                v = v.acc if s.accent
                v = v.slide if s.slide
                v
              }
              parts.length == 1 ? parts[0] : parts.reduce(:&)
            end
          end

          def sized(v, s, bare)
            return v if bare
            v = v.public_send(:"n#{s.div}")
            v = v.d if s.dotted
            v = v.t if s.triplet
            v
          end

          # The note constant (C4, Fs3) for MIDI note +n+, so the Ruby
          # reads as notes.
          def note_const(n)
            name = Note.new(n).name
            name.match?(/\A[A-G]s?\d\z/) && Sound.const_defined?(name, false) ? Sound.const_get(name, false) : Note.new(n)
          end
        end
      end
    end
  end
end
