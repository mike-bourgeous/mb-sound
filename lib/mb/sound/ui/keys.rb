module MB
  module Sound
    module UI
      # The key table (ux-1 round 3, pattern C): every UI key, what it
      # does in each mode, and what it does where the tiled screen isn't up
      # (the band, no UI), in one place.  The `?` overlay, `help :ui`
      # (Tiles::KEY_HELP), and the specs read it, so they can't drift.
      #
      # Keymaps: MB::Term::Input::Router::NAV (the Router's own), NAV_EXTRA
      # (mb-sound's NAV keys), Keyboard::KEYMAP (KEYS mode), the REPL's
      # direct keys (REPL_DEFAULTS, minus what the user's inputrc binds,
      # plus `ui.bind`), and doc lines for keys the Router reads itself.
      #
      #     ui.bind ['k', :ctrl], :keys      # Ctrl-K: KEYS (instead of kill to end of line)
      #     ui.bind [:f5], :zoom, mode: :nav
      #     ui.unbind ['k', :ctrl]
      module Keys
        Keymap = MB::Term::Input::Keymap

        # NAV keys of mb-sound's own panes (after Router::NAV).
        NAV_EXTRA = Keymap.new(:tiles) do
          group 'Jump'
          on 'i', :jump, :repl, help: 'into: REPL i, KEYS k, tracks t, meters e', label: 'i k t e'
          on 'k', :jump, :keyboard, help: 'into: REPL i, KEYS k, tracks t, meters e', label: ''
          # (K as the docs and the keyboard pane's hint say; panel round 2,
          # K16/N7: "K: not a NAV key" in :studio, and the next letters
          # went to NAV)
          on 'K', :keys, help: 'KEYS: the keyboard (put in below the REPL if missing; F2 too)'
          on 't', :jump, :tracks, help: 'into: REPL i, KEYS k, tracks t, meters e', label: ''
          on 'e', :jump, :meters, help: 'into: REPL i, KEYS k, tracks t, meters e', label: ''
          doc 'a b ...', "a pane's letter (by its number in NAV)"
          group 'Modes'
          on ' ', :pause, help: 'play / pause (starts the flow if nothing played yet)', label: 'Space'
          on 'm', :messages, help: 'messages (warnings) pane, again: away'
          on 'f', :show_fps, help: 'frame rate on the status line'
          on '?', :key_help, help: 'this help (a key listed here closes it and acts)'
          doc 'Ctrl-]', 'back to where NAV came from (REPL, KEYS, a prompt)'
          doc 'Ctrl-Z', 'hide the tiles (the set plays on; Ctrl-Z or ui: back)'
        end

        # Jump letters of the built-in panes (pane name => letter, as bound
        # in NAV_EXTRA); other pane kinds declare theirs with
        # `jump 'a'` (UI::PaneKeys).  #check_jumps keeps them all clear of
        # NAV's keys and each other.
        JUMPS = NAV_EXTRA.entries.select { |b| b.action == :jump }.to_h { |b| [b.args[0], b.chord[0]] }.freeze

        # Letters a jump may not take: every key NAV binds (Router::NAV,
        # NAV_EXTRA but jumps; Ctrl-W reads the same keys once).
        def self.reserved_letters
          maps = [MB::Term::Input::Router::NAV, NAV_EXTRA]
          maps.flat_map { |m| m.entries.reject { |b| b.action == :jump }.map(&:chord) }.select { |k, mods| k.is_a?(String) && mods.empty? }.map(&:first).uniq.sort
        end

        # Problems with jump letters ({name => letter} of panes' declared
        # jumps): reserved letters and letters claimed twice.  Empty when
        # all is well.
        def self.check_jumps(declared)
          out = []
          reserved = reserved_letters
          all = JUMPS.to_a + declared.to_a
          all.each { |name, l| out << "#{name.inspect}'s jump #{l.inspect} is a NAV key" if reserved.include?(l) }
          all.group_by(&:last).each { |l, list| out << "jump #{l.inspect} is claimed by #{list.map { |n, _| n.inspect }.uniq.join(' and ')}" if list.map(&:first).uniq.length > 1 }
          out
        end

        # Direct REPL keys (scrolling without NAV), each taken only when
        # the user's inputrc doesn't bind it (MB::Term::Input::RelineKeys.user_bound?).
        REPL_DEFAULTS = Keymap.new(:repl) do
          group 'REPL'
          on [:page_up, :alt], :scroll, :page_up, help: 'scroll the REPL back, forward (typing: back to live)'
          on [:page_down, :alt], :scroll, :page_down, help: 'scroll the REPL back, forward (typing: back to live)'
        end

        # Keys the Router reads itself in the REPL (doc lines).
        REPL_DOCS = Keymap.new(:repl_docs) do
          group 'REPL'
          doc 'Ctrl-]', 'NAV (Ctrl-] again: back)'
          doc 'Ctrl-W then a NAV key', 'that one NAV action, then back (Ctrl-W Ctrl-W: the last pane)'
          doc 'F2', 'KEYS (the keyboard pane)'
          doc 'Ctrl-BkSp Ctrl-Del', 'delete the word before, after the cursor'
          doc 'Ctrl-S-Del', 'delete to the end of the line'
          doc 'PgUp PgDn', 'history search (Reline; your inputrc decides)'
          doc 'Ctrl-C Ctrl-Z', 'interrupt, hide the tiles'
        end

        # The one-shot NAV (Ctrl-W, the Router's :once; doc lines).
        ONCE_DOCS = Keymap.new(:once) do
          group 'Ctrl-W then (one NAV key, then back)'
          doc 'any NAV key', 'that action, then back where you were (z zooms, u undoes, ...)'
          doc 'arrows Tab 1-9 p', 'focus a pane and go into it, as Enter would'
          doc 'a k t e i ...', 'jump into that pane'
          doc 'Ctrl-W', 'the pane focused before, gone into (again: back)'
          doc 'Ctrl-]', 'stay in NAV'
          doc 'Esc', 'back, nothing done'
          doc 'other keys', 'this overlay (a key listed here then acts once)'
        end

        # Step entry's keys (StepEntry reads them; doc lines).
        STEP_DOCS = Keymap.new(:step) do
          group 'Step entry'
          doc 'z x c v ...', 'a note (several at once: a chord)'
          doc '1-7', 'whole .. 64th'
          doc '8 9', 'dotted, triplet'
          doc 'r t', 'rest, tie'
          doc 'a `', 'accent, slide the last step'
          doc 'BkSp Del', 'undo a step, clear'
          doc 'p', 'play the clip'
          doc 'w', 'swap it into the armed tracks'
          doc 'Enter', 'done: its Ruby on the REPL line'
          doc 'Tab', 'back to playing'
          doc 'Ctrl-]', 'NAV (Ctrl-] again: back)'
        end

        # Script screens' keys (bin/ scripts' --ui; items 42, 43): the
        # Router's :play state consults them first (Tiles.new(play_keys:)),
        # each binding an action the script handles (Tiles' on_action:).
        # Repeats act like presses (a held Left keeps stepping, kitty
        # repeat events too); releases are ignored.  One rule per screen
        # kind for Esc: song screens quit, synth and effect screens send
        # all notes off (twice: all sound off).
        SONG_SCREEN = Keymap.new(:song_screen) do
          group 'Song'
          on ['q', 'Q', :escape], :quit, help: 'quit (also Ctrl-C)', label: 'q Esc'
          on ' ', :pause, help: 'pause, play on'
          on :left, :bar_back, help: 'back, forward a bar (first press: to this bar\'s start; held: keeps going)', label: 'Left Right'
          on :right, :bar_forward, help: 'back, forward a bar (first press: to this bar\'s start; held: keeps going)', label: 'Left Right'
          on ['[', :up], :section_prev, help: 'previous, next section', label: '[ ] Up Down'
          on [']', :down], :section_next, help: 'previous, next section', label: '[ ] Up Down'
          on :page_up, :scene_prev, help: 'previous, next scene', label: 'PgUp PgDn'
          on :page_down, :scene_next, help: 'previous, next scene', label: 'PgUp PgDn'
          doc 'Ctrl-] F2', 'NAV (zoom a pane, ...), the keyboard'
        end

        SYNTH_SCREEN = Keymap.new(:synth_screen) do
          group 'Synth'
          on ['q', 'Q'], :quit, help: 'quit (also Ctrl-C)', label: 'q'
          on :escape, :panic, help: 'all notes off (again: all sound off)'
          on ' ', :pause, help: 'pause, play on'
          doc 'Ctrl-] F2', 'NAV (zoom a pane, ...), the keyboard'
        end

        # A screen's status-line hints from its keymap ("q Esc quit  Space
        # pause ..."): the first words of each help line.
        def self.hints(map)
          map.help_groups.flat_map { |_, lines| lines.map { |k, what| "#{k} #{what.split(/[(;]/).first.strip}" } }.join('  ')
        end

        # What the UI keys do where the tiled screen isn't up: [key, in the
        # band, with no UI].  Every key the tiles read from the REPL has a
        # row (a spec checks), so none is dropped silently in another mode.
        ELSEWHERE = [
          ['Ctrl-]', 'the band\'s tiled screen, in NAV', 'the tiled screen, in NAV'],
          ['F2', 'KEYS (the tiled :keys screen)', 'KEYS (the tiled :keys screen)'],
          ['Ctrl-W', 'Reline: delete a word (in the tiles: one NAV key)', 'Reline: delete a word'],
          ['Alt-PgUp Alt-PgDn', 'the terminal\'s own (scrollback: Shift-PgUp)', 'the terminal\'s own'],
          ['Ctrl-BkSp Ctrl-Del', 'delete the word before, after', 'delete the word before, after'],
          ['Ctrl-S-Del', 'delete to the end of the line', 'delete to the end of the line'],
          ['Ctrl-C', 'interrupt', 'interrupt'],
          ['Ctrl-Z', 'nothing (the band stays; ui off)', 'nothing (Reline ignores it)'],
        ].freeze

        class << self
          # Users' bindings by mode (:repl, :nav), from #bind.
          def user
            @user ||= { repl: Keymap.new(:user_repl) { group 'Yours' }, nav: Keymap.new(:user_nav) { group 'Yours' } }
          end

          # The REPL keymap a tiled screen's Router consults before Reline:
          # REPL_DEFAULTS not bound in the user's inputrc, plus #bind's.
          # Rebuilt by #rebuild (after #bind); +config+ a Reline::Config
          # (specs pass one read from a temporary INPUTRC).
          def repl_keymap(config: :default)
            @repl_keymap = nil if config != :default
            @repl_keymap ||= build_repl(config)
          end

          # The default keys the user's inputrc took (Keymap entries).
          def skipped = @skipped || []

          # Binds +key+ (as for Keymap#on: 'x', [:f5], ['k', :ctrl]) to
          # +action+ (a Tiles action: :keys, :zoom, :scroll, :panic, ...)
          # with +args+ in +mode+ (:repl, the default, or :nav).  A REPL key
          # the user's inputrc binds still binds (you asked), with a note.
          # Returns a note String.
          def bind(key, action, *args, mode: :repl, help: nil)
            map = user.fetch(mode) { raise ArgumentError, "ui.bind modes are :repl and :nav (got #{mode.inspect})" }
            k = key.is_a?(Array) ? MB::Term::Input::Key.of(*key) : MB::Term::Input::Key.of(key)
            raise ArgumentError, "#{Keymap.chord_name(k.chord)} is the NAV key; it stays" if k.chord == MB::Term::Input::Router::NAV_KEY.chord
            map.on(key.is_a?(Array) && key.length == 1 ? key[0] : key, action, *args, help: help || action.to_s.tr('_', ' '))
            rebuild
            note = "#{Keymap.chord_name(k.chord)} -> #{action}#{args.empty? ? '' : " #{args.map(&:inspect).join(', ')}"} (#{mode})"
            note += '; your inputrc binds it too, the UI takes it in the tiles' if mode == :repl && MB::Term::Input::RelineKeys.user_bound?(k)
            note
          end

          # Removes a #bind binding.
          def unbind(key, mode: :repl)
            user.fetch(mode).off(key.is_a?(Array) && key.length == 1 ? key[0] : key)
            rebuild
            self
          end

          # Rebuilds the REPL keymap in place (live Routers see it).
          def rebuild
            fresh = build_repl(:default)
            if @repl_keymap
              @repl_keymap.entries.each { |b| @repl_keymap.off(b.keys) }
              fresh.entries.each { |b| @repl_keymap.on(b.keys, b.action, *b.args, help: b.help) }
            else
              @repl_keymap = fresh
            end
            self
          end

          # Key-table groups for +mode+ (:repl, :nav, :once, :grab, :step).
          def groups(mode)
            case mode
            when :repl then merge(repl_keymap.help_groups, REPL_DOCS.help_groups)
            when :nav then merge(MB::Term::Input::Router::NAV.help_groups, NAV_EXTRA.help_groups, user[:nav].help_groups)
            when :once then ONCE_DOCS.help_groups
            when :grab then Keyboard::KEYMAP.help_groups
            when :step then STEP_DOCS.help_groups
            else raise ArgumentError, "Key table modes are :repl, :nav, :once, :grab, :step (got #{mode.inspect})"
            end
          end

          # The key table by mode, for help :ui ({mode => groups}).
          # +live+ false lists the REPL's default keys without reading the
          # inputrc (Tiles::KEY_HELP, built at load time).
          def table(live: true)
            %i[repl nav once grab step].to_h { |m|
              [m, m == :repl && !live ? merge(REPL_DEFAULTS.help_groups, REPL_DOCS.help_groups) : groups(m)]
            }.merge(elsewhere: [['Outside the tiles', ELSEWHERE.map { |k, band, off| [k, band == off ? "band, no UI: #{band}" : "band: #{band}; no UI: #{off}"] }]])
          end

          private

          # Groups with the same title joined (in first-seen order).
          def merge(*lists)
            out = {}
            lists.each { |l| l.each { |g, keys| (out[g] ||= []).concat(keys) } }
            out.to_a
          end

          def build_repl(config)
            map = Keymap.new(:repl) { group 'REPL' }
            @skipped = []
            REPL_DEFAULTS.entries.each do |b|
              key = MB::Term::Input::Key.of(b.chord[0], *b.chord[1])
              taken = config == :default ? MB::Term::Input::RelineKeys.user_bound?(key) : MB::Term::Input::RelineKeys.user_bound?(key, config: config)
              if taken
                @skipped << b
              else
                map.on(b.keys, b.action, *b.args, help: b.help)
              end
            end
            user[:repl].entries.each { |b| map.on(b.keys, b.action, *b.args, help: b.help) }
            map
          end
        end
      end
    end
  end
end
