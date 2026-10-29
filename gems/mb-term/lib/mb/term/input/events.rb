module MB
  module Term
    # What the terminal's input becomes (Input::Decoder): keys, pastes,
    # mouse reports, focus changes, and replies to queries.  Generic (no
    # MB::Sound types).
    module Input
      # Modifier names, in the order of the xterm modifier bits.
      MODS = %i[shift alt ctrl meta].freeze

      # Key event types (the kitty keyboard protocol's 1, 2, 3).
      KEY_TYPES = %i[press repeat release].freeze

      # A key: +key+ is a one-character String for text ('a', 'Z', '中')
      # or a Symbol for named keys (:up, :enter, :escape, :f5, ...), with
      # +mods+ (sorted Symbols from MODS) and the +bytes+ the terminal
      # sent (forwarded unchanged to the REPL).  Keymaps compare #chord
      # (key and mods), never bytes.  +type+ is :press, or :repeat or
      # :release where the terminal reports them (the kitty keyboard
      # protocol's event types, flag 2); legacy terminals send presses
      # only, autorepeats included.
      #
      #     Key.of(:right, :shift)    Key.of(']', :ctrl)    Key.of('z')
      #     Key.of('z', type: :release)
      Key = Data.define(:key, :mods, :bytes, :type) do
        def initialize(key:, mods: [], bytes: nil, type: :press)
          super(key: key, mods: mods.sort.freeze, bytes: bytes, type: type)
        end

        # Control characters given as Strings and the key names they
        # mean (`Key.of("\t")` is Tab: panel round 2, M12 drove step
        # entry with "\t" and its keys went to notes).
        CONTROL_NAMES = { "\t" => :tab, "\r" => :enter, "\n" => :enter, "\e" => :escape, "\x7f" => :backspace }.freeze

        def self.of(key, *mods, bytes: nil, type: :press)
          key = CONTROL_NAMES.fetch(key, key) if key.is_a?(String)
          new(key: key, mods: mods, bytes: bytes, type: type)
        end

        def press? = type == :press
        def repeat? = type == :repeat
        def release? = type == :release

        # [key, mods]: what keymaps look up.
        def chord
          [key, mods]
        end

        # True for a printable character without ctrl/alt/meta.
        def text?
          key.is_a?(String) && (mods - [:shift]).empty?
        end

        def to_s
          s = [*mods, key].join('-')
          type == :press ? s : "#{s} (#{type})"
        end
      end

      # A bracketed paste: the pasted +text+ as one event (so a paste
      # never triggers NAV keys).
      Paste = Data.define(:text)

      # An SGR mouse report: +button+ (0 left, 1 middle, 2 right, 64/65
      # wheel up/down), +x+/+y+ 0-based cells, +action+ :press, :release,
      # or :drag, +mods+.
      Mouse = Data.define(:button, :x, :y, :action, :mods)

      # Terminal focus in (true) or out (false) (?1004).
      Focus = Data.define(:in)

      # A reply to a query: +kind+ :cursor ([row, col], 1-based), :mode
      # ([mode, value] from DECRQM), :device (DA1 parameters), :kitty
      # (the keyboard protocol flags), with +data+.
      Reply = Data.define(:kind, :data)

      # What keys, MIDI, and the command palette all turn into: one
      # stream, so a pad and a key do exactly the same thing.
      Action = Data.define(:name, :args) do
        def self.of(name, *args)
          new(name: name, args: args.freeze)
        end

        def to_s
          args.empty? ? name.to_s : "#{name}(#{args.map(&:inspect).join(', ')})"
        end
      end

      # A mode's key bindings, written as Ruby, with what each does (the
      # key table: the `?` overlay, help pages, and specs read it):
      #
      #     Keymap.new :nav do
      #       group 'Panes'
      #       on '1'..'9', :focus_index, help: 'pick a pane by its number'  # the digit is passed along
      #       on 'z', :zoom, help: 'zoom (again: back)'
      #       on [:right, :shift], :resize, :right, 5, help: 'resize by 5'
      #       doc 'z s x ...', 'notes (handled elsewhere; listed only)'
      #     end
      #
      # Keys are Strings (text), Symbols (:up, :escape, :tab), Ranges of
      # Strings (the key's digit or character is passed as the last
      # argument), Arrays of those, or [key, *mods].  Bindings with the
      # same help text in a group print as one line.
      class Keymap
        # One binding: its keys as written, the chord, the Action's name
        # and arguments, the help text, and the group.
        Binding = Data.define(:keys, :chord, :action, :args, :help, :group)

        attr_reader :name

        def initialize(name, &block)
          @name = name
          @map = {}
          @docs = []
          @group = nil
          instance_exec(&block) if block
        end

        # Starts a group of bindings (a heading in the key table).
        def group(title)
          @group = title
          self
        end

        # Binds +keys+ to Action +action+ with +args+ (+help+: what it
        # does, for the key table).  Returns self.
        # +label+ names the keys in the key table instead (several
        # bindings with one label show once: 'arrows').
        def on(keys, action, *args, help: nil, label: nil)
          seq = (@seq = @seq.to_i + 1)
          each_chord(keys) do |key|
            @map[key.chord] = [action, args, keys.is_a?(Range), help, @group, label || keys, seq]
          end
          self
        end

        # A key-table line for keys handled outside the keymap (note
        # keys, chords a mode reads itself).
        def doc(keys, help)
          @docs << [@group, keys, help, (@seq = @seq.to_i + 1)]
          self
        end

        # Removes the bindings of +keys+.
        def off(keys)
          each_chord(keys) { |key| @map.delete(key.chord) }
          self
        end

        # True if +key+ is bound.
        def bound?(key) = @map.key?(key.chord)

        # The Action for +key+, or nil.
        def [](key)
          action, args, pass = @map[key.chord]
          return nil unless action
          pass ? Action.of(action, *args, key.key =~ /\A\d\z/ ? key.key.to_i : key.key) : Action.of(action, *args)
        end

        # Every binding (Binding), in the order bound.
        def entries
          @map.map { |chord, (a, args, _, help, group, keys)| Binding.new(keys: keys, chord: chord, action: a, args: args, help: help, group: group) }
        end

        # Bindings as {"key" => :action} (for the keys line and help).
        def bindings
          @map.to_h { |(k, mods), (a, _)| [Keymap.chord_name([k, mods]), a] }
        end

        # The key table: [[group, [[keys text, help], ...]], ...], keys
        # with the same help in a group joined ("h j k l"), ranges as
        # "1-9"; bindings without help are left out.
        def help_groups
          groups = {}
          items = @map.each_value.filter_map { |_a, _args, _pass, help, group, keys, seq| [seq, group, keys.is_a?(String) && keys.length > 1 ? keys : Keymap.keys_name(keys), help] if help }
          items += @docs.map { |group, keys, help, seq| [seq, group, keys, help] }
          items.sort_by(&:first).each do |_, group, name, help|
            lines = (groups[group] ||= {})
            (lines[help] ||= []) << name unless lines[help]&.include?(name)
          end
          groups.map { |group, lines| [group || @name.to_s.capitalize, lines.map { |help, names| [names.uniq.reject(&:empty?).join(" "), help] }] }
        end

        def inspect
          "#<MB::Term::Input::Keymap #{@name.inspect} #{@map.length} keys>"
        end

        # Key names as people write them: "Ctrl-W", "S-Tab", "Alt-PgUp",
        # "1-9", "Left".
        NAMES = {
          page_up: 'PgUp', page_down: 'PgDn', escape: 'Esc', enter: 'Enter', tab: 'Tab', backspace: 'BkSp',
          delete: 'Del', insert: 'Ins', left: 'Left', right: 'Right', up: 'Up', down: 'Down', home: 'Home', end: 'End',
        }.freeze
        MOD_NAMES = { shift: 'S', alt: 'Alt', ctrl: 'Ctrl', meta: 'Meta' }.freeze

        # The name of keys as written for #on.
        def self.keys_name(keys)
          return "#{keys.first}-#{keys.last}" if keys.is_a?(Range)
          if keys.is_a?(Array) && keys.length > 1 && keys.drop(1).all? { |m| MODS.include?(m) }
            return chord_name([keys[0], keys.drop(1)])
          end
          return Array(keys).map { |k| keys_name(k) }.join(' ') if keys.is_a?(Array)
          chord_name([keys, []])
        end

        # The name of a [key, mods] chord.
        def self.chord_name((key, mods))
          k = key.is_a?(Symbol) ? (NAMES[key] || key.to_s.capitalize.sub(/\AF(\d)/, 'F\\1')) : key == ' ' ? 'Space' : key
          k = k.upcase if mods.include?(:ctrl) && k.is_a?(String) && k.length == 1
          [*mods.sort_by { |m| MODS.index(m) }.reverse.map { |m| MOD_NAMES[m] }, k].join('-')
        end

        private

        def each_chord(keys)
          chord = keys.is_a?(Array) && keys.length > 1 && keys.drop(1).all? { |m| MODS.include?(m) }
          list = chord ? [keys] : keys.is_a?(Range) ? keys.to_a : Array(keys)
          list.each { |k| yield(k.is_a?(Array) ? Key.of(*k) : Key.of(k)) }
        end
      end
    end
  end
end
