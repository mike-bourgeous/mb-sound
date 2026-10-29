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
      # list until the word changes.  The keys are Reline one-shot bindings
      # held only while the list shows, so Tab, the arrows, and Enter work
      # as before everywhere else (Pry's own completion included); multi-line
      # input reads the line being edited.  The plain console and the tiled
      # screen's REPL share it (both are Reline).  Installed by
      # UI::Completion.install (bin/sound.rb).
      module LibraryPopup
        # The keys the list takes while it shows (Reline keystrokes).
        KEYS = {
          up: "\e[A".bytes, down: "\e[B".bytes, up_app: "\eOA".bytes, down_app: "\eOB".bytes,
          tab: [9], enter: [13], escape: [27],
        }.freeze

        # The most entries listed.
        LIMIT = 10

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
            st.closed = nil
            list = st.finder.candidates(word, limit: LIMIT)
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
            scrollbar: false, height: [st.list.length, LIMIT].min, face: :completion_dialog
          )
        rescue StandardError
          nil
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
