require_relative 'keyboard/hold_tracker'
require_relative 'keyboard/step_entry'
require_relative 'keyboard/link'
require_relative 'keyboard/pane'
require_relative 'keyboard/scale_lock'

module MB
  module Sound
    module UI
      # The virtual keyboard (the `keyboard` pane's KEYS mode): two rows of
      # the computer keyboard play notes, laid out like jack-keyboard and
      # ZynAddSubFX's virtual keyboard (the lower row z s x d c v g b h n j
      # m , l . ; / from C, the upper row q 2 w 3 e r 5 t 6 y 7 u i 9 o 0
      # p [ = ] \ an octave higher; z is C3 and q is C4 at first, as in
      # ZynAddSubFX).  Notes go to +out+ (anything with #note_on,
      # #note_off, and #cc, e.g. a MIDI::VirtualInput read by the Session's
      # MIDI input, so they reach monitors, `rec`, `capture`, and takes
      # exactly like a hardware keyboard's).
      #
      # Terminals without key-release events (most, unless the kitty
      # keyboard protocol is on) send only presses and autorepeats, so the
      # note-off mode (#off_mode) decides when notes end:
      #
      # - :release: on the key's release (kitty protocol flag 2; chosen
      #   automatically when the terminal reports releases).
      # - :hold: while the key autorepeats (see HoldTracker): a tap sounds
      #   about the OS repeat delay (~0.5 s), a held key until 0.1 s after
      #   its repeats stop; keys pressed together hold together.
      # - :tap: every note is #tap seconds long.
      # - :legato: each note holds until the next key (one note at a time).
      #
      # #off_mode :auto (default) is :release where the terminal reports
      # releases, else :tap (maintainer, 2026-10-16: fixed-length notes
      # rather than notes guessed from autorepeats; :hold stays a choice).
      # Every way out of the mode (Ctrl-], Esc,
      # focus loss, hiding the screen, `ui off`, exit) calls #all_off, so
      # no note is left hanging.
      #
      # Keys (play mode): note keys (Shift: accent velocity 127; Ctrl: soft,
      # letter keys only in legacy terminals, where Ctrl-C, Ctrl-Z, and
      # Ctrl-M keep their meanings), - and + or Left and Right: octave, Up
      # and Down: velocity, Home and End: channel, Space: sustain pedal
      # (held where releases are reported, else a toggle), Esc: all notes
      # off, Enter: capture the last phrase into the armed tracks, `:
      # the note-off mode, Tab: step entry (see StepEntry).
      #
      # Thread safety: keys and ticks come from the UI's input thread; the
      # painter reads #view, a frozen snapshot rebuilt on change.
      class Keyboard
        # The lower row: semitones from the base C.
        LOWER = "zsxdcvgbhnjm,l.;/".chars.each_with_index.to_h.freeze

        # The upper row: semitones from the base C (an octave up); \ is
        # the A above ] (G), as on jack-keyboard (the key for G# would be
        # Backspace).
        UPPER = "q2w3er5t6y7ui9o0p[=]".chars.each_with_index.to_h { |c, i| [c, i + 12] }.merge('\\' => 33).freeze

        # Every note key and its semitone.
        KEYS = LOWER.merge(UPPER).freeze

        # Semitones the rows cover (C to the A of the third octave).
        SPAN = 34

        # Shifted characters of note keys on a US layout (legacy terminals
        # send these for Shift; the kitty protocol sends the base key).
        SHIFTED = {
          '<' => ',', '>' => '.', ':' => ';', '?' => '/', '@' => '2', '#' => '3', '%' => '5', '^' => '6',
          '&' => '7', '(' => '9', ')' => '0', '{' => '[', '}' => ']', '|' => '\\',
        }.freeze

        # Play mode's keys besides the note rows (the key table: the `?`
        # overlay and help :ui print it; #play_key acts on it).
        KEYMAP = Input::Keymap.new(:keys) do
          group 'Keyboard'
          doc 'z s x d c v ...', 'notes from C3 (lower row)'
          doc 'q 2 w 3 e r ...', 'notes from C4 (upper row)'
          on ['-', :left], :octave, -1, help: 'octave down, up'
          on ['+', :right], :octave, 1, help: 'octave down, up'
          on :up, :velocity_step, 8, help: 'velocity up, down'
          on :down, :velocity_step, -8, help: 'velocity up, down'
          doc 'Shift / Ctrl', 'accent / soft'
          on :home, :channel_step, -1, help: 'MIDI channel down, up'
          on :end, :channel_step, 1, help: 'MIDI channel down, up'
          on ' ', :sustain, help: 'sustain'
          on :escape, :panic, help: 'all notes off'
          on :enter, :capture, help: 'capture into the armed tracks'
          on '`', :cycle_off_mode, help: 'note-off mode'
          on :tab, :step_entry, help: 'step entry'
          # (scale lock: PgUp/PgDn cycle the scale and root; the methods come with scale lock)
          on :page_up, :cycle_scale, help: 'scale lock: next scale, next root', label: 'PgUp PgDn'
          on :page_down, :cycle_root, help: 'scale lock: next scale, next root', label: 'PgUp PgDn'
          doc 'Ctrl-]', 'NAV (notes off; Ctrl-] again: back to KEYS)'
          doc 'F2 Ctrl-C', 'back to the REPL'
        end

        # Note-off modes (see the class comment).
        OFF_MODES = %i[auto release hold tap legato].freeze

        # Velocities (raw 1..127): normal (Up/Down change it), accent
        # (Shift), soft (Ctrl).
        ACCENT = 127
        SOFT = 40

        # A recently played note: MIDI +note+, raw +velocity+.
        Played = Data.define(:note, :velocity)

        # What the pane draws (frozen; see #view).
        # (+velocities+: held notes' raw velocities by note)
        View = Data.define(:entry, :off_mode, :releases, :base, :velocity, :channel, :sustain, :held, :velocities, :played, :step, :message, :active, :scale)

        attr_reader :base, :velocity, :channel, :off_mode, :tap, :step

        # The output for notes (see the class comment); settable.
        attr_accessor :out

        # Called with no arguments for Enter in play mode (capture); with
        # the finished Clip at the end of step entry (Enter); with the
        # Clip so far for step entry's swap key (w, or Shift-Enter where
        # the terminal tells it from Enter).
        attr_accessor :on_capture, :on_finish, :on_swap

        # +clock+ gives monotonic seconds.
        def initialize(out: nil, base: 48, velocity: 96, channel: 0, off_mode: :auto, tap: 0.25, clock: nil, tempo: nil)
          @out = out
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @lock = Monitor.new
          @base = base
          @velocity = velocity
          @channel = channel
          @tap = tap
          @releases = false
          @sustain = false
          @active = false
          @held = {}
          @played = []
          @clips = []
          @message = nil
          @on_capture = nil
          @on_finish = nil
          @on_swap = nil
          @tracker = HoldTracker.new
          @step = StepEntry.new(self, tempo: tempo)
          @entry = :play
          @view = nil
          @scale_lock = nil
          self.off_mode = off_mode
        end

        # The scale lock (a ScaleLock), or nil.
        attr_reader :scale_lock

        # Locks the keys to +scale+ (a Scale, e.g. `scale(:dorian, :d)`, or
        # nil to unlock; ux-r3 item 44), in ScaleLock's :degrees mode (each
        # white key the next degree) unless the lock given is a ScaleLock.
        def scale=(scale)
          @lock.synchronize do
            @scale_lock = scale.nil? || scale.is_a?(ScaleLock) ? scale : ScaleLock.new(scale)
            changed!
          end
          say(@scale_lock ? "scale: #{@scale_lock.label}" : 'scale: off')
        end

        # The locked scale (a Scale), or nil.
        def scale = @scale_lock&.scale

        # Sets the scale lock's mode (a lock style, :play, :mash, :along, or
        # :chord; :degrees and :snap name :play and :along; see ScaleLock).
        def scale_mode=(mode)
          raise ArgumentError, 'Lock a scale first (ui.keyboard.scale = scale(:dorian, :d))' unless @scale_lock
          self.scale = ScaleLock.new(@scale_lock.scale, mode: mode)
        end

        # Steps the scale lock to the next scale in ScaleLock::CYCLE (off
        # after the last).
        def cycle_scale
          self.scale = ScaleLock.next_scale(@scale_lock)
        end

        # Moves the scale lock's root a fifth up.
        def cycle_root
          return say('scale: off (cycle a scale first)') unless @scale_lock
          self.scale = ScaleLock.next_root(@scale_lock)
        end

        # The MIDI note of the key +semis+ semitones above the base (through
        # the scale lock, if any).
        def note_for(semis)
          l = @scale_lock
          l ? l.note(@base, semis) : @base + semis
        end

        # True while KEYS mode has the keyboard (set by the screen).
        def active? = @active

        def active=(on)
          @lock.synchronize do
            @active = !!on
            changed!
          end
        end

        # :play (notes as played) or :step (StepEntry).
        def entry = @entry

        def entry=(e)
          raise ArgumentError, "Keyboard entry is :play or :step (got #{e.inspect})" unless %i[play step].include?(e)
          @lock.synchronize do
            all_off_unlocked(@clock.call)
            @entry = e
            changed!
          end
        end

        # True once the terminal reported a key release (or was told it
        # will: see #releases=).
        def releases? = @releases

        # Whether the terminal reports key releases (the kitty protocol's
        # event types).
        def releases=(on)
          @lock.synchronize do
            @releases = !!on
            changed!
          end
        end

        # :auto, :release, :hold, :tap, or :legato (see the class comment).
        def off_mode=(m)
          raise ArgumentError, "Note-off modes are #{OFF_MODES.map(&:inspect).join(', ')} (got #{m.inspect})" unless OFF_MODES.include?(m)
          @lock.synchronize do
            all_off_unlocked(@clock.call) if @held.any?
            @off_mode = m
            changed!
          end
        end

        # The note-off mode in effect (:auto resolved).
        def resolved_mode
          @off_mode == :auto ? (@releases ? :release : :tap) : @off_mode
        end

        # The OS key-repeat delay the keyboard tells autorepeats from new
        # strikes by (learned from the repeats it sees; set it to skip the
        # one retrigger before it is learned, e.g. `ui.keyboard.repeat_delay
        # = 0.25` for a short delay).
        def repeat_delay = @tracker.delay

        def repeat_delay=(seconds)
          raise ArgumentError, "Repeat delays are 0.15..1.2 seconds (got #{seconds.inspect})" unless seconds.is_a?(Numeric) && seconds.between?(0.15, 1.2)
          @lock.synchronize { @tracker.delay = seconds }
        end

        # Seconds each note sounds in :tap mode.
        def tap=(seconds)
          raise ArgumentError, "Tap lengths are positive seconds (got #{seconds.inspect})" unless seconds.is_a?(Numeric) && seconds > 0
          @tap = seconds.to_f
        end

        # The lowest note (the z key; C3 = 48 at first): a C (other notes
        # round down to their octave's C), C-1 (0) to C6 (84).
        def base=(n)
          @lock.synchronize do
            all_off_unlocked(@clock.call)
            @base = n.to_i.clamp(0, 127 - SPAN + 1) / 12 * 12
            changed!
          end
        end

        # The normal velocity (raw 1..127).
        def velocity=(v)
          @lock.synchronize do
            @velocity = v.to_i.clamp(1, 127)
            changed!
          end
        end

        # The MIDI channel (0-based; shown 1-based).
        def channel=(c)
          @lock.synchronize do
            all_off_unlocked(@clock.call)
            @channel = c.to_i.clamp(0, 15)
            changed!
          end
        end

        # Handles one key event (UI::Input::Key) at monotonic time +now+.
        # Returns true if it was a keyboard key.
        def key(k, now = @clock.call)
          @lock.synchronize do
            r = @entry == :step ? @step.key(k, now) : nil
            r = play_key(k, now) if r.nil?
            changed! if r
            r
          end
        end

        # Ends notes whose time is up (:hold, :tap) and plays due preview
        # notes.  Returns true if anything changed.
        def tick(now = @clock.call)
          @lock.synchronize do
            changed = false
            @held.to_a.each do |ch, h|
              next unless h[:off_at] && now >= h[:off_at]
              note_off(ch, h[:off_at])
              changed = true
            end
            changed = true if @step.tick(now)
            changed!(now) if changed
            changed
          end
        end

        # Seconds until #tick has something to do, or nil.
        def wait(now = @clock.call)
          @lock.synchronize do
            times = @held.each_value.filter_map { |h| h[:off_at] }
            s = @step.next_due
            times << s if s
            times.empty? ? nil : MB::M.max(times.min - now, 0.0)
          end
        end

        # Ends every note (and the sustain pedal and any preview).  Safe to
        # call any time, from any thread.
        def all_off(now = @clock.call)
          @lock.synchronize do
            all_off_unlocked(now)
            changed!
          end
          self
        end

        # The notes sounding (MIDI note numbers).
        def held
          @lock.synchronize { @held.values.map { |h| h[:note] }.sort }
        end

        # What the pane draws (frozen; rebuilt after changes).
        def view
          @lock.synchronize do
            @view ||= View.new(
              entry: @entry, off_mode: resolved_mode, releases: @releases, base: @base, velocity: @velocity, channel: @channel,
              sustain: @sustain, held: @held.values.map { |h| h[:note] }.sort.freeze,
              velocities: @held.values.to_h { |h| [h[:note], h[:vel] || @velocity] }.freeze, played: @played.dup.freeze,
              step: @entry == :step ? @step.view : nil, message: @message, active: @active, scale: @scale_lock&.label
            )
          end
        end

        # A short line for the screen's status (flash) messages.
        attr_reader :message

        # The clips finished in step entry (oldest first).
        def clips = @lock.synchronize { @clips.dup }

        # The last clip finished in step entry, or nil.
        def clip = @lock.synchronize { @clips.last }

        # Called by StepEntry when a clip is done.
        def finished(clip)
          @clips << clip
          @on_finish&.call(clip)
        end

        # Called by StepEntry to swap +clip+ into the armed tracks (see
        # #on_swap).
        def swap_in(clip)
          @clips << clip unless @clips.last.equal?(clip)
          return say('swap: nothing to swap into here') unless @on_swap
          @on_swap.call(clip)
        end

        # Sets the message shown in the pane.
        def say(text)
          @message = text
          changed!
        end

        # How #off_mode works now, in a few words (for the pane and help).
        def off_mode_text
          case resolved_mode
          when :release then 'key-up ends notes'
          when :hold then "no key-up here: notes hold while keys repeat (taps ~#{format('%.1f', @tracker.delay + HoldTracker::FIRST_SLACK)} s)"
          when :tap then "no key-up here: every note #{format('%.2f', @tap)} s (` for :hold)"
          when :legato then 'each note holds until the next'
          end
        end

        def inspect
          "#<UI::Keyboard #{@entry} #{resolved_mode} z=#{note_name(@base)} vel #{@velocity} ch #{@channel + 1}#{@held.empty? ? '' : " held #{held.map { |n| note_name(n) }.join(' ')}"}>"
        end

        # A note's name ("C3", "F#4").
        def note_name(n)
          Note.new(n).name.sub('s', '#')
        end

        # Plays a note now (step entry's audition and previews; +length+
        # seconds, or until #all_off).
        def audition(note, velocity, now, length)
          key = :"audition#{note}"
          note_off(key, now) if @held.key?(key)
          note_on(key, note, velocity, now)
          @held[key][:off_at] = now + length
        end

        # Sends a note-off for +key+'s note (used by StepEntry).
        def release(key, now)
          note_off(key, now) if @held.key?(key)
        end

        # Sends a controller change (used by panic).
        def send_cc(index, value, now)
          @out&.cc(index, value, channel: @channel, time: now)
        end

        private

        def changed!(_now = nil)
          @view = nil
        end

        # Play-mode keys.  Returns true if handled, false if not a keyboard
        # key.
        def play_key(k, now)
          semis, vel = note_of(k)
          return note_key(k, semis, vel, now) if semis

          return false if k.release? && k.key != ' '
          a = KEYMAP[Input::Key.of(k.key)] or return false # (modifiers as without: Shift-Up is Up)
          case a.name
          when :octave then octave(a.args[0])
          when :velocity_step then self.velocity = @velocity + a.args[0]
          when :channel_step then self.channel = @channel + a.args[0]
          when :sustain then sustain_key(k, now)
          when :panic then all_off_unlocked(now, panic: true)
          when :capture then @on_capture&.call
          when :cycle_off_mode
            i = OFF_MODES.index(@off_mode)
            self.off_mode = OFF_MODES[(i + 1) % OFF_MODES.length]
            say("note-off: #{@off_mode}#{@off_mode == :auto ? " (#{resolved_mode})" : ''}")
          when :step_entry then self.entry = :step
          when :cycle_scale then cycle_scale # (scale lock: the next scale; ux-r3 item 44)
          when :cycle_root then cycle_root   # (its root a fifth up)
          end
          true
        end

        # [semitones from the base, raw velocity] for a note key, or nil.
        def note_of(k)
          ch = k.key
          return nil unless ch.is_a?(String) && (k.mods - %i[shift ctrl]).empty?
          accent = k.mods.include?(:shift)
          if (base = SHIFTED[ch])
            ch = base
            accent = true
          elsif ch.match?(/\A[A-Z]\z/)
            ch = ch.downcase
            accent = true
          end
          semis = KEYS[ch] or return nil
          [semis, accent ? ACCENT : k.mods.include?(:ctrl) ? SOFT : @velocity]
        end

        def note_key(k, semis, vel, now)
          ch = KEYS.key(semis)
          note = note_for(semis)
          return true if note.nil? || note > 127 # (a silent key of the scale lock, or off the top)

          mode = resolved_mode
          if mode == :release
            if k.release?
              note_off(ch, now)
            elsif k.press?
              note_off(ch, now) # a press without a release: strike again
              note_on(ch, note, vel, now)
            end
            return true
          end
          return true if k.release?

          # Legacy terminals: presses and autorepeats look alike
          kind = k.repeat? ? @tracker.press(ch, now, repeat: true) : @tracker.press(ch, now)
          case mode
          when :hold
            case kind
            when :new then note_on(ch, note, vel, now) unless @held.key?(ch)
            when :strike
              note_off(ch, now)
              note_on(ch, note, vel, now)
            end
            @tracker.deadlines(@held.keys).each { |c, t| @held[c][:off_at] = t }
          when :tap
            return true if kind == :repeat
            note_off(ch, now)
            note_on(ch, note, vel, now)
            @held[ch][:off_at] = now + @tap
          when :legato
            return true if kind == :repeat
            # The new note first, so mono voices glide and envelopes hold
            others = @held.keys.reject { |c| c.is_a?(Symbol) || c == ch }
            note_off(ch, now)
            note_on(ch, note, vel, now)
            others.each { |c| note_off(c, now) }
          end
          true
        end

        def octave(dir)
          self.base = @base + 12 * dir
          say("z is #{note_name(@base)}")
        end

        def sustain_key(k, now)
          on =
            if resolved_mode == :release && !k.press?
              k.release? ? false : @sustain
            elsif resolved_mode == :release
              true
            else
              !@sustain
            end
          return if on == @sustain
          @sustain = on
          @out&.cc(64, on ? 1.0 : 0.0, channel: @channel, time: now)
        end

        def note_on(key, note, vel, now)
          @out&.note_on(note, vel / 127.0, channel: @channel, time: now)
          @held[key] = { note: note, at: now, off_at: nil, vel: vel }
          @played << Played.new(note: note, velocity: vel) unless key.is_a?(Symbol)
          @played.shift while @played.length > 24
        end

        def note_off(key, now)
          h = @held.delete(key) or return
          @out&.note_off(h[:note], channel: @channel, time: now)
        end

        def all_off_unlocked(now, panic: false)
          @held.keys.each { |k| note_off(k, now) }
          @step.stop_preview
          if @sustain || panic
            @sustain = false
            @out&.cc(64, 0.0, channel: @channel, time: now)
          end
          @out&.cc(123, 0.0, channel: @channel, time: now) if panic
          @tracker.clear
        end
      end
    end
  end
end
