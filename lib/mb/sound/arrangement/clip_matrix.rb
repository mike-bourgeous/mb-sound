module MB
  module Sound
    class Arrangement
      # The clip matrix behind the terminal UI's clips pane (UI round 4;
      # contract in design/notes/terminal_ui.md): each track's slots (the
      # clips it can play, append-only, so a slot's index never changes in
      # a session and `launch :bass, 3` replays the same in takes), which
      # clip each journaled launch played, and the console's #launch and
      # #tweak.
      #
      # Slots fill in this order: the clips scenes give the track (in
      # scene order, as scenes are defined), then clips played on it
      # (`bg`, #launch), its captures, and tweaked versions, as they
      # appear.
      module ClipMatrix
        # Launches remembered (journal seq => clip), newest kept.
        LAUNCHES = 512

        # The transforms #tweak takes: keyword ones (with a value) and
        # bare ones (Symbols).
        TWEAK_VALUES = [:transpose, :legato, :swing, :quantize].freeze
        TWEAK_FLAGS = [:reverse, :halftime, :doubletime, :double, :half].freeze

        # The clips track +name+ can play (see ClipMatrix), oldest slot
        # first.  A frozen Array.
        def slots(name)
          @mutex.synchronize { ((@slots ||= {})[name] || []).dup.freeze }
        end

        # Every track's slots ({ name => [clip, ...] }).
        def all_slots
          @mutex.synchronize { (@slots ||= {}).transform_values { |l| l.dup.freeze } }
        end

        # The slot index of +clip+ on track +name+ (by identity), adding it
        # as a new slot if it isn't one yet (unless +add+ is false: nil).
        def slot_of(name, clip, add: true)
          return nil unless slot_clip?(clip)
          @mutex.synchronize { slot_index_unlocked(name, clip, add) }
        end

        # The clip the journal change +seq+ launched (a #play, #go, or
        # #launch of this Arrangement), or nil.
        def launch_clip(seq)
          @mutex.synchronize { (@launch_clips ||= {})[seq] }
        end

        # Plays a slot of track +name+: +ref+ is a slot index (see #slots)
        # or a clip's name (`.named(:bass_b)`, a capture like :bass_1, or a
        # tweaked clip's name), looked up among the track's slots, then the
        # captures, then every track's slots.  Launch points and +fade:+ as
        # #play (the `bg :bass, clip` path: journaled, one undo step).
        # Returns the journal entry.
        #
        #     launch :bass, :bass_b
        #     launch :bass, 3, on: :beat
        def launch(name, ref, at: nil, on: nil, in: nil, fade: nil)
          point = LaunchPoint.of(binding) or return nil
          tr = tracks[name]
          return MB::Sound.live_error(ArgumentError.new("No track #{name.inspect}#{track_hint}")) if tr.nil?
          return MB::Sound.live_error(ArgumentError.new("Track #{name.inspect} plays a graph, not clips")) unless tr.patch?

          clip = find_slot(name, ref) or return nil
          play(name, clip, at: point, fade: fade)
        end

        # Replaces track +name+'s clip (the one playing, or the one queued
        # last) with a transformed copy, at the track's launch point (or
        # +on:+, +in:+, +at:+) as one change and one undo step.  One
        # transform per call:
        #
        #     tweak :bass, transpose: 2      # semitones (an octave: 12)
        #     tweak :bass, legato: 0.8       # note lengths as a share of the gap
        #     tweak :bass, swing: 0.6
        #     tweak :bass, quantize: 1/16r   # (true: the default grid)
        #     tweak :bass, :reverse
        #     tweak :bass, :halftime         # twice as long
        #     tweak :bass, :doubletime       # half as long
        #     tweak :bass, :double           # played twice: twice the length
        #     tweak :bass, :half             # its first half
        #
        # The new clip is named after the old one and the transform
        # (`:"bass_a/t+2"`) and becomes a new slot.  Returns the journal
        # entry.
        def tweak(name, op = nil, at: nil, on: nil, in: nil, fade: nil, **opts)
          point = LaunchPoint.of(binding) or return nil
          tr = tracks[name]
          return MB::Sound.live_error(ArgumentError.new("No track #{name.inspect}#{track_hint}")) if tr.nil?
          clip = tr.clip
          return MB::Sound.live_error(ArgumentError.new("Track #{name.inspect} has no clip to tweak")) unless tr.patch? && slot_clip?(clip)

          ops = (op ? [[op, nil]] : []) + opts.to_a
          if ops.length != 1
            return MB::Sound.live_error(ArgumentError.new(
              "tweak takes one transform (#{TWEAK_VALUES.map { |k| "#{k}: x" }.join(', ')}, or #{TWEAK_FLAGS.map(&:inspect).join(', ')}; got #{ops.empty? ? 'none' : ops.map(&:first).map(&:inspect).join(', ')})"
            ))
          end
          kind, value = ops[0]
          new_clip = tweaked(name, clip, kind, value) or return nil
          slot_of(name, new_clip)
          play(name, new_clip, at: point, fade: fade)
        end

        private

        # Clips (and kits) that can be slots.
        def slot_clip?(v)
          v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit)
        end

        def slot_index_unlocked(name, clip, add)
          list = ((@slots ||= {})[name] ||= [])
          i = list.index { |c| c.equal?(clip) }
          return i if i || !add
          list << clip
          list.length - 1
        end

        # Remembers that journal change +change+ (a Session::Changes::Change,
        # or nil) launched +clip+ on track +name+, and makes +clip+ a slot.
        def note_launch(name, change, clip)
          @mutex.synchronize {
            slot_index_unlocked(name, clip, true) if slot_clip?(clip)
            next unless change&.seq
            l = (@launch_clips ||= {})
            l[change.seq] = clip
            l.shift while l.length > LAUNCHES
          }
        end

        # Adds the clips of scene values to their tracks' slots.
        def note_scene_slots(values)
          @mutex.synchronize { values.each { |k, v| slot_index_unlocked(k, v, true) if slot_clip?(v) } }
        end

        def track_hint
          names = tracks.keys
          names.empty? ? '' : " (tracks: #{names.map(&:inspect).join(', ')})"
        end

        # The clip +ref+ names for track +name+ (see #launch), or nil after
        # a live_error.
        def find_slot(name, ref)
          list = slots(name)
          case ref
          when Integer
            return list[ref] if ref >= 0 && ref < list.length
            MB::Sound.live_error(ArgumentError.new("Track #{name.inspect} has #{list.length} slot#{list.length == 1 ? '' : 's'} (0..#{list.length - 1}; got #{ref})"))
          when Symbol, String
            key = ref.to_sym
            found = list.find { |c| c.named? && c.name == key } ||
                    captures[key] ||
                    all_slots.each_value.lazy.flat_map(&:itself).find { |c| c.named? && c.name == key }
            return found if found
            known = (list.select(&:named?).map(&:name) + captures.keys).uniq
            hint = DidYouMean::SpellChecker.new(dictionary: known.map(&:to_s)).correct(key.to_s).first
            MB::Sound.live_error(ArgumentError.new("No clip #{key.inspect} for track #{name.inspect}#{hint ? " (did you mean :#{hint}?)" : known.empty? ? '' : " (clips: #{known.map(&:inspect).join(', ')})"}"))
          else
            return ref if slot_clip?(ref)
            MB::Sound.live_error(ArgumentError.new("launch takes a slot index or a clip name (got #{ref.inspect})"))
          end
        end

        # +clip+ with one #tweak transform, named, or nil after a
        # live_error.
        def tweaked(track, clip, kind, value)
          base = clip.named? ? clip.name.to_s : "#{track}##{slot_of(track, clip)}"
          suffix, result =
            case kind
            when :transpose
              check_tweak_number(kind, value, integer: true) or return nil
              ["t#{value >= 0 ? '+' : ''}#{value}", clip.transpose(value)]
            when :legato
              check_tweak_number(kind, value) or return nil
              ["legato#{value}", clip.legato(value)]
            when :swing
              check_tweak_number(kind, value) or return nil
              ["swing#{value}", clip.swing(value)]
            when :quantize
              grid = value == true ? nil : value
              check_tweak_number(kind, grid) or return nil if grid
              ["q#{grid ? Sequence::Duration.format(grid.to_r) : ''}", grid ? clip.quantize(grid) : clip.quantize]
            when :reverse then ['rev', clip.reverse]
            when :halftime then ['x2', clip.halftime]
            when :doubletime then ['/2', clip.doubletime]
            when :double then ['dbl', resized(clip, 2)]
            when :half then ['half', resized(clip, 1/2r)]
            else
              all = TWEAK_VALUES + TWEAK_FLAGS
              hint = DidYouMean::SpellChecker.new(dictionary: all.map(&:to_s)).correct(kind.to_s).first
              return MB::Sound.live_error(ArgumentError.new("tweak can't #{kind.inspect}#{hint ? " (did you mean #{hint}?)" : ''}; it takes #{TWEAK_VALUES.map { |k| "#{k}:" }.join(', ')}, #{TWEAK_FLAGS.map(&:inspect).join(', ')}"))
            end
          result.named(:"#{base}/#{suffix}")
        rescue NoMethodError => e
          raise unless e.receiver.equal?(clip)
          MB::Sound.live_error(ArgumentError.new("A #{clip.class.name.split('::').last.downcase} can't #{kind} (track #{track.inspect})"))
        end

        def check_tweak_number(kind, value, integer: false)
          ok = value.is_a?(Numeric) && value.real? && (!integer || value == value.round)
          ok || MB::Sound.live_error(ArgumentError.new("tweak #{kind}: takes a#{integer ? 'n integer' : ' number'} (got #{value.inspect})"))
        end

        # +clip+ played over +factor+ times its length (2: twice through;
        # 1/2: its first half), looping if it looped.
        def resized(clip, factor)
          if clip.is_a?(Sequence::Kit)
            return Sequence::Kit.new(clip.rows.transform_values { |c| resized(c, factor) })
          end
          len = clip.length * factor
          return clip.truncate(len) if clip.looping?
          factor > 1 ? clip.fill(len) : clip.truncate(len)
        end
      end
    end
  end
end
