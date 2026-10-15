require_relative 'events'

module MB
  module Sound
    module UI
      module Input
        # Turns the bytes a terminal sends into events (Key, Paste, Mouse,
        # Focus, Reply).  Sequences split across reads wait for the rest:
        # #feed returns what is complete, #pending? says something waits,
        # and #flush (after #esc_timeout with no more bytes) emits it as
        # keys, so a lone ESC becomes Key :escape while Alt-x ("\ex" in one
        # read) stays one key.  Every Key keeps the bytes it came from.
        #
        #     d = Input::Decoder.new
        #     d.feed("\e[1;2C")   # => [Key(:right, [:shift])]
        #     d.feed("\e[200~hi\e[201~")  # => [Paste("hi")]
        class Decoder
          # Seconds a lone ESC waits for the rest of a sequence.
          ESC_TIMEOUT = 0.03

          CSI_KEYS = { 'A' => :up, 'B' => :down, 'C' => :right, 'D' => :left, 'H' => :home, 'F' => :end, 'E' => :begin,
                       'P' => :f1, 'Q' => :f2, 'S' => :f4, 'Z' => :tab }.freeze
          TILDE_KEYS = { 1 => :home, 2 => :insert, 3 => :delete, 4 => :end, 5 => :page_up, 6 => :page_down, 7 => :home, 8 => :end,
                         11 => :f1, 12 => :f2, 13 => :f3, 14 => :f4, 15 => :f5, 17 => :f6, 18 => :f7, 19 => :f8, 20 => :f9,
                         21 => :f10, 23 => :f11, 24 => :f12 }.freeze
          SS3_KEYS = { 'A' => :up, 'B' => :down, 'C' => :right, 'D' => :left, 'H' => :home, 'F' => :end,
                       'P' => :f1, 'Q' => :f2, 'R' => :f3, 'S' => :f4, 'M' => :enter }.freeze
          # Kitty keyboard protocol codes for named keys (CSI code u).
          KITTY_KEYS = { 27 => :escape, 13 => :enter, 9 => :tab, 127 => :backspace, 57_399 => '0' }.freeze

          attr_accessor :esc_timeout

          # True while a cursor report is expected (CSI r;c R is then a
          # Reply, not F3 with modifiers).
          attr_accessor :expect_cpr

          def initialize(esc_timeout: ESC_TIMEOUT)
            @esc_timeout = esc_timeout
            @buf = +''.b
            @paste = nil
            @expect_cpr = false
          end

          # True when bytes wait for the rest of a sequence (or a paste is
          # open).
          def pending?
            !@buf.empty? || !@paste.nil?
          end

          # Events from +bytes+ (and what waited from earlier calls).
          def feed(bytes)
            @buf << bytes.b
            out = []
            parse(out, false)
            out
          end

          # Emits what waits as keys (a lone ESC becomes Key :escape; an
          # open paste stays open).
          def flush
            out = []
            parse(out, true)
            out
          end

          private

          def parse(out, final)
            b = @buf
            i = 0
            while i < b.bytesize
              if @paste
                j = b.index("\e[201~", i)
                if j.nil?
                  # Keep a possible start of the end marker for the next read
                  keep = partial_end(b, i)
                  @paste << b.byteslice(i, b.bytesize - i - keep)
                  i = b.bytesize - keep
                  break
                end
                @paste << b.byteslice(i, j - i)
                out << Paste.new(text: utf8(@paste))
                @paste = nil
                i = j + 6
                next
              end

              c = b.getbyte(i)
              if c == 0x1B
                n = escape(b, i, out, final)
                break if n.nil?
                i = n
              elsif c < 0x20 || c == 0x7F
                out << control(c, b.byteslice(i, 1))
                i += 1
              else
                len = utf8_len(c)
                if i + len > b.bytesize
                  break unless final
                  len = b.bytesize - i
                end
                ch = b.byteslice(i, len)
                text = utf8(ch)
                out << Key.new(key: text, mods: text =~ /\A[A-Z]\z/ ? [:shift] : [], bytes: ch)
                i += len
              end
            end
            @buf = b.byteslice(i, b.bytesize - i) || +''.b
            @buf = +''.b if @buf.empty?
          end

          def partial_end(b, i)
            marker = "\e[201~"
            (1..5).reverse_each do |k|
              next if b.bytesize - i < k
              return k if b.byteslice(b.bytesize - k, k) == marker[0, k]
            end
            0
          end

          def utf8(s)
            s.dup.force_encoding(Encoding::UTF_8).scrub('?')
          end

          def utf8_len(c)
            c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1
          end

          def control(c, bytes)
            case c
            when 0x0D then Key.new(key: :enter, bytes: bytes)
            when 0x09 then Key.new(key: :tab, bytes: bytes)
            when 0x7F, 0x08 then Key.new(key: :backspace, bytes: bytes)
            when 0x00 then Key.new(key: ' ', mods: [:ctrl], bytes: bytes)
            when 0x1B then Key.new(key: :escape, bytes: bytes)
            when 0x1C then Key.new(key: '\\', mods: [:ctrl], bytes: bytes)
            when 0x1D then Key.new(key: ']', mods: [:ctrl], bytes: bytes)
            when 0x1E then Key.new(key: '^', mods: [:ctrl], bytes: bytes)
            when 0x1F then Key.new(key: '_', mods: [:ctrl], bytes: bytes)
            else Key.new(key: (c + 0x60).chr, mods: [:ctrl], bytes: bytes)
            end
          end

          def mods_of(m)
            m = m.to_i - 1
            return [] if m <= 0
            MODS.each_with_index.select { |_, k| m[k] == 1 }.map(&:first)
          end

          # Parses an escape at +i+; returns the index after it, or nil to
          # wait for more bytes.
          def escape(b, i, out, final)
            n = b.bytesize
            if i + 1 >= n
              return nil unless final
              out << Key.new(key: :escape, bytes: "\e".b)
              return i + 1
            end

            c = b.getbyte(i + 1)
            case c
            when 0x5B # [
              j = i + 2
              j += 1 while j < n && !(0x40..0x7E).cover?(b.getbyte(j))
              if j >= n
                return nil unless final
                # A broken sequence: ESC as a key, the rest as text
                out << Key.new(key: :escape, bytes: "\e".b)
                return i + 1
              end
              csi(b.byteslice(i + 2, j - i - 2), b.getbyte(j).chr, b.byteslice(i, j - i + 1), out)
              j + 1
            when 0x4F # O
              if i + 2 >= n
                return nil unless final
                out << Key.new(key: 'O', mods: [:alt], bytes: b.byteslice(i, 2))
                return i + 2
              end
              f = b.getbyte(i + 2).chr
              key = SS3_KEYS[f]
              out << (key ? Key.new(key: key, bytes: b.byteslice(i, 3)) : Key.new(key: f, mods: [:alt], bytes: b.byteslice(i, 3)))
              i + 3
            when 0x1B
              # ESC ESC: an Escape key (the second may start a sequence)
              out << Key.new(key: :escape, bytes: "\e".b)
              i + 1
            else
              # Alt + a character or control
              if c < 0x20 || c == 0x7F
                k = control(c, nil)
                out << Key.new(key: k.key, mods: (k.mods + [:alt]).uniq, bytes: b.byteslice(i, 2))
                return i + 2
              end
              len = utf8_len(c)
              if i + 1 + len > n
                return nil unless final
                len = n - i - 1
              end
              ch = utf8(b.byteslice(i + 1, len))
              out << Key.new(key: ch, mods: [:alt], bytes: b.byteslice(i, len + 1))
              i + 1 + len
            end
          end

          def csi(params, final, bytes, out)
            if params == '200' && final == '~'
              @paste = +''.b
              return
            end

            lead = params[0]
            if lead == '<' && (final == 'M' || final == 'm')
              bt, x, y = params[1..].split(';').map(&:to_i)
              action = final == 'm' ? :release : (bt & 32 != 0 ? :drag : :press)
              mods = []
              mods << :shift if bt & 4 != 0
              mods << :alt if bt & 8 != 0
              mods << :ctrl if bt & 16 != 0
              out << Mouse.new(button: bt & ~(4 | 8 | 16 | 32), x: x.to_i - 1, y: y.to_i - 1, action: action, mods: mods)
              return
            end
            if lead == '?'
              case final
              when 'y' then out << Reply.new(kind: :mode, data: params[1..].delete('$').split(';').map(&:to_i))
              when 'c' then out << Reply.new(kind: :device, data: params[1..].split(';').map(&:to_i))
              when 'u' then out << Reply.new(kind: :kitty, data: params[1..].to_i)
              end
              return
            end
            if params.empty? && (final == 'I' || final == 'O')
              out << Focus.new(in: final == 'I')
              return
            end

            nums = params.split(';')
            if final == 'R' && @expect_cpr && nums.length == 2
              out << Reply.new(kind: :cursor, data: nums.map(&:to_i))
              return
            end

            case final
            when '~'
              key = TILDE_KEYS[nums[0].to_i]
              out << Key.new(key: key || :"key#{nums[0]}", mods: mods_of(nums[1]), bytes: bytes)
            when 'u'
              code, m = nums[0].to_s.split(':').first.to_i, nums[1]&.split(':')&.first
              key = KITTY_KEYS[code] || (code >= 32 ? code.chr(Encoding::UTF_8) : (code + 0x60).chr)
              mods = mods_of(m)
              mods << :ctrl if code < 32 && !KITTY_KEYS.key?(code) && !mods.include?(:ctrl)
              out << Key.new(key: key, mods: mods.uniq, bytes: bytes)
            else
              key = CSI_KEYS[final]
              if key
                mods = mods_of(nums[1])
                mods |= [:shift] if final == 'Z'
                out << Key.new(key: key, mods: mods, bytes: bytes)
              elsif final == 'R'
                out << Key.new(key: :f3, mods: mods_of(nums[1]), bytes: bytes)
              else
                out << Key.new(key: :"csi_#{final}", mods: [], bytes: bytes)
              end
            end
          end
        end
      end
    end
  end
end
