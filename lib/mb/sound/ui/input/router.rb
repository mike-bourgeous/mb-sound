require_relative 'events'

module MB
  module Sound
    module UI
      module Input
        # Routes input events by state, so one stream of Actions comes from
        # keys, the palette, and MIDI alike.  The Router is an explicit
        # state machine: its states (STATES), the classes of event it tells
        # apart (EVENTS), and what each (state, event) pair does (TABLE,
        # every pair declared; #table prints it) are data, so the `?`
        # overlay and help can show them and specs can walk every pair.
        #
        # States:
        # - :repl: keys go to the REPL (the host's #repl_key), except the
        #   NAV key (Ctrl-], always), the one-shot NAV key (Ctrl-W), the
        #   REPL keymap (#repl_keys: direct bindings like Alt-PgUp,
        #   `ui.bind`), and with #nav_esc a lone held Escape (a prefix).
        # - :play (instead of :repl on a screen without a console, a
        #   script's --ui screen): keys go to the host's #play_key.
        # - :nav: keys go through the focused pane's keymap (#pane_keymap),
        #   then NAV, then the extra keymaps; Ctrl-] goes back to where NAV
        #   was entered from (:repl, :grab, :line, :play).
        # - :once (Ctrl-W from :repl, :play, :nav, :grab, or :pane; the
        #   maintainer's one-shot NAV, 2026-10-18): the next key acts as in
        #   NAV (the same keymaps: no separate window keys), then the Router
        #   goes back to #once_return, or, when the action moved the focus,
        #   into the pane it landed on as Enter would (the host's
        #   #once_target).  Ctrl-W again (Ctrl-W Ctrl-W) is the pane focused
        #   before, gone into (twice: back); Ctrl-] stays in NAV; Esc goes
        #   back; an unbound key opens the ? overlay over :once (a key
        #   there closes it and acts once; Esc goes back).  An action that
        #   changes the mode itself (Enter, a jump, Esc's NAV binding is
        #   not reached, :, /) keeps the mode it chose.
        # - :line (the palette and search prompts): keys edit a one-line
        #   input (LineInput); Enter submits, Esc cancels.
        # - :grab (a pane that takes the keyboard, like the virtual piano):
        #   every key event, releases and repeats included, goes to the
        #   host's #grab_key, except Ctrl-], F2, Ctrl-C, Ctrl-Z.
        # - :pane (a focused pane's own mode, entered with Enter in NAV on a
        #   pane whose kind declares mode keys, like the clip matrix's
        #   cursor): keys go to the host's #pane_mode_key (the pane's mode
        #   keys, then its NAV keys; unbound keys are refused, never NAV's);
        #   Esc and Ctrl-] go to NAV, ? shows the keys.
        # - :overlay (the `?` key help over NAV): Esc, ?, and Ctrl-] close
        #   it; any other key closes it and acts as in the state below.
        # - :pending: a prefix key waits for the next key (Prefix: a held
        #   Escape for NAV); #origin is the state it came from, which #mode
        #   reports.
        #
        # Outside :grab, key releases are ignored and repeats act as presses
        # (terminals report them only while a grab asks for them, but a
        # release can arrive just after the grab ends).
        #
        # The host receives #act(Action) for everything else, among them
        # :interrupt (Ctrl-C), :hide (Ctrl-Z), :keys (F2), :refused (a key a state can't take, with
        # why: shown, never silently dropped), :unbound (a NAV key that
        # isn't one), and :event (mouse, focus, replies).
        class Router
          # The NAV key: Ctrl-] (0x1D), distinct in every terminal (ssh,
          # tmux) and unused by Reline.
          NAV_KEY = Key.of(']', :ctrl)

          # Keys every state treats alike (see TABLE).
          KEYS_KEY = Key.of(:f2)
          INTERRUPT_KEY = Key.of('c', :ctrl)
          SUSPEND_KEY = Key.of('z', :ctrl)

          NAV = Keymap.new :nav do
            group 'Panes'
            on '1'..'9', :focus_index, help: 'pick a pane by its number'
            on :tab, :focus_next, help: 'next, previous, by direction (arrows)'
            on [:tab, :shift], :focus_prev, help: 'next, previous, by direction (arrows)'
            %i[left right up down].each do |dir|
              on dir, :focus_dir, dir, help: 'next, previous, by direction (arrows)', label: 'arrows'
            end
            on 'p', :focus_last, help: 'the pane focused before'
            on 'z', :zoom, help: 'zoom (again: back)'
            on 's', :split, :rows, help: 'split below, beside'
            on 'v', :split, :cols, help: 'split below, beside'
            on 'x', :close, help: 'close (the REPL stays)'
            on '=', :equalize, help: 'even out sizes'
            %i[left right up down].each do |dir|
              on [dir, :shift], :resize, dir, 1, help: 'resize by 1 (Ctrl-Shift: 5)', label: 'S-arrows'
              on [dir, :shift, :ctrl], :resize, dir, 5, help: 'resize by 1 (Ctrl-Shift: 5)', label: 'S-arrows'
            end
            on '[', :tab, -1, help: 'previous, next tab'
            on ']', :tab, 1, help: 'previous, next tab'
            on 'u', :undo, help: 'undo, redo'
            on ['r', :ctrl], :redo, help: 'undo, redo'
            group 'Console'
            on :page_up, :scroll, :page_up, help: 'scroll the REPL (also Ctrl-B Ctrl-F)'
            on :page_down, :scroll, :page_down, help: 'scroll the REPL (also Ctrl-B Ctrl-F)'
            on ['b', :ctrl], :scroll, :page_up, help: 'scroll the REPL (also Ctrl-B Ctrl-F)', label: ''
            on ['f', :ctrl], :scroll, :page_down, help: 'scroll the REPL (also Ctrl-B Ctrl-F)', label: ''
            on 'g', :scroll, :top, help: 'oldest line, live'
            on 'G', :scroll, :bottom, help: 'oldest line, live'
            on '/', :search, help: 'search back, next, previous'
            on 'n', :search_next, 1, help: 'search back, next, previous'
            on 'N', :search_next, -1, help: 'search back, next, previous'
            on 'y', :copy, help: 'copy the match or the view (OSC 52)'
            on ':', :palette, help: 'run a line of Ruby (show :knobs, go :drop)'
            on ['l', :ctrl], :redraw, help: 'redraw'
            group 'Modes'
            on :enter, :enter, help: "into the pane: REPL, KEYS, or its own keys"
            on :escape, :mode, :repl, help: 'back to the REPL'
          end

          # The one-shot NAV key (maintainer, 2026-10-18): Ctrl-W then any
          # NAV key does that one action and comes back (the :once state).
          ONCE_KEY = Key.of('w', :ctrl)

          # Keys that act in every state but :grab (none by default; e.g.
          # `Router::GLOBAL.on ['\\', :ctrl], :panic`).
          GLOBAL = Keymap.new :global

          # A key that waits for the next one: +key+ starts it, +keymap+
          # maps the next key (nil: none), +timeout+ seconds (nil: waits
          # forever) after which +on_timeout+ (an Action) happens, and
          # +pass_through+: a key the keymap doesn't bind goes to the REPL
          # after the prefix key (a held Escape then x: Esc, x).
          Prefix = Data.define(:name, :key, :keymap, :timeout, :on_timeout, :pass_through)

          # The states (see the class comment).
          STATES = %i[repl play nav once line grab pane overlay pending].freeze

          # What the Router tells apart in an event (#classify).
          EVENTS = %i[nav_key keys_key interrupt suspend once_key prefix global key release paste tick other].freeze

          # What each (state, event) pair does: [handler, what it does].
          # Every pair is declared (a spec checks), so no key falls through
          # unhandled; :ignore and :refuse say why.
          TABLE = {
            # repl
            [:repl, :nav_key] => [:enter_nav, 'to NAV (Ctrl-] again comes back)'],
            [:repl, :keys_key] => [:act_keys, 'to KEYS (the keyboard pane)'],
            [:repl, :interrupt] => [:act_interrupt, 'interrupt the REPL (SIGINT)'],
            [:repl, :suspend] => [:act_hide, 'hide the tiles (Ctrl-Z or `ui` brings them back)'],
            [:repl, :once_key] => [:start_once, 'one NAV key, then back (Ctrl-W z, Ctrl-W arrows, Ctrl-W Ctrl-W)'],
            [:repl, :prefix] => [:start_prefix, 'wait for the next key (held Esc: NAV)'],
            [:repl, :global] => [:act_global, 'the global binding'],
            [:repl, :key] => [:repl_key, 'a REPL keymap binding (Alt-PgUp, ui.bind), else to the REPL'],
            [:repl, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:repl, :paste] => [:repl_paste, 'to the REPL whole'],
            [:repl, :tick] => [:ignore, 'nothing waits'],
            [:repl, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # play (a screen without a console)
            [:play, :nav_key] => [:enter_nav, 'to NAV (Ctrl-] again comes back)'],
            [:play, :keys_key] => [:act_keys, 'to KEYS'],
            [:play, :interrupt] => [:act_interrupt, 'interrupt (the script decides)'],
            [:play, :suspend] => [:act_hide, 'hide (only with a console; else refused)'],
            [:play, :once_key] => [:start_once, 'one NAV key, then back'],
            [:play, :prefix] => [:start_prefix, 'wait for the next key'],
            [:play, :global] => [:act_global, 'the global binding'],
            [:play, :key] => [:play_key, "the screen's own keys (repeats too)"],
            [:play, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:play, :paste] => [:refuse, 'refused: nowhere to paste without a console'],
            [:play, :tick] => [:ignore, 'nothing waits'],
            [:play, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # nav
            [:nav, :nav_key] => [:leave_nav, 'back to where NAV came from'],
            [:nav, :keys_key] => [:act_keys, 'to KEYS'],
            [:nav, :interrupt] => [:act_interrupt, 'interrupt the REPL'],
            [:nav, :suspend] => [:act_hide, 'hide the tiles'],
            [:nav, :once_key] => [:start_once, 'one NAV key, then back in NAV (Ctrl-W Ctrl-W: the last pane, gone into)'],
            [:nav, :prefix] => [:ignore, 'no prefixes in NAV (cannot happen)'],
            [:nav, :global] => [:act_global, 'the global binding'],
            [:nav, :key] => [:nav_key, "the focused pane's keys, then NAV's (unbound: says so)"],
            [:nav, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:nav, :paste] => [:repl_paste, 'to the REPL whole'],
            [:nav, :tick] => [:ignore, 'nothing waits'],
            [:nav, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # once (Ctrl-W: one NAV key, then back where it came from)
            [:once, :nav_key] => [:once_to_nav, 'stay in NAV (Ctrl-W Ctrl-]; Ctrl-] again: back where Ctrl-W came from)'],
            [:once, :keys_key] => [:once_then, 'back, then F2 as before Ctrl-W'],
            [:once, :interrupt] => [:once_then, 'back, then Ctrl-C as before Ctrl-W'],
            [:once, :suspend] => [:once_then, 'back, then hide'],
            [:once, :once_key] => [:once_last, 'the pane focused before, gone into as Enter would (Ctrl-W Ctrl-W twice: back)'],
            [:once, :prefix] => [:ignore, 'no prefixes here (cannot happen)'],
            [:once, :global] => [:once_then, 'back, then the global binding'],
            [:once, :key] => [:once_key, "a NAV key (the focused pane's first), then back; a moved focus goes into its pane; Esc: back; unbound: the ? overlay"],
            [:once, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:once, :paste] => [:once_then, 'back, then the paste as before Ctrl-W'],
            [:once, :tick] => [:ignore, 'nothing waits'],
            [:once, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # line (palette, search)
            [:line, :nav_key] => [:enter_nav, 'to NAV, the line kept (Ctrl-] again restores it)'],
            [:line, :keys_key] => [:line_then_keys, 'cancel the line, to KEYS'],
            [:line, :interrupt] => [:line_cancel, 'cancel the line'],
            [:line, :suspend] => [:act_hide, 'hide the tiles (the line kept)'],
            [:line, :once_key] => [:line_key, 'edit the line (Ctrl-W deletes a word)'],
            [:line, :prefix] => [:refuse, 'no prefixes in a line'],
            [:line, :global] => [:act_global, 'the global binding'],
            [:line, :key] => [:line_key, 'edit the line (Enter runs, Esc cancels)'],
            [:line, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:line, :paste] => [:line_paste, 'into the line (newlines dropped)'],
            [:line, :tick] => [:ignore, 'nothing waits'],
            [:line, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # grab (KEYS)
            [:grab, :nav_key] => [:enter_nav, 'to NAV, notes off (Ctrl-] again: back to KEYS)'],
            [:grab, :keys_key] => [:to_base, 'back to the REPL, notes off'],
            [:grab, :interrupt] => [:to_base, 'all notes off, back to the REPL'],
            [:grab, :suspend] => [:act_hide, 'hide the tiles, notes off'],
            [:grab, :once_key] => [:start_once, 'notes off, one NAV key, then back (to KEYS unless the focus moved)'],
            [:grab, :prefix] => [:refuse, 'no prefixes in a grab (the grab takes every key)'],
            [:grab, :global] => [:grab_key, 'to the grab (it takes every key)'],
            [:grab, :key] => [:grab_key, 'to the grab (presses and repeats)'],
            [:grab, :release] => [:grab_key, 'to the grab (releases end notes)'],
            [:grab, :paste] => [:refuse, 'refused: the keyboard plays keys, not text'],
            [:grab, :tick] => [:ignore, 'nothing waits (the grab keeps its own time)'],
            [:grab, :other] => [:act_event, 'mouse, focus (focus out: notes off), replies'],
            # pane (a focused pane's own keys, entered with NAV Enter)
            [:pane, :nav_key] => [:enter_nav, 'to NAV (Ctrl-] again: back into the pane)'],
            [:pane, :keys_key] => [:act_keys, 'to KEYS'],
            [:pane, :interrupt] => [:act_interrupt, 'interrupt the REPL'],
            [:pane, :suspend] => [:act_hide, 'hide the tiles'],
            [:pane, :once_key] => [:start_once, 'one NAV key, then back into the pane (unless the focus moved)'],
            [:pane, :prefix] => [:ignore, 'no prefixes in a pane (cannot happen)'],
            [:pane, :global] => [:act_global, 'the global binding'],
            [:pane, :key] => [:pane_key, "the pane's keys (Esc: NAV; ? lists them; others refused)"],
            [:pane, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:pane, :paste] => [:refuse, 'refused: a pane takes keys, not text (Esc, then i: the REPL)'],
            [:pane, :tick] => [:ignore, 'nothing waits'],
            [:pane, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # overlay (the ? key help)
            [:overlay, :nav_key] => [:overlay_to_nav, 'close it, in NAV'],
            [:overlay, :keys_key] => [:overlay_then, 'close it, then F2 as below it'],
            [:overlay, :interrupt] => [:overlay_then, 'close it, then Ctrl-C as below it'],
            [:overlay, :suspend] => [:overlay_then, 'close it, then hide'],
            [:overlay, :once_key] => [:overlay_then, 'close it, then Ctrl-W as below it'],
            [:overlay, :prefix] => [:overlay_then, 'close it, then the prefix as below it'],
            [:overlay, :global] => [:overlay_then, 'close it, then the global binding'],
            [:overlay, :key] => [:overlay_key, 'Esc or ? close it; other keys close it and act as below it'],
            [:overlay, :release] => [:ignore, 'ignored (only a grab reads releases)'],
            [:overlay, :paste] => [:overlay_then, 'close it, then paste as below it'],
            [:overlay, :tick] => [:ignore, 'nothing waits'],
            [:overlay, :other] => [:act_event, 'mouse, focus, replies to the host'],
            # pending (a prefix waits)
            [:pending, :nav_key] => [:prefix_then, 'drop the prefix, then Ctrl-] as before it'],
            [:pending, :keys_key] => [:prefix_then, 'drop the prefix, then F2 as before it'],
            [:pending, :interrupt] => [:prefix_then, 'drop the prefix, then Ctrl-C as before it'],
            [:pending, :suspend] => [:prefix_then, 'drop the prefix, then hide'],
            [:pending, :once_key] => [:prefix_then, 'drop the prefix (Esc to the REPL), then Ctrl-W as before it'],
            [:pending, :prefix] => [:prefix_key, 'the prefix keymap, else pass-through'],
            [:pending, :global] => [:prefix_key, 'the prefix keymap, else pass-through'],
            [:pending, :key] => [:prefix_key, 'the prefix keymap; else to the REPL after the prefix key (pass-through) or refused'],
            [:pending, :release] => [:ignore, 'ignored (the prefix key let go)'],
            [:pending, :paste] => [:prefix_then, 'the prefix key to the REPL (pass-through), then the paste'],
            [:pending, :tick] => [:prefix_tick, 'after the timeout: the timeout action (held Esc: NAV)'],
            [:pending, :other] => [:act_event, 'mouse, focus, replies (the prefix keeps waiting)'],
          }.freeze

          # The table as text lines ("repl  Ctrl-] (nav_key)  to NAV ..."),
          # for help and the overlay.
          def self.table(states = STATES)
            states.flat_map do |s|
              ["#{s}:", *EVENTS.map { |e| format('  %-10s %s', e, TABLE.fetch([s, e])[1]) }]
            end
          end

          # The state (see STATES).
          attr_reader :state

          # Seconds a lone Escape waits before entering NAV (nil: Escape
          # always goes to the REPL; 0.25-0.4 is a comfortable range).
          attr_accessor :nav_esc

          # True (default) when Ctrl-W is the one-shot NAV key (:once);
          # false leaves Ctrl-W to the REPL and the keyboard.
          attr_accessor :nav_once

          # Where :once goes back to (nil outside :once).
          attr_reader :once_return

          # The palette or search prompt while in :line (or in :nav entered
          # from :line, kept for coming back).
          attr_reader :line

          # The prefix waiting in :pending (a Prefix), its origin state, and
          # the time it started.
          attr_reader :prefix, :origin, :since

          # Where NAV goes back to (Ctrl-] in NAV).
          attr_reader :nav_return

          # Direct bindings in :repl (and :play), consulted before keys go
          # to the REPL (Alt-PgUp scrolls, `ui.bind`).
          attr_reader :repl_keys

          # +host+ responds to #repl_key(Key), #repl_paste(String),
          # #act(Action), #line_done(kind, text or nil), #mode_changed(mode),
          # #grab_key(Key) (for :grab), #play_key(Key) (without a console),
          # #pane_mode_key(Key) (for :pane: true if the pane took it), and
          # optionally #pane_keymap (the focused pane's Keymap, or nil) and
          # #once_target(origin) (where :once goes after its action: the
          # origin, or the mode of the pane the focus moved to).
          # +console+ false: no REPL (the base state is :play).
          def initialize(host, nav: NAV, nav_esc: nil, console: true, nav_once: true, repl_keys: nil)
            @host = host
            @nav = nav
            @nav_esc = nav_esc
            @nav_once = nav_once
            @once_return = nil
            @console = console
            @base = console ? :repl : :play
            @state = @base
            @nav_return = @base
            @overlay_return = :nav
            @line = nil
            @line_return = @base
            @prefix = nil
            @origin = nil
            @since = nil
            @extra = []
            @first = []
            @repl_keys = repl_keys || Keymap.new(:repl)
            @midi = {}
            @last_cc = {}
          end

          # The mode the host draws: the state, or a waiting prefix's origin.
          def mode = @state == :pending ? @origin : @state

          # True without a console (a script's screen).
          def console? = @console

          # Adds a keymap consulted in :nav after NAV (+first+: before NAV,
          # after the focused pane's; users' bindings).
          def add_keymap(map, first: false)
            list = first ? @first : @extra
            list << map unless list.include?(map)
            self
          end

          # Changes the state (:repl, :nav, :grab, :overlay, :line with
          # #open_line; :repl means the base state on a screen without a
          # console).  Entering :nav remembers where from (Ctrl-] goes back).
          def mode=(m)
            m = @base if m == :repl || m == :play
            raise ArgumentError, "Router states to set are #{(STATES - %i[pending play once]).map(&:inspect).join(', ')} (got #{m.inspect})" unless STATES.include?(m) && m != :pending && m != :once
            drop_prefix if @state == :pending
            return if m == @state
            go(m)
          end

          # Opens a one-line prompt (+kind+ :palette or :search).
          def open_line(kind, prompt, history: [])
            drop_prefix if @state == :pending
            @line = LineInput.new(kind, prompt, history)
            from = @state == :overlay ? @overlay_return : @state
            from = @once_return if from == :once
            @line_return = from == :line ? @line_return : from
            go(:line, force: true)
          end

          # The prefixes active in +state+ (a held Esc in :repl with
          # #nav_esc).
          def prefixes(state = @state)
            state == :repl && @nav_esc ? [esc_prefix] : []
          end

          # What the Router calls on its host (the optional ones through
          # respond_to?, which is false for a private method: a spec checks
          # that Tiles has each one public, ux-r4b).
          HOST_METHODS = %i[repl_key repl_paste act line_done mode_changed grab_key play_key pane_mode_key pane_keymap once_target].freeze

          # The states Ctrl-W starts :once from.
          ONCE_FROM = %i[repl play nav grab pane].freeze

          # Seconds until #tick has something to do (a prefix with a
          # timeout), or nil.
          def wait(now)
            return nil unless @state == :pending && @prefix.timeout
            [@since + @prefix.timeout - now, 0].max
          end

          # Acts on a prefix whose time ran out.
          def tick(now)
            dispatch(:tick, nil, now)
          end

          # The event class of +e+ in the current state (see EVENTS).
          def classify(e, state = @state)
            case e
            when Paste then :paste
            when Key
              return :release if e.release?
              chord = e.chord
              return :nav_key if chord == NAV_KEY.chord
              return :keys_key if chord == KEYS_KEY.chord
              return :interrupt if chord == INTERRUPT_KEY.chord
              return :suspend if chord == SUSPEND_KEY.chord
              return :once_key if @nav_once && chord == ONCE_KEY.chord
              return :prefix if state == :pending ? prefix_chord?(e) : prefixes(state).any? { |p| p.key.chord == chord }
              return :global if GLOBAL.bound?(e)
              :key
            when nil then :tick
            else :other
            end
          end

          # Routes one event (Key, Paste, Mouse, Focus, Reply) at time +now+.
          def event(e, now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
            dispatch(classify(e), e, now)
          end

          alias key event

          # Text pasted (as a Paste event).
          def paste(text)
            event(Paste.new(text: text))
          end

          # MIDI bindings: `map_midi(:note, 36, :zoom)`,
          # `map_midi(:cc, 21, [:resize, :right, 2])`, or a Proc.
          def map_midi(type, number, action)
            raise ArgumentError, "MIDI bindings are :note or :cc (got #{type.inspect})" unless %i[note cc].include?(type)
            raise ArgumentError, "MIDI numbers are 0..127 (got #{number.inspect})" unless (0..127).cover?(number)
            @midi[[type, number]] = action
            self
          end

          # Removes a MIDI binding.
          def unmap_midi(type, number)
            @midi.delete([type, number])
            self
          end

          # MIDI bindings ({[type, number] => action}).
          def midi_map
            @midi.dup
          end

          # A MIDI event (+type+ :note or :cc, +number+, +value+ 0..1):
          # notes act on note-on, CCs when they cross 0.5 upward (a button),
          # so a held pad doesn't repeat.  Returns the Action, or nil.
          def midi(type, number, value)
            binding = @midi[[type, number]] or return nil
            if type == :cc
              was = @last_cc[number] || 0
              @last_cc[number] = value
              return nil unless was < 0.5 && value >= 0.5
            else
              return nil unless value > 0
            end
            a = binding.is_a?(Proc) ? Action.of(:call, binding) : Action.of(*Array(binding))
            @host.act(a)
            a
          end

          def inspect
            "#<UI::Input::Router #{@state}#{@state == :pending ? " #{@prefix.name} from #{@origin}" : ''}#{@state == :once ? " from #{@once_return}" : ''}>"
          end

          private

          # Runs the TABLE entry for (state, +event+).
          def dispatch(event, e, now)
            handler, = TABLE.fetch([@state, event])
            send(handler, e, now, event)
          end

          # Moves to +to+, telling the host when the mode it draws changes.
          def go(to, force: false)
            from = mode
            if to == :nav
              src = @state == :overlay ? @overlay_return : @state
              src = @once_return if src == :once
              @nav_return = src == :line ? :line : base_of(src) unless src == :nav
            end
            @overlay_return = @state == :pending ? @origin : @state if to == :overlay && @state != :overlay
            unless to == :line || (to == :nav && @nav_return == :line) || line_kept?(to)
              drop_line
            end
            @once_return = nil unless to == :once || (to == :overlay && @overlay_return == :once)
            @state = to
            @host.mode_changed(to) if force || to != from
          end

          # True if going to +to+ (:overlay or :once) keeps a prompt line
          # NAV was entered from.
          def line_kept?(to)
            under = to == :overlay ? @overlay_return : to
            under = @once_return if under == :once
            %i[overlay once].include?(to) && under == :nav && @nav_return == :line
          end

          # The state +s+ falls back to (the base for anything not grab).
          def base_of(s) = s == :grab || s == :pane ? s : s == :line ? @line_return : %i[nav overlay pending].include?(s) ? @base : s

          def drop_line
            return unless @line
            kind = @line.kind
            @line = nil
            @host.line_done(kind, nil)
          end

          def drop_prefix
            return unless @state == :pending
            @state = @origin
            @prefix = @origin = @since = nil
          end

          def esc_prefix
            Prefix.new(name: :esc_nav, key: Key.of(:escape), keymap: nil, timeout: @nav_esc, on_timeout: Action.of(:mode, :nav), pass_through: true)
          end

          def prefix_chord?(e)
            @prefix.keymap&.bound?(e) || false
          end

          # The NAV action for +e+: the focused pane's keys, then the first
          # keymaps, NAV, the extra keymaps; nil if none binds it.
          def nav_action(e)
            pane = @host.respond_to?(:pane_keymap) ? @host.pane_keymap : nil
            if (pa = pane&.[](e))
              return Action.of(:pane_key, pa)
            end
            @first.lazy.map { |m| m[e] }.find(&:itself) || @nav[e] || @extra.lazy.map { |m| m[e] }.find(&:itself)
          end

          ### Handlers (e, now, event)

          def ignore(*) = nil

          def refuse(e, _now, event)
            why = TABLE.fetch([@state, event])[1]
            @host.act(Action.of(:refused, e.is_a?(Key) ? e.to_s : event.to_s, why))
          end

          def act_event(e, *) = @host.act(Action.of(:event, e))
          def act_keys(*) = @host.act(Action.of(:keys))
          def act_interrupt(*) = @host.act(Action.of(:interrupt))
          def act_hide(*) = @host.act(Action.of(:hide))
          def act_global(e, *) = @host.act(GLOBAL[e])

          def enter_nav(*) = go(:nav)

          def leave_nav(*)
            to = @nav_return
            to = @base if to == :line && @line.nil?
            go(to)
          end

          def to_base(*) = go(@base)

          def repl_key(e, *)
            if (a = @repl_keys[e])
              return @host.act(a)
            end
            @host.repl_key(e)
          end

          def play_key(e, *)
            if (a = @repl_keys[e])
              return @host.act(a)
            end
            @host.play_key(e)
          end

          def repl_paste(e, *) = @host.repl_paste(e.text)
          def grab_key(e, *) = @host.grab_key(e)

          # A key in a pane's own mode: Esc to NAV, else the pane (#pane_mode_key
          # true when it took the key), else ? the overlay, else refused.
          def pane_key(e, now, event)
            return go(:nav) if e.key == :escape && e.mods.empty?
            return if @host.pane_mode_key(e)
            return go(:overlay) if e.key == '?'
            @host.act(Action.of(:refused, e.to_s, 'not a key of this pane (Esc: NAV, ? lists its keys)'))
          end

          def nav_key(e, *)
            a = nav_action(e)
            return @host.act(a) if a
            @host.act(Action.of(:unbound, e))
          end

          ### One-shot NAV (:once)

          def start_once(*)
            @once_return = @state
            go(:once)
          end

          # Back where Ctrl-W came from.
          def once_back
            to = @once_return
            go(to == :line && @line.nil? ? @base : to)
          end

          # After the one action: back, or into the pane the focus moved to
          # (#once_target); nothing if the action changed the mode itself.
          def once_done
            return unless @state == :once
            to = @host.respond_to?(:once_target) ? @host.once_target(@once_return) : @once_return
            to = @once_return unless STATES.include?(to) && !%i[once pending overlay line].include?(to)
            go(to == :repl ? @base : to)
          end

          def once_key(e, *)
            return once_back if e.key == :escape && e.mods.empty?
            a = nav_action(e)
            unless a
              go(:overlay)
              return @host.act(Action.of(:unbound, e, 'Ctrl-W then'))
            end
            @host.act(a)
            once_done
          end

          # Ctrl-W Ctrl-W: the pane focused before, gone into.
          def once_last(*)
            @host.act(Action.of(:focus_last))
            once_done
          end

          # Ctrl-W Ctrl-]: NAV to stay (Ctrl-] there goes back where Ctrl-W
          # came from).
          def once_to_nav(*) = go(:nav)

          # Back where Ctrl-W came from, then the event as there.
          def once_then(e, now, _event)
            once_back
            dispatch(classify(e), e, now)
          end

          def start_prefix(e, now, _event)
            p = prefixes.find { |x| x.key.chord == e.chord }
            @origin = @state
            @prefix = p
            @since = now
            @state = :pending
            @host.act(Action.of(:prefix, p.name)) if p.keymap
          end

          # A key after the prefix: its keymap's action, else pass-through
          # (the prefix key and this key to the REPL) or refused.
          def prefix_key(e, now, _event)
            p = @prefix
            origin = @origin
            if (a = p.keymap&.[](e))
              drop_prefix
              @host.act(a)
              return
            end
            drop_prefix
            if p.pass_through && origin == :repl
              @host.repl_key(p.key.bytes ? p.key : with_bytes(p.key))
              # (the key after it doesn't start the same prefix again: Esc Esc goes to the REPL as two keys)
              return @host.repl_key(e) if e.chord == p.key.chord
              return dispatch(classify(e), e, now)
            end
            @host.act(Action.of(:unbound, Key.of(e.key, *e.mods, bytes: e.bytes, type: e.type), "#{Keymap.chord_name(p.key.chord)} then"))
          end

          # Leaves the prefix, then handles the event as the origin state
          # would (a pass-through prefix sends its key to the REPL first for
          # a paste).
          def prefix_then(e, now, event)
            p = @prefix
            origin = @origin
            drop_prefix
            @host.repl_key(with_bytes(p.key)) if event == :paste && p.pass_through && origin == :repl
            dispatch(classify(e), e, now)
          end

          def prefix_tick(_e, now, _event)
            return unless @prefix.timeout && now - @since >= @prefix.timeout
            a = @prefix.on_timeout
            drop_prefix
            if a && a.name == :mode
              go(a.args[0] == :nav ? :nav : a.args[0])
            elsif a
              @host.act(a)
            end
          end

          def overlay_to_nav(*)
            go(:nav)
          end

          def overlay_key(e, now, event)
            if e.key == :escape || e.key == '?'
              return @overlay_return == :once ? once_back : go(@overlay_return)
            end
            overlay_then(e, now, event)
          end

          def overlay_then(e, now, _event)
            go(@overlay_return)
            dispatch(classify(e), e, now)
          end

          def line_paste(e, *)
            @line.insert(e.text.delete("\r\n"))
            @host.act(Action.of(:line_changed))
          end

          def line_then_keys(*)
            line_cancel
            @host.act(Action.of(:keys))
          end

          def line_key(k, *)
            l = @line
            case k.key
            when :enter
              kind = l.kind
              text = l.text
              l.remember
              @line = nil
              go(@line_return)
              @host.line_done(kind, text)
              return
            when :escape then return line_cancel
            when :backspace then k.mods.include?(:alt) || k.mods.include?(:ctrl) ? l.delete_word : l.backspace
            when :delete then k.mods.include?(:ctrl) ? (k.mods.include?(:shift) ? l.kill_forward : l.delete_word_forward) : l.delete
            when :left then l.move(-1)
            when :right then l.move(1)
            when :home then l.move(-l.cursor)
            when :end then l.move(l.text.length)
            when :up then l.history_step(-1)
            when :down then l.history_step(1)
            when :tab then @host.act(Action.of(:complete))
            else
              if k.text?
                l.insert(k.key)
              elsif k.mods == [:ctrl]
                case k.key
                when 'a' then l.move(-l.cursor)
                when 'e' then l.move(l.text.length)
                when 'u' then l.kill_back
                when 'k' then l.kill_forward
                when 'w', 'h' then l.delete_word
                end
              end
            end
            @host.act(Action.of(:line_changed))
          end

          def line_cancel(*)
            kind = @line&.kind
            @line = nil
            go(@line_return)
            @host.line_done(kind, nil)
          end

          # +key+ with legacy bytes (a prefix Key made from a chord).
          def with_bytes(key)
            key.bytes ? key : Key.of(key.key, *key.mods, bytes: Input.legacy_bytes(key))
          end
        end

        # A one-line prompt (the palette, search): text, cursor, history.
        class LineInput
          attr_reader :kind, :prompt, :text, :cursor

          def initialize(kind, prompt, history)
            @kind = kind
            @prompt = prompt
            @history = history
            @hpos = history.length
            @text = +''
            @cursor = 0
          end

          def insert(s)
            @text.insert(@cursor, s)
            @cursor += s.length
          end

          def backspace
            return if @cursor == 0
            @text.slice!(@cursor - 1)
            @cursor -= 1
          end

          def delete
            @text.slice!(@cursor) if @cursor < @text.length
          end

          def delete_word
            start = @text[0, @cursor].rstrip.rindex(/[\s.(:,]/)
            start = start ? start + 1 : 0
            @text.slice!(start...@cursor)
            @cursor = start
          end

          def delete_word_forward
            rest = @text[@cursor..]
            n = rest[/\A[\s.(:,]*[^\s.(:,]*/].length
            @text.slice!(@cursor, n)
          end

          def kill_back
            @text.slice!(0, @cursor)
            @cursor = 0
          end

          def kill_forward
            @text.slice!(@cursor..)
          end

          def move(n)
            @cursor = (@cursor + n).clamp(0, @text.length)
          end

          def history_step(d)
            return if @history.empty?
            @hpos = (@hpos + d).clamp(0, @history.length)
            @text = (@history[@hpos] || '').dup
            @cursor = @text.length
          end

          def remember
            @history << @text.dup unless @text.empty? || @history.last == @text
            @history.shift while @history.length > 100
          end
        end
      end
    end
  end
end
