module MB
  module Sound
    class Arrangement
      # Recording MIDI into tracks (see design/notes/arrangement.md,
      # Recording): #arm a track to hear live input through its patch,
      # #record an N-bar loop that swaps into the track when it closes (a
      # looper), or #capture what was just played (Live's Capture MIDI).
      # Events come from the Session's MIDI input (Session::MidiInput) on
      # exact frames and become clips with exact Rational starts (see
      # MIDI::Capture).
      #
      # Each recording is a few changes in the Session's change queue (so
      # it is journaled, undoable as one step, and replayed by takes): a
      # :rec change where the window opens (#record only), the track's
      # change to a silent placeholder clip where it closes (a swap, or a
      # launch if the track isn't playing; the patch is built when the
      # command runs, not on the render thread), and a :capture change
      # right after it that builds the clip from what the input saw and
      # swaps it in for the placeholder.
      module Recording
        # Recorded clips (a Hash from name to Sequence::Clip), oldest
        # first.
        def captures
          @mutex.synchronize { (@captures ||= {}).dup }
        end

        # The armed tracks: a Hash from name to the MIDI input's name (nil
        # for the default input).
        def armed
          @mutex.synchronize { (@armed ||= {}).dup }
        end

        # True if track +name+ is armed.
        def armed?(name)
          armed.key?(name)
        end

        # The name of the player that monitors armed track +name+.
        def self.monitor_name(name)
          :"#{name}/live"
        end

        # The track whose monitor player is +name+ (see .monitor_name), or
        # nil if +name+ isn't a monitor's name.
        def self.monitored_track(name)
          return nil unless name.is_a?(Symbol)
          s = name.name
          s.end_with?('/live') && s.length > 5 ? s[0...-5].to_sym : nil
        end

        # Arms tracks: #record and #capture without names record into
        # them, and (+monitor: true+, the default) each track's patch also
        # plays the live input (MidiInput#stream through a LiveClip) as the
        # player "name/live", so the performer hears the track's sound.
        # +input+ names the Session's MIDI input (nil: the default).
        # Returns the :arm journal entries (one, or an Array).
        def arm(*names, monitor: true, input: nil)
          names = names.flatten
          raise ArgumentError, 'Name the tracks to arm' if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }

          entries = nil
          @session.command("arm #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = trs.map { |tr|
              # Armed right away (Set state, like a track's clip), so `arm
              # :lead; rec 4` works while the :arm change waits (in a
              # replay, lines run ahead of their landing times)
              @mutex.synchronize { (@armed ||= {})[tr.name] = input }
              c = @session.change(:arm, tr.name, @session.now, data: { input: input }.compact) { |_t| }
              start_monitor(tr, input) if monitor && tr.patch?
              c
            }
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          entries.length == 1 ? entries.first : entries
        end

        # Disarms tracks (every armed track if none are named), stopping
        # their monitors.  Returns the :disarm journal entries.
        def disarm(*names)
          names = names.flatten
          names = armed.keys if names.empty?
          return [] if names.empty?

          entries = nil
          @session.command("disarm #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = names.map { |n|
              mon = Recording.monitor_name(n)
              @session.remove(mon, fade: @session.declick_bars) if @session.playing_after_queue?(mon)
              @mutex.synchronize { (@armed ||= {}).delete(n) }
              @session.change(:disarm, n, @session.now) { |_t| }
            }
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          entries.length == 1 ? entries.first : entries
        end

        # Records +length+ (bars, or a Duration such as 4.bars or 2.beats)
        # of MIDI from the track's launch point (+on:+, +in:+, +at:+; else
        # its +q:+ or the set's quant) into each of +names+ (the armed tracks
        # if none are given): a looping clip that swaps into the track the
        # moment it closes, playing in phase with the timeline.  See
        # MIDI::Capture for how notes become events.  +quantize:+ (a grid
        # for Clip#quantize, e.g. 16 or 1.n16, or [grid, {amount:}]) and
        # +humanize:+ (a time for Clip#humanize, or [time, {velocity:}])
        # clean up or loosen the clip; +channel:+ keeps one channel's notes;
        # +sustain: false+ ignores the sustain pedal.  Returns the :rec
        # journal entries (one, or an Array).
        def record(length, *names, at: nil, on: nil, in: nil, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true)
          point = LaunchPoint.of(binding) or return nil
          names = names.flatten
          names = armed.keys if names.empty?
          return MB::Sound.live_error(ArgumentError.new('Arm a track to record into (arm :lead), or name it: rec 4, :lead')) if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }
          len = recording_length(length) or return nil

          entries = nil
          @session.command("rec #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = trs.map { |tr|
              hub = @session.midi_in(input || armed[tr.name])
              start = resolve(tr.q || @quant, tr, point)
              rec = @session.change(:rec, tr.name, start, data: { length: len, ends: @session.stamp(start + len) }) { |_t| }
              capture_into(tr, hub, close: start + len, length: len, from: start, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain)
              rec
            }
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          entries.length == 1 ? entries.first : entries
        end

        # Captures what was just played on the MIDI input into each of
        # +names+ (the armed tracks if none are given), like Live's Capture
        # MIDI: at the track's launch point (its +q:+ by default, so the
        # next bar), the last +length+ (bars or a Duration; by default the
        # last phrase: back to the first note after a bar without notes,
        # rounded up to 1, 2, 4, 8, or 16 bars) becomes a looping clip on
        # the track, playing on in phase with the timeline.  Options as in
        # #record.  Returns the :capture journal entries.
        def capture(*names, length: nil, at: nil, on: nil, in: nil, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true)
          point = LaunchPoint.of(binding) or return nil
          names = names.flatten
          names = armed.keys if names.empty?
          return MB::Sound.live_error(ArgumentError.new('Arm a track to capture into (arm :lead), or name it: capture :lead')) if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }
          len = length && (recording_length(length) or return nil)

          entries = nil
          @session.command("capture #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = trs.map { |tr|
              hub = @session.midi_in(input || armed[tr.name])
              if Session.perform&.[](:source) != :replay && hub.note_positions.none? { |_, type| type == :note_on }
                MB::Sound.live_error(ArgumentError.new("Nothing played on #{hub} to capture")) or next
              end
              close = resolve(tr.q || @quant, tr, point)
              capture_into(tr, hub, close: close, length: len, from: len && close - len, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain)
            }.compact
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          entries.length == 1 ? entries.first : entries
        end

        # The length of the last phrase played before +pos+ on +hub+ (see
        # #capture), in whole notes, or nil if nothing was played.
        def phrase_length(hub, pos)
          ons = hub.note_positions.select { |p, type| type == :note_on && p < pos - MIDI::Capture::GRACE }.map(&:first).sort
          return nil if ons.empty?

          bar = @session.transport.bar_length(pos)
          start = ons.last
          ons.reverse.each_cons(2) do |later, earlier|
            break if later - earlier >= bar
            start = earlier
          end

          bars = ((pos - start) / bar).ceil
          bars = [1, 2, 4, 8, 16].find { |b| b >= bars } || 16
          bars * bar
        end

        private

        # The track to record into, or nil (after live_error).
        def recording_track(name)
          tr = tracks[name]
          if tr.nil?
            known = tracks.keys
            return MB::Sound.live_error(ArgumentError.new("No track #{name.inspect} to record into#{known.empty? ? '' : " (tracks: #{known.map(&:inspect).join(', ')})#{Form.suggest(name, known)}"}"))
          end
          return MB::Sound.live_error(ArgumentError.new("Track #{name.inspect} plays a graph; recording needs a track with a patch (track #{name.inspect} do |clip| ... end)")) unless tr.patch?
          tr
        end

        # +length+ (bars or a Duration) in whole notes, or nil (after
        # live_error).
        def recording_length(length)
          len = case length
                when Sequence::Duration then length.to_r
                when Numeric then length.real? && length.positive? ? Sequence::Duration.rational(length) * @session.transport.bar_length : nil
                end
          if len.nil? || len <= 0
            return MB::Sound.live_error(ArgumentError.new("Record lengths are bars or Durations like 4.bars or 2.beats (got #{length.inspect})"))
          end
          if len > Session::MidiInput::HISTORY - @session.transport.bar_length
            return MB::Sound.live_error(ArgumentError.new("Recordings can be at most #{(Session::MidiInput::HISTORY - @session.transport.bar_length) / @session.transport.bar_length} bars"))
          end
          len
        end

        # Queues the track's change to a placeholder clip at +close+ (whole
        # notes) and the :capture change that fills it with the clip of
        # what +hub+ saw from +from+ for +length+ (both nil for the last
        # phrase, found when it lands).  Returns the :capture Change.
        def capture_into(tr, hub, close:, length:, from:, quantize:, humanize:, channel:, sustain:)
          placeholder = Sequence::Clip.new([], length: length || @session.transport.bar_length, loop: true).named(:"#{tr.name}_rec")
          set_track(tr, placeholder, close, fade: nil)

          data = { length: length || :phrase, from: from && @session.stamp(from) }.compact
          @session.change(:capture, tr.name, early(tr, close), data: data) { |t|
            len = length || phrase_length(hub, close)
            raise ArgumentError, "Nothing played on #{hub} to capture" if len.nil?
            start = from || close - len

            g = MIDI::Capture::GRACE
            clip = MIDI::Capture.clip(hub.history(start - g, start + len - g), from: start, length: len, channel: channel, sustain: sustain)
            clip = feel(clip, :quantize, quantize) if quantize
            clip = feel(clip, :humanize, humanize) if humanize

            name = @mutex.synchronize {
              @captures ||= {}
              n = (1..).find { |i| !@captures.key?(:"#{tr.name}_#{i}") }
              @captures[:"#{tr.name}_#{n}"] = clip.named(:"#{tr.name}_#{n}")
              tr.clip = clip if tr.clip.equal?(placeholder)
              clip.name
            }
            @session.send(:swap_now, tr.name, { placeholder => clip }, t)
            @session.describe_player(tr.name, "#{tr.name}: #{name}")
            name
          }
        end

        # Applies Clip#quantize or #humanize with +value+: a grid or time,
        # or [value, {options}].
        def feel(clip, method, value)
          arg, options = value.is_a?(Array) ? value : [value, {}]
          clip.public_send(method, arg, **(options || {}))
        end

        # Starts the player that monitors armed track +tr+ (see #arm).
        def start_monitor(tr, input)
          live = Session::MidiInput::LiveClip.new(@session.midi_in(input))
          graph = begin
                    tr.patch.call(live)
                  rescue => e
                    warn "Track #{tr.name.inspect} can't monitor live MIDI (#{e.class}: #{e.message}); recording still works"
                    return nil
                  end
          @session.add(graph, name: Recording.monitor_name(tr.name), on: :now, fade: 0, description: "#{tr.name}: live MIDI")
        end
      end
    end
  end
end
