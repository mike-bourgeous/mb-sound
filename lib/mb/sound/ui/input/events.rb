module MB
  module Sound
    module UI
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

          def self.of(key, *mods, bytes: nil, type: :press)
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

        # A mode's key bindings, written as Ruby:
        #
        #     Keymap.new :nav do
        #       on '1'..'9', :focus_index        # the digit is passed along
        #       on 'z', :zoom
        #       on [:right, :shift], :resize, :right, 5
        #     end
        #
        # Keys are Strings (text), Symbols (:up, :escape, :tab), Ranges of
        # Strings (the key's digit or character is passed as the last
        # argument), Arrays of those, or [key, *mods].
        class Keymap
          attr_reader :name

          def initialize(name, &block)
            @name = name
            @map = {}
            instance_exec(&block) if block
          end

          # Binds +keys+ to Action +action+ with +args+.  Returns self.
          def on(keys, action, *args)
            chord = keys.is_a?(Array) && keys.length > 1 && keys.drop(1).all? { |m| MODS.include?(m) }
            list = chord ? [keys] : keys.is_a?(Range) ? keys.to_a : Array(keys)
            list.each do |k|
              key = k.is_a?(Array) ? Key.of(*k) : Key.of(k)
              @map[key.chord] = [action, args, keys.is_a?(Range)]
            end
            self
          end

          # Removes the bindings of +keys+.
          def off(keys)
            Array(keys.is_a?(Range) ? keys.to_a : keys).each do |k|
              key = k.is_a?(Array) ? Key.of(*k) : Key.of(k)
              @map.delete(key.chord)
            end
            self
          end

          # The Action for +key+, or nil.
          def [](key)
            action, args, pass = @map[key.chord]
            return nil unless action
            pass ? Action.of(action, *args, key.key =~ /\A\d\z/ ? key.key.to_i : key.key) : Action.of(action, *args)
          end

          # Bindings as {"key" => :action} (for the keys line and help).
          def bindings
            @map.to_h { |(k, mods), (a, _)| [[*mods, k].join('-'), a] }
          end

          def inspect
            "#<UI::Input::Keymap #{@name.inspect} #{@map.length} keys>"
          end
        end
      end
    end
  end
end
