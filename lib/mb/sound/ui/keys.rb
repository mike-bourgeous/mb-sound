module MB
  module Sound
    module UI
      # The key table (ux-1 round 3, pattern C): every UI key, what it
      # does in each mode, and what it does where the tiled screen isn't up
      # (the band, no UI), in one place.  The `?` overlay, `help :ui`
      # (Tiles::KEY_HELP), and the specs read it, so they can't drift.
      #
      # Keymaps: Input::Router::NAV and WINDOW (the Router's own), NAV_EXTRA
      # (mb-sound's NAV keys), Keyboard::KEYMAP (KEYS mode), the REPL's
      # direct keys (REPL_DEFAULTS, minus what the user's inputrc binds,
      # plus `ui.bind`), and doc lines for keys the Router reads itself.
      #
      #     ui.bind ['k', :ctrl], :keys      # Ctrl-K: KEYS (instead of kill to end of line)
      #     ui.bind [:f5], :zoom, mode: :nav
      #     ui.unbind ['k', :ctrl]
      module Keys
        Keymap = Input::Keymap

        # NAV keys of mb-sound's own panes (after Router::NAV).
        NAV_EXTRA = Keymap.new(:tiles) do
          group 'Modes'
          on 'p', :keys, help: 'play the keyboard (KEYS; F2 also from the REPL)'
          on 'm', :messages, help: 'messages (warnings) pane, again: away'
          on 'f', :show_fps, help: 'frame rate on the status line'
          on '?', :key_help, help: 'this help (a key listed here closes it and acts)'
          doc 'Ctrl-]', 'back to where NAV came from (REPL, KEYS, a prompt)'
          doc 'Ctrl-Z', 'hide the tiles (the set plays on; Ctrl-Z or ui: back)'
        end

        # Direct REPL keys (scrolling without NAV), each taken only when
        # the user's inputrc doesn't bind it (Input::RelineKeys.user_bound?).
        REPL_DEFAULTS = Keymap.new(:repl) do
          group 'REPL'
          on [:page_up, :alt], :scroll, :page_up, help: 'scroll the REPL back, forward (typing: back to live)'
          on [:page_down, :alt], :scroll, :page_down, help: 'scroll the REPL back, forward (typing: back to live)'
        end

        # Keys the Router reads itself in the REPL (doc lines).
        REPL_DOCS = Keymap.new(:repl_docs) do
          group 'REPL'
          doc 'Ctrl-]', 'NAV (Ctrl-] again: back)'
          doc 'Ctrl-W then h j k l w p', 'focus a pane, as in vim (other keys: Ctrl-W deletes a word, then the key)'
          doc 'F2', 'KEYS (the keyboard pane)'
          doc 'Ctrl-BkSp Ctrl-Del', 'delete the word before, after the cursor'
          doc 'Ctrl-S-Del', 'delete to the end of the line'
          doc 'PgUp PgDn', 'history search (Reline; your inputrc decides)'
          doc 'Ctrl-C Ctrl-Z', 'interrupt, hide the tiles'
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

        # What the UI keys do where the tiled screen isn't up: [key, in the
        # band, with no UI].  Every key the tiles read from the REPL has a
        # row (a spec checks), so none is dropped silently in another mode.
        ELSEWHERE = [
          ['Ctrl-]', 'the tiled screen with the band\'s panes, in NAV', 'the tiled screen (ui :tiles), in NAV'],
          ['F2', 'KEYS: the tiled :keys screen', 'KEYS: the tiled :keys screen'],
          ['Ctrl-W', 'Reline: delete the word before the cursor', 'Reline: delete the word before the cursor'],
          ['Alt-PgUp Alt-PgDn', 'the terminal\'s own scrollback (Shift-PgUp in most terminals)', 'the terminal\'s scrollback'],
          ['Ctrl-BkSp Ctrl-Del Ctrl-S-Del', 'Reline: delete word back, next word, to the end', 'the same'],
          ['Ctrl-C', 'interrupt', 'interrupt'],
          ['Ctrl-Z', 'nothing to hide (the band stays; ui off)', 'Reline: ignored'],
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
            k = key.is_a?(Array) ? Input::Key.of(*key) : Input::Key.of(key)
            raise ArgumentError, "#{Keymap.chord_name(k.chord)} is the NAV key; it stays" if k.chord == Input::Router::NAV_KEY.chord
            map.on(key.is_a?(Array) && key.length == 1 ? key[0] : key, action, *args, help: help || action.to_s.tr('_', ' '))
            rebuild
            note = "#{Keymap.chord_name(k.chord)} -> #{action}#{args.empty? ? '' : " #{args.map(&:inspect).join(', ')}"} (#{mode})"
            note += '; your inputrc binds it too, the UI takes it in the tiles' if mode == :repl && Input::RelineKeys.user_bound?(k)
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

          # Key-table groups for +mode+ (:repl, :nav, :window, :grab, :step).
          def groups(mode)
            case mode
            when :repl then merge(repl_keymap.help_groups, REPL_DOCS.help_groups)
            when :nav then merge(Input::Router::NAV.help_groups, NAV_EXTRA.help_groups, user[:nav].help_groups)
            when :window then Input::Router::WINDOW.help_groups
            when :grab then Keyboard::KEYMAP.help_groups
            when :step then STEP_DOCS.help_groups
            else raise ArgumentError, "Key table modes are :repl, :nav, :window, :grab, :step (got #{mode.inspect})"
            end
          end

          # The key table by mode, for help :ui ({mode => groups}).
          # +live+ false lists the REPL's default keys without reading the
          # inputrc (Tiles::KEY_HELP, built at load time).
          def table(live: true)
            %i[repl nav window grab step].to_h { |m|
              [m, m == :repl && !live ? merge(REPL_DEFAULTS.help_groups, REPL_DOCS.help_groups) : groups(m)]
            }.merge(elsewhere: [['Outside the tiles', ELSEWHERE.map { |k, band, off| [k, "band: #{band}; no UI: #{off}"] }]])
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
              key = Input::Key.of(b.chord[0], *b.chord[1])
              taken = config == :default ? Input::RelineKeys.user_bound?(key) : Input::RelineKeys.user_bound?(key, config: config)
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
