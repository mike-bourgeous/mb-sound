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
          @mutex.synchronize { (@arms ||= {}).transform_values(&:input) }
        end

        # The armed tracks' states: a Hash from name to Arm (input,
        # whether a monitor was asked for, and :monitoring or :silent; see
        # Arm for the state machine).
        def arms
          @mutex.synchronize { (@arms ||= {}).dup }
        end

        # Applies +event+ (see Arm::TABLE) to track +name+'s arm state,
        # creating it from +input+ and +monitor+ when disarmed.  Returns the
        # new Arm, or nil once disarmed.
        def arm_event(name, event, input: nil, monitor: true, wire: nil)
          @mutex.synchronize {
            @arms ||= {}
            arm = @arms[name] || Arm.new(input: input, monitor: monitor, state: :disarmed, wire: wire)
            arm = arm.with(input: input, monitor: monitor, wire: wire) if %i[arm arm_silent].include?(event)
            nxt = arm.on(event)
            nxt ? @arms[name] = nxt : @arms.delete(name)
            nxt
          }
        end

        # Brings the arm states in line with the Session's players: an
        # armed track whose monitor stopped (`stop :"x/live"`, an undone
        # arm, a cancelled start) becomes :silent, and one whose monitor
        # plays again (undo, resume) :monitoring.  Session#command runs
        # this after every command, and undo, redo, and seeks after they
        # land, so the invariant in #arm_problems holds between commands.
        #
        # The arm state owns the monitors: a monitor brought back for a
        # track that isn't armed (undoing `stop :"x/live"` after `disarm`)
        # is stopped again with a declick.
        def sync_arms
          a = arms
          tracks.each_key do |name|
            next if a.key?(name)
            mon = Session::Name.monitor(name)
            @session.remove(mon, fade: @session.declick_bars) if @session.playing_after_queue?(mon)
          end

          a.each do |name, arm|
            playing = @session.playing_after_queue?(Session::Name.monitor(name))
            if arm.monitoring? && !playing
              arm_event(name, :monitor_lost)
            elsif !arm.monitoring? && playing
              arm_event(name, :monitor_found)
            end
          end
          nil
        end

        # Broken invariants between the arm states and the players, as
        # Strings (empty when all is well): a :monitoring track whose
        # monitor isn't playing or queued, a :silent one whose monitor is,
        # or a disarmed track's monitor still playing.  For specs (like
        # UI::Tiles#mode_problems).
        def arm_problems
          a = arms
          problems = a.filter_map { |name, arm|
            playing = @session.playing_after_queue?(Session::Name.monitor(name))
            next if arm.monitoring? == playing
            "#{name.inspect} is #{arm.state} but its monitor is #{playing ? '' : 'not '}playing"
          }
          tracks.each_key do |name|
            next if a.key?(name)
            problems << "#{name.inspect} is disarmed but its monitor plays" if @session.playing_after_queue?(Session::Name.monitor(name))
          end
          problems
        end

        # Disarms every armed track for #panic (see Arm: panic disarms, so
        # a broken armed track can't keep making noise, and the prompt and
        # listings agree with what plays).  Panic has already stopped the
        # monitors.  Returns the names disarmed.
        def panic_disarm
          names = arms.keys
          return [] if names.empty?
          time = @session.now
          before = undo_state
          a = arms
          names.each do |n|
            @session.wire_midi(a[n].input, nil, time, data: { track: n, by: :panic }) if a[n]&.wired?
            arm_event(n, :panic)
            @session.change(:disarm, n, time, data: { by: :panic }) { |_t| }
          end
          @session.note_undo_extra(self, before, undo_state)
          names
        end

        # True if track +name+ is armed.
        def armed?(name)
          armed.key?(name)
        end


        # Arms tracks: #record and #capture without names record into
        # them, and (+monitor: true+, the default) each track's patch also
        # plays the live input (MidiInput#stream through a LiveClip) as the
        # player "name/live", so the performer hears the track's sound.
        # +input+ names the Session's MIDI input (nil: the default), or is
        # a MIDI stream to play instead of live input (anything
        # MIDI::Stream.for takes: `midi.arp(:up)`, `riff.stream.echo(1.n8,
        # 3)`, a MIDI file's Notes): the track is then wired to it from now
        # (see Wires#wire, which lands at a launch point).  Returns the :arm
        # journal entries (one, or an Array).
        def arm(*names, monitor: true, input: nil)
          names = names.flatten
          raise ArgumentError, 'Name the tracks to arm' if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }
          wire = nil
          if Wire.stream?(input)
            wire = Wire.of(input, 'arm ..., input:') or return nil
          end

          entries = nil
          @session.command("arm #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            time = @session.now
            entries = trs.map { |tr| arm_now(tr, monitor: monitor, input: wire ? nil : input, wire: wire, time: time).first }
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
            # At Session#now, like the :disarm change: a scheduled block's
            # time, not when the scheduler runs it (up to Session#lookahead
            # earlier, which cut the end of the monitored phrase; the looper persona, 2026-10-13)
            time = @session.now
            entries = names.map { |n| disarm_now(n, time).first }
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
        # +sustain: false+ ignores the sustain pedal.  +cc:+ keeps the
        # controllers played (MIDI::Capture: false, the default, keeps
        # notes only; true or :steps keeps CCs, bend, and pressure as
        # controller lanes in the clip; :fit fits them; an Array keeps
        # some; :split keeps them as steps in a clip of their own, saved in
        # #captures as `<name>_cc` beside the notes clip the track plays;
        # see Clip#split_controls).  The loop follows the
        # timeline's phase (a 2-bar loop recorded from bar 2 plays the bar
        # recorded first on even bars; see MIDI::Capture), or with +align:
        # :launch+ starts from what was played first where it closes or is
        # launched (see Sequence::Clip#loop).  Returns the :rec journal
        # entries (one, or an Array).
        def record(length, *names, at: nil, on: nil, in: nil, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true, align: :timeline, cc: false)
          point = LaunchPoint.of(binding) or return nil
          names = names.flatten
          names = armed.keys if names.empty?
          return MB::Sound.live_error(ArgumentError.new('Arm a track to record into (arm :lead), or name it: rec 4, :lead')) if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }
          len = recording_length(length) or return nil
          recording_align(align) or return nil
          recording_cc(cc) or return nil

          entries = nil
          @session.command("rec #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = trs.map { |tr|
              hub = @session.midi_in(input || armed[tr.name])
              start = resolve(tr.q || @quant, tr, point)
              rec = @session.change(:rec, tr.name, start, data: { length: len, ends: @session.stamp(start + len) }) { |_t| }
              capture_into(tr, hub, close: start + len, length: len, from: start, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain, align: align, cc: cc)
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
        def capture(*names, length: nil, at: nil, on: nil, in: nil, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true, align: :timeline, cc: false)
          point = LaunchPoint.of(binding) or return nil
          names = names.flatten
          names = armed.keys if names.empty?
          return MB::Sound.live_error(ArgumentError.new('Arm a track to capture into (arm :lead), or name it: capture :lead')) if names.empty?
          trs = names.map { |n| recording_track(n) or return nil }
          len = length && (recording_length(length) or return nil)
          recording_align(align) or return nil
          recording_cc(cc) or return nil

          entries = nil
          failed = []
          @session.command("capture #{names.map(&:inspect).join(', ')}") {
            before = undo_state
            entries = trs.map { |tr|
              hub = @session.midi_in(input || armed[tr.name])
              if !Session.context&.replaying? && hub.note_positions.none? { |_, type| type == :note_on }
                MB::Sound.live_error(ArgumentError.new("Nothing played on #{hub} to capture")) or next
              end
              close = resolve(tr.q || @quant, tr, point)
              # One track's failure (a patch that doesn't build) leaves the
              # others captured (ux-1 round 2), and is reported below
              begin
                capture_into(tr, hub, close: close, length: len, from: len && close - len, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain, align: align, cc: cc)
              rescue StandardError, ScriptError => e
                failed << [tr.name, e]
                nil
              end
            }.compact
            @session.note_undo_extra(self, before, undo_state)
          }
          entries = entries.map { |c| @session.journal[c.seq] }
          unless failed.empty?
            text = failed.map { |name, e|
              where = Internal.error_origin(e)
              "capture into #{name.inspect} failed: #{e.class}: #{e.message.lines.first&.strip}#{where ? " (at #{where})" : ''}"
            }.join('; ')
            ok = entries.map(&:subject).uniq
            text += " (#{ok.map(&:inspect).join(', ')} captured)" unless ok.empty?
            MB::Sound.live_error(CaptureFailed.new(text, failed: failed, entries: entries))
          end
          entries.length == 1 ? entries.first : entries
        end

        # Raised (through live_error: a warning when live) when #capture
        # couldn't capture into some of its tracks; +failed+ is [track
        # name, error] pairs, +entries+ the captures that went through.
        class CaptureFailed < StandardError
          attr_reader :failed, :entries

          def initialize(message, failed:, entries:)
            super(message)
            @failed = failed
            @entries = entries
          end
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

        # The track to record into (or wire: +wire+ true), or nil (after
        # live_error).
        def recording_track(name, wire: false)
          tr = tracks[name]
          if tr.nil?
            known = tracks.keys
            return MB::Sound.live_error(ArgumentError.new("No track #{name.inspect} to #{wire ? 'wire' : 'record into'}#{known.empty? ? '' : " (tracks: #{known.map(&:inspect).join(', ')})#{Form.suggest(name, known)}"}"))
          end
          return MB::Sound.live_error(ArgumentError.new("Track #{name.inspect} plays a graph; #{wire ? 'a wire' : 'recording'} needs a track with a patch (track #{name.inspect} do |clip| ... end)")) unless tr.patch?
          tr
        end

        # Arms track +tr+ (inside a command; see #arm): on MIDI input
        # +input+, or on the stream of Wire +wire+ through the track's wire
        # input from timeline position +time+ (+arm_time+ is the :arm
        # change's: now).  Arming a wired track on live input unwires it at
        # +time+; wiring a track whose monitor plays its wire input already
        # keeps that monitor (only the stream changes).  Returns the :arm
        # Change and the :wire or :unwire Change (or nil).
        def arm_now(tr, monitor:, input:, wire:, time:, arm_time: @session.now)
          prior = arms[tr.name]
          input = Session::Name.wire(tr.name) if wire
          want = monitor && tr.patch?
          mon = Session::Name.monitor(tr.name)
          keep = wire && want && prior&.wired? && prior.monitoring? && @session.playing_after_queue?(mon)

          # Armed right away (Set state, like a track's clip), so `arm
          # :lead; rec 4` works while the :arm change waits (in a replay,
          # lines run ahead of their landing times)
          arm_event(tr.name, want ? :arm : :arm_silent, input: input, monitor: monitor, wire: wire)
          c = @session.change(:arm, tr.name, arm_time, data: { input: input, wire: wire&.text }.compact) { |_t| }
          wc =
            if wire
              @session.wire_midi(input, wire.stream, time, data: { track: tr.name, stream: wire.text })
            elsif prior&.wired?
              @session.wire_midi(prior.input, nil, time, data: { track: tr.name })
            end
          if want && !keep && !start_monitor(tr, input, wire: wire, time: wire ? time : nil)
            arm_event(tr.name, :arm_silent, input: input, monitor: monitor, wire: wire)
          end
          [c, wc]
        end

        # Disarms track +name+ at timeline position +time+ (inside a
        # command; see #disarm): its monitor stops, and a wired stream stops
        # playing into its wire input.  Returns the :disarm Change and the
        # :unwire Change (or nil).
        def disarm_now(name, time)
          arm = arms[name]
          mon = Session::Name.monitor(name)
          @session.remove(mon, fade: @session.declick_bars, time: time) if @session.playing_after_queue?(mon)
          wc = arm&.wired? ? @session.wire_midi(arm.input, nil, time, data: { track: name }) : nil
          arm_event(name, :disarm)
          [@session.change(:disarm, name, time) { |_t| }, wc]
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

        # True if +cc+ is a capture's controller option (see #record), else
        # nil (after live_error).
        def recording_cc(cc)
          return true if cc == :split || Sequence::ControlLane.selection?(cc)
          hint = cc.is_a?(Symbol) && DidYouMean::SpellChecker.new(dictionary: %w[steps fit split]).correct(cc.to_s).first
          MB::Sound.live_error(ArgumentError.new("cc: is false (notes only), true or :steps (controller lanes in the clip), :fit (fitted lanes), :split (lanes in a clip of their own), or an Array of CC numbers and :bend/:pressure/:poly_pressure (got #{cc.inspect}#{"; did you mean :#{hint}?" if hint})"))
        end

        # +align+ if it is a loop alignment, else nil (after live_error).
        def recording_align(align)
          return align if Sequence::Clip::ALIGNMENTS.include?(align)
          MB::Sound.live_error(ArgumentError.new("align: is :timeline (in phase with the timeline) or :launch (from what was played first; got #{align.inspect})"))
        end

        # Queues the track's change to a placeholder clip at +close+ (whole
        # notes) and the :capture change that fills it with the clip of
        # what +hub+ saw from +from+ for +length+ (both nil for the last
        # phrase, found when it lands).  Returns the :capture Change.
        def capture_into(tr, hub, close:, length:, from:, quantize:, humanize:, channel:, sustain:, align:, cc: false)
          # (performed, like the clip it stands for, so a drum kit built for it
          # plays any recorded note at live velocities; see TR808.kit)
          placeholder = Sequence::Clip.new([], length: length || @session.transport.bar_length, loop: true, performed: true).named(:"#{tr.name}_rec")
          set_track(tr, placeholder, close, fade: nil, slot: false)

          data = { length: length || :phrase, from: from && @session.stamp(from), cc: cc || nil }.compact
          @session.change(:capture, tr.name, early(tr, close), data: data) { |t|
            len = length || phrase_length(hub, close)
            raise ArgumentError, "Nothing played on #{hub} to capture" if len.nil?
            start = from || close - len

            g = MIDI::Capture::GRACE
            # (controllers chase their values from before the window, so
            # their history goes back as far as the input keeps it)
            back = cc ? Session::MidiInput::HISTORY : 0
            clip = MIDI::Capture.clip(hub.history(start - g - back, start + len - g), from: start, length: len, channel: channel, sustain: sustain, align: align,
                                      cc: cc == :split ? :steps : cc)
            clip, moves = clip.split_controls if cc == :split
            clip = feel(clip, :quantize, quantize) if quantize
            clip = feel(clip, :humanize, humanize) if humanize

            name = @mutex.synchronize {
              @captures ||= {}
              n = (1..).find { |i| !@captures.key?(:"#{tr.name}_#{i}") }
              @captures[:"#{tr.name}_#{n}"] = clip.named(:"#{tr.name}_#{n}")
              @captures[:"#{tr.name}_#{n}_cc"] = moves.named(:"#{tr.name}_#{n}_cc") if moves
              tr.clip = clip if tr.clip.equal?(placeholder)
              slot_index_unlocked(tr.name, clip, true) # (ClipMatrix)
              clip.name
            }
            # (the track may be gone: stopped before the loop closed, or a
            # render's song ended; the capture is kept for later)
            if @session.send(:swap_target?, tr.name)
              @session.send(:swap_now, tr.name, { placeholder => clip }, t)
              @session.describe_player(tr.name, "#{tr.name}: #{name}")
            end
            name
          }
        end

        # Applies Clip#quantize or #humanize with +value+: a grid or time,
        # or [value, {options}].
        def feel(clip, method, value)
          arg, options = value.is_a?(Array) ? value : [value, {}]
          clip.public_send(method, arg, **(options || {}))
        end

        # Rebuilds armed track +tr+'s monitor from its patch if the monitor
        # plays (called when #track redefines an armed track, so the
        # performer hears the patch that `capture` and `rec` will play;
        # ui-noise-1, 2026-10-17: the old monitor kept playing the first
        # patch, and a capture then played a very different one).
        def refresh_monitor(tr)
          return unless tr.patch?
          arm = arms[tr.name]
          return unless arm&.monitoring? && @session.playing_after_queue?(Session::Name.monitor(tr.name))
          # (a patch that fails to build leaves the old monitor playing)
          arm_event(tr.name, :redefine) if start_monitor(tr, arm.input, wire: arm.wire)
        end

        # Starts the player that monitors armed track +tr+ (see #arm), now
        # or at +time+ (a wire's launch point).
        def start_monitor(tr, input, wire: nil, time: nil)
          live = Session::MidiInput::LiveClip.new(@session.midi_in(input))
          graph = begin
                    GraphNode::Mixer.with_ring(@session.ring || GraphNode::Mixer.ring_mode) { tr.build(live) }
                  rescue => e
                    # (not a PatchError: a patch may play clips but not live
                    # MIDI, e.g. ghost_chords; the track still arms, silent)
                    where = patch_line(tr.patch, e)
                    notice_patch_problem("Track #{tr.name.inspect} can't monitor #{wire ? 'its wire' : 'live MIDI'} (#{e.class}: #{e.message}#{where ? " at #{where}" : ''}); recording still works")
                    return nil
                  end
          what = wire ? "wired: #{wire.text}" : "armed; #{input ? "MIDI input #{input.inspect}" : 'live MIDI'}"
          name = Session::Name.monitor(tr.name)
          description = "#{tr.name}: live monitor (#{what})"
          if time
            @session.add(graph, name: name, start_time: time, fade: 0, description: description)
          else
            @session.add(graph, name: name, on: :now, fade: 0, description: description)
          end
        end
      end
    end
  end
end
