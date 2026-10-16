module MB
  module Sound
    module MIDI
      class Transform
        # Stream versions of clip operations (midi-consol-1, maintainer
        # decision 3, 2026-10-16: Transform::Spec chains carry them, so
        # they need stream versions): legato, ratchet, and ghost chords.
        # Like every stream transform they only delay, since a stream
        # doesn't know a note's length (or the next note) at its note-on.

        # Notes +fraction+ of their length (see Stream#legato).  Longer
        # notes (1 or more) delay each note-off.  Shorter ones need the
        # note's length at its note-on: notes with a length hint
        # (Event#length_hint: from clips, arps, echoes, ratchets, ...) get
        # their note-off planned then, with no added latency (an earlier
        # played note-off still ends them); notes without one pass through
        # unchanged after one MB::Sound.live_error notice (an error in
        # scripts; maintainer, 2026-10-16: "length hints, else pass +
        # live_error").
        class Legato < NoteMap
          def initialize(parent, fraction, **options)
            super(parent, **options)
            @fraction = Sequence::Clip.check_legato(fraction)
            @noticed = false
            @node_type_name = "legato(#{fraction})"
          end

          private

          def note_off_time(time, delay, on_time)
            return super if @fraction < 1

            start = on_time + delay
            MB::M.max(start + (time - on_time) * @fraction, time)
          end

          def planned_length(out)
            return nil if @fraction >= 1

            hint = out.length_hint
            if hint.nil?
              unless @noticed
                @noticed = true
                MB::Sound.live_error(ArgumentError.new("legato(#{@fraction.to_f}) on a stream shortens only notes with a length hint (from clips, arp, echo, ratchet, len); notes from live keys or files pass through unchanged"))
              end
              return nil
            end

            seconds_of(hint) * @fraction
          end

          # Hints scale (Durations stay Durations, so they follow the tempo).
          def output_hint(out, e, delay, planned)
            hint = out.length_hint
            return super unless hint
            hint.is_a?(Sequence::Duration) ? Sequence::Duration.new(hint.whole_notes * @fraction) : hint * @fraction
          end
        end

        # Strikes each note up to +count+ times, +rate+ apart, while it is
        # held (see Stream#ratchet).
        class Ratchet < NoteMap
          def initialize(parent, count, rate:, velocity: nil, **options)
            super(parent, **options)
            @count = Sequence::Clip.check_ratchet_count(count)
            raise ArgumentError, "A stream's ratchet needs rate: (a note's length isn't known at its note-on), e.g. ratchet(#{count}, rate: 1.n32)" if rate.nil?
            raise ArgumentError, "Ratchet rate must be a positive length (got #{rate.inspect})" unless seconds_of(rate) > 0
            @rate = rate
            @velocity = velocity
            @node_type_name = "ratchet(#{count}, rate: #{rate}#{", velocity: #{velocity}" if velocity})"
          end

          private

          def map_on(e)
            step = seconds_of(@rate)
            Array.new(@count) { |i|
              v = Sequence::Clip.ratchet_velocity(e.velocity, @velocity, i, @count)
              [v == e.velocity ? e : e.with_velocity(MB::M.clamp(v.to_f, 0.0, 1.0)), step * i]
            }
          end

          def note_on(e)
            step = seconds_of(@rate)
            whole = e.length_hint && seconds_of(e.length_hint)
            last = @count - 1
            chain = map_on(e).each_with_index.map { |(out, delay), i|
              # Every hit but the last lasts a step; the last, the rest of
              # the note if its length is known
              hint = i < last ? step : nil
              hint = hint ? MB::M.min(hint, whole - delay) : whole - delay if whole && whole > delay
              out = out.at(e.time + delay).with_length_hint(hint)
              [out.note, out.channel, schedule_on(out), delay, e.time]
            }
            # Every hit but the last ends where the next starts; the last
            # (and any hit sounding at the note-off) ends with the key
            chain[0...-1].each do |note, channel, id, delay, on_time|
              schedule_off(Event.note_off(note, channel: channel, time: on_time + delay + step), id)
            end
            (@chains[[e.channel, e.note]] ||= []) << chain
          end

          def note_off(e)
            key = [e.channel, e.note]
            list = @chains[key]
            chain = list&.shift
            @chains.delete(key) if list && list.empty?
            return unless chain

            chain.each do |note, channel, id, delay, on_time|
              if delay > 0 && on_time + delay >= e.time
                # A hit after the key came up never plays
                @queue.reject! { |q| q[4] == id }
                @pending.delete(id)
                @early_off.delete(id)
              else
                # The ledger drops this for hits already ended
                schedule_off(Event.note_off(note, e.velocity, channel: channel, time: e.time), id)
              end
            end
          end

          def map_note(event)
            event
          end
        end

        # Moves notes to the nearest tones of a silent chord progression
        # that follows the timeline (see Stream#ghost_chords and
        # Sequence::Clip#ghost_chords, whose rules it shares).
        class GhostChords < NoteMap
          def initialize(parent, chords, per: nil, scale: :minor, root: nil, size: 3, harmonic: false, tie: :contour, passing: nil, **options)
            super(parent, **options)
            unless passing.nil?
              raise ArgumentError, "A stream's ghost_chords can't keep passing notes: a note's length isn't known at its note-on (Clip#ghost_chords can)"
            end
            @scale, @classes = Sequence::Clip.ghost_setup(chords, scale: scale, root: root, size: size, harmonic: harmonic, tie: tie)
            @span = per && Sequence::Duration.whole_notes(per)
            @tie = tie
            @previous = nil # the last played note number (for :contour ties)
            @node_type_name = "ghost_chords(#{chords.map(&:inspect).join(', ')}#{", per: #{per}" if per})"
          end

          private

          def map_on(e)
            out = snap(e, @previous)
            n = Sequence::Clip.ghost_number(e.note)
            @previous = n if n
            [[out, 0r]]
          end

          # Chased notes snap without changing the contour.
          def map_note(event)
            snap(event, nil)
          end

          # +e+ moved to the chord of its timeline position.
          def snap(e, prev)
            n = Sequence::Clip.ghost_number(e.note)
            return e if n.nil?

            wn = timeline_at(e.time)
            index = @span ? (wn / @span).floor : transport.bar_at(wn).floor - 1
            pcs = @classes[index % @classes.length]
            return e if pcs.nil?

            up = @tie == :up || (@tie == :contour && prev && prev < n)
            target = Sequence::Clip.nearest_tone(n, pcs, @scale.period, up)
            target == n ? e : e.with_note(Transpose.whole(target))
          end
        end
      end
    end
  end
end
