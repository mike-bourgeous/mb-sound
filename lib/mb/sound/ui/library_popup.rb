module MB
  module Sound
    module UI
      # Find-as-you-type for library heads at the console prompt
      # (omnibus15; maintainer, 2026-10-28: "Better yet...
      # find-as-you-type"): while the word under the cursor is a head
      # chain (`L.`, `L.inst.ree`, `L.reese`), a Reline dialog under it
      # lists the entries matching what is typed anywhere in their names,
      # name words, tags, and families (Library::Finder, ranked), narrowing
      # with every key.  Up and Down pick, Tab or Enter puts the picked
      # entry's full chain on the line (Enter again runs it), Esc closes the
      # list until the word changes.  Only typing or deleting opens it (a
      # chain recalled from history doesn't, so Up goes on through it).  The keys are Reline one-shot bindings
      # held only while the list shows, so Tab, the arrows, and Enter work
      # as before everywhere else (Pry's own completion included); multi-line
      # input reads the line being edited.  The plain console and the tiled
      # screen's REPL share it (both are Reline).  Installed by
      # UI::Completion.install (bin/sound.rb).
      module LibraryPopup
        # The keys the list takes while it shows (Reline keystrokes).
        KEYS = {
          up: "\e[A".bytes, down: "\e[B".bytes, up_app: "\eOA".bytes, down_app: "\eOB".bytes,
          tab: [9], enter: [13], escape: [27], page_up: "\e[5~".bytes, page_down: "\e[6~".bytes,
        }.freeze

        # The rows the list shows at once.
        LIMIT = 10

        # The most entries listed: the list scrolls through them (Up, Down,
        # PageUp, PageDown, with a scrollbar), so a head's every entry can
        # be found without knowing its name (followups-1; the maintainer,
        # 2026-11-21: "Can the autocomplete scroll beyond the few items
        # listed?"; L.gen. has 17, L.inst.a 62, L. 198).
        MAX = 250

        # The dialog's state (Reline gives the proc this context): the word
        # it lists for, the picked row, the word Esc closed it for.
        State = Struct.new(:word, :pointer, :closed, :list, :finder)

        PROC = -> { LibraryPopup.render(self) }

        module_function

        def install
          return false unless defined?(::Reline) && ::Reline.respond_to?(:add_dialog_proc)
          ::Reline.add_dialog_proc(:mb_library, PROC, State.new(nil, 0, nil, nil, Library::Finder.new))
          true
        end

        # The dialog for Reline's DialogProcScope +scope+ (the proc's self),
        # or nil when nothing is listed.
        def render(scope)
          st = scope.context
          pre, word, post = scope.retrieve_completion_block
          key = scope.key
          trapped = key && key.method_symbol == scope.dialog.name
          if trapped && st.list
            case key_of(key)
            when :up, :up_app then st.pointer = (st.pointer - 1) % st.list.length
            when :down, :down_app then st.pointer = (st.pointer + 1) % st.list.length
            when :page_up then st.pointer = [st.pointer - LIMIT, 0].max
            when :page_down then st.pointer = [st.pointer + LIMIT, st.list.length - 1].min
            when :tab, :enter
              pick(scope, pre, st.list[st.pointer].chain, post)
              st.closed = st.list[st.pointer].chain
              st.list = nil
              return nil
            when :escape
              st.closed = word
              st.list = nil
              return nil
            end
          else
            return close(st) if word.nil? || word == st.closed
            # (Only typing opens it: a line recalled from history or a cursor
            # moved onto a chain kept Up from reaching the next entry;
            # ux-friction-1, the maintainer: "pressing up repeatedly to go
            # through history landed me inside a tab completion menu")
            return close(st) if st.list.nil? && !typed?(key)
            st.closed = nil
            list = LibraryPopup.live { st.finder.candidates(word, limit: MAX) }
            return close(st) unless list
            st.pointer = 0 unless st.word == word && st.list && st.pointer < list.length
            st.word = word
            st.list = list
          end

          # (Enter runs the line when the picked chain is what is typed)
          scope.dialog.trap_key = st.list[st.pointer].chain == word ? KEYS.except(:enter).values : KEYS.values
          scope.dialog.pointer = st.pointer
          x = [scope.cursor_pos.x - word.to_s.length, 0].max
          ::Reline::DialogRenderInfo.new(
            pos: ::Reline::CursorPos.new(x, 0), contents: st.list.map(&:label),
            scrollbar: st.list.length > LIMIT, height: [st.list.length, LIMIT].min, face: :completion_dialog
          )
        rescue StandardError
          nil
        end

        # Runs the block as a live thread (Library::Index#document_entries
        # gives it the last scan's documents, rescanning in the background
        # once that is DOCUMENT_STALE), then puts the thread's flag back:
        # each key typed in a head chain listed the shelves' documents
        # anew, about 200 stats, ~40 ms of typing lag where the checkout is
        # on sshfs (followups-1; the gvl-main-1 report).  Lines the console
        # runs on the same thread still scan fresh.
        def live
          was = Thread.current[:mb_sound_live]
          Thread.current[:mb_sound_live] = true
          yield
        ensure
          Thread.current[:mb_sound_live] = was
        end

        # Reline editing methods that open the list (typing or deleting in
        # the word; everything else, history and cursor moves included,
        # only updates a list already showing).
        def typed?(key)
          sym = key&.method_symbol
          !sym.nil? && (sym == :ed_insert || sym == :ed_quoted_insert || sym.to_s.match?(/delete|kill|rubout/))
        end

        # Which of KEYS +key+ is.
        def key_of(key)
          bytes = key.char.is_a?(String) ? key.char.bytes : Array(key.char)
          KEYS.key(bytes)
        end

        def close(st)
          st.list = nil
          st.word = nil
          nil
        end

        # Replaces the word being typed with +chain+, the cursor after it.
        def pick(scope, pre, chain, post)
          editor = scope.instance_variable_get(:@line_editor)
          before = "#{pre}#{chain}"
          editor.set_current_line("#{before}#{post}", before.bytesize)
        end
      end
    end
  end
end
