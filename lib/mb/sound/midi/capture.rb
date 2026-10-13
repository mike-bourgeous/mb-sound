module MB
  module Sound
    module MIDI
      # Turns MIDI events stamped with timeline positions (what a Session's
      # MIDI input saw; see Session::MidiInput) into a looping
      # Sequence::Clip: the looper (`rec 4.bars`) and Capture MIDI
      # (`capture :lead`) both use it.  See design/notes/arrangement.md
      # (Recording).
      #
      # A note belongs to the clip if its note-on falls in the window
      # [+from+ - +grace+, +from+ + +length+ - +grace+): a downbeat played a
      # hair early still counts, and it wraps to the end of the loop, so it
      # plays just as early before each downbeat of the loop (the clip is a
      # timeline loop: its notes repeat in phase with the timeline).  Notes
      # end at their note-offs (held by the sustain pedal, CC 64, unless
      # +sustain: false+), or at the end of the window if still held, so
      # note-ons and note-offs stay balanced.  A key struck again while it
      # sounds ends the earlier note there.
      #
      # Event starts are exact Rationals: positions of the frames the
      # events landed on, modulo the length for a loop (so a loop recorded
      # from bar 2 of a 2-bar grid starts with the second bar's notes and
      # plays in phase), less the window's start otherwise.  The clip is
      # Clip#performed? (its velocities are as played).
      module Capture
        # How early (whole notes) a note may start before the window and
        # still count as its downbeat: a 64th note (31 ms at 120 BPM).
        GRACE = 1/64r

        # Builds the clip from +events+ (an Array of [pos, MIDI::Event],
        # sorted by pos; pos in whole notes).  +length+ is the clip's
        # length in whole notes.  +channel+ (0-based) keeps one channel's
        # notes (all channels if nil).
        def self.clip(events, from:, length:, grace: GRACE, channel: nil, sustain: true, loop: true)
          from = from.to_r
          length = length.to_r
          grace = grace.to_r
          raise ArgumentError, "Capture length must be positive (got #{length})" unless length > 0

          start = from - grace
          stop = start + length
          held = {}    # [channel, note] => [pos, velocity]
          pedaled = {} # channel => keys released while the pedal was down
          pedal = Hash.new(false)
          notes = []

          finish = ->(key, pos) {
            on = held.delete(key) or next
            pedaled[key[0]]&.delete(key)
            notes << [on[0], MB::M.min(pos, stop) - on[0], key[1], on[1]]
          }

          events.each do |pos, e|
            next unless e.respond_to?(:type) && e.channel
            next if channel && e.channel != channel
            break if pos >= stop

            key = [e.channel, e.note]
            case e.type
            when :note_on
              next if pos < start
              finish.call(key, pos) if held.key?(key)
              held[key] = [pos, e.velocity]

            when :note_off
              next unless held.key?(key)
              if sustain && pedal[e.channel]
                (pedaled[e.channel] ||= []) << key unless pedaled[e.channel]&.include?(key)
              else
                finish.call(key, pos)
              end

            when :cc
              next unless sustain && e.note == 64
              down = e.value >= 0.5
              if pedal[e.channel] && !down
                (pedaled[e.channel] || []).dup.each { |k| finish.call(k, pos) }
                pedaled[e.channel] = []
              end
              pedal[e.channel] = down
            end
          end

          held.keys.each { |k| finish.call(k, stop) }

          seq_events = notes.sort_by { |p, _, n, _| [p, n] }.map { |p, len, note, velocity|
            # A loop's starts are timeline phases (pos mod length), so it
            # plays in phase with the timeline from where it closes even
            # if the window didn't start on a multiple of its length (a
            # 2-bar loop recorded from bar 2 played its bars swapped
            # before, 2026-10-13); else offsets into the window
            Sequence::Event.new(start: (loop ? p : p - from) % length, length: MB::M.max(len, 0r), value: note, velocity: velocity)
          }
          Sequence::Clip.new(seq_events, length: length, loop: loop, performed: true)
        end
      end
    end
  end
end
