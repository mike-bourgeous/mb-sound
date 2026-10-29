require_relative 'events'

module MB
  module Term
    module Input
      # Reline's key bindings, read and added without taking keys from the
      # user (pattern D: respect the user's environment).
      #
      # - #user_bound?: whether the user's inputrc (Reline's "additional"
      #   bindings: ~/.inputrc, $INPUTRC) binds a key, in any of its byte
      #   forms; screens skip default keys of their own that are bound
      #   there (the tiles' Alt-PgUp scrolling).
      # - .install_editing_keys: IDE-style editing keys (Ctrl-Backspace
      #   deletes the word before the cursor, Ctrl-Delete the next word,
      #   Ctrl-Shift-Delete to the end of the line), added as Reline
      #   *defaults*, so an inputrc binding of the same sequence wins.
      # - .bind: a Reline function for key sequences (defaults again).
      #
      # Generic: no MB::Sound types.
      module RelineKeys
        # Editing keys: [name, byte sequences, Reline function].  Ctrl-
        # Backspace arrives as ^H in most terminals whose Backspace sends
        # ^? (xterm, Konsole, iTerm2, VTE), and as CSI 127;5u with the
        # kitty protocol (the tiles forward that as ^H); ^H is bound only
        # when the terminal's erase character isn't ^H.
        EDITING_KEYS = [
          ['Ctrl-Backspace', ["\x08"], :ed_delete_prev_word],
          ['Ctrl-Delete', ["\e[3;5~"], :em_delete_next_word],
          ['Ctrl-Shift-Delete', ["\e[3;6~"], :ed_kill_line],
        ].freeze

        # Reline's editing modes the bindings go into.
        KEYMAPS = %i[emacs vi_insert].freeze

        module_function

        # The byte forms a terminal may send for +key+ (a Key): the xterm
        # form, plus ESC + the unmodified key for Alt (Alt-PgUp is "\e[5;3~"
        # or "\e\e[5~").
        def byte_forms(key)
          forms = [Input.legacy_bytes(key)]
          if key.mods.include?(:alt)
            plain = Key.of(key.key, *(key.mods - [:alt]))
            forms << "\e#{Input.legacy_bytes(plain)}"
          end
          forms.reject(&:empty?).uniq
        end

        # True if the user's inputrc binds any byte form of +key+ (or a
        # longer sequence starting with one) in any editing mode.
        # +config+ a Reline::Config (Reline's own by default; it reads
        # the inputrc first if Reline hasn't yet).
        def user_bound?(key, config: default_config)
          return false unless config
          additional = config.instance_variable_get(:@additional_key_bindings) || {}
          byte_forms(key).any? do |bytes|
            seq = bytes.bytes
            additional.each_value.any? { |actor| actor.get(seq) || actor.matching?(seq) }
          end
        end

        # Reline's config once it has read the user's inputrc, else a
        # private Reline::Config that read it (nil without Reline).
        # Never Reline's own #read: Reline sets up its default bindings
        # (bracketed paste, cursor keys) only when it reads the inputrc
        # itself, at its first readline.
        def default_config
          return nil unless defined?(::Reline) && ::Reline.respond_to?(:core)
          c = ::Reline.core.config
          return c if c.loaded?
          ::Reline::Config.new.tap(&:read)
        rescue StandardError
          nil
        end

        # Reline's own config (for adding default bindings; it needn't
        # have read the inputrc yet).
        def reline_config
          defined?(::Reline) && ::Reline.respond_to?(:core) ? ::Reline.core.config : nil
        end

        # Adds EDITING_KEYS as Reline defaults (the inputrc still wins),
        # skipping ^H when it is the terminal's erase character
        # (+erase+: the erase byte, from stty if nil).  Returns the names
        # added.
        def install_editing_keys(config: reline_config, erase: nil)
          return [] unless config
          erase ||= erase_char
          EDITING_KEYS.filter_map do |name, seqs, func|
            seqs = seqs.reject { |s| s == "\x08" && erase == "\x08" }
            next if seqs.empty?
            seqs.each { |s| bind(s, func, config: config) }
            name
          end
        end

        # Binds byte sequence +seq+ to Reline function +func+ as a
        # default in the editing modes.
        def bind(seq, func, config: reline_config)
          return unless config
          KEYMAPS.each { |m| config.add_default_key_binding_by_keymap(m, seq.bytes, func) }
        end

        # The terminal's erase character ("\x7f" or "\x08"), from `stty
        # -a` on the controlling terminal; "\x7f" if it can't tell.
        def erase_char
          @erase ||= begin
            out = File.open('/dev/tty') { |tty| IO.popen(%w[stty -a], in: tty, err: File::NULL, &:read) }
            out.to_s[/erase = (\^.|<undef>)/, 1] == '^H' ? "\x08" : "\x7f"
          rescue StandardError
            "\x7f"
          end
        end
      end
    end
  end
end
