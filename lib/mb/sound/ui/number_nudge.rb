require 'prism'

module MB
  module Sound
    module UI
      # Finds and steps number literals in a line of console Ruby (the
      # prompt's number nudge, UI::NudgeKeys; repl-scrub-1, 2026-11-21):
      # Prism's tokens, so numbers inside strings, symbols (`:h13`),
      # identifiers (`n8`, `C4`, the `h3:` key), and comments are never
      # touched, while `1` in `1.n8`, both ends of `150..1500`, and `-3` in
      # `h3: -3` are numbers.  Positions are byte offsets, as Reline's.
      #
      # The stepping rule (NumberNudge.step): a number steps by one unit of
      # its last written digit, keeping its type and how it is written:
      #
      #     300   -> 301      (an Integer: 1; coarse 10; fine refused)
      #     0.125 -> 0.126    (a Float: 0.001; coarse 0.010; fine 0.0001,
      #                        which writes one more decimal: 0.1251)
      #     0.19  -> 0.20     (the written decimals stay: never 0.2 or
      #                        0.30000000000000004)
      #     1     -> 0 -> -1  (through zero: the sign comes and goes)
      #     48_000 -> 48_001  (underscores regrouped by thousands)
      #     1.5e3 -> 1.6e3    (the mantissa steps; the exponent stays)
      #     4r, 0.5r, 2i      (suffixes stay: 3/4r's 4r steps to 5r)
      #
      # Hexadecimal, binary, and octal literals are refused (NumberNudge::
      # Refused, with a reason the keys flash).
      module NumberNudge
        # A number literal in a line: byte offsets +start+...+stop+ (the
        # sign included when it belongs to the literal, as in `-3` or
        # `(-10).db`'s `-10.db`) and its +text+.
        Literal = Data.define(:start, :stop, :text) do
          # True if byte offset +pos+ is on the literal or right after it.
          def at?(pos) = pos >= start && pos <= stop
        end

        # A nudge that can't happen here; #message says why (flashed).
        class Refused < StandardError; end

        # Prism token types of number literals.
        NUMBER_TOKENS = %i[
          INTEGER FLOAT INTEGER_RATIONAL FLOAT_RATIONAL
          INTEGER_IMAGINARY FLOAT_IMAGINARY INTEGER_RATIONAL_IMAGINARY FLOAT_RATIONAL_IMAGINARY
        ].freeze

        # A decimal literal: sign, digits, decimals, exponent, suffix.
        DECIMAL = /\A(?<sign>-)?(?<int>\d(?:_?\d)*)(?:\.(?<frac>\d(?:_?\d)*))?(?:(?<e>[eE])(?<esign>[+-]?)(?<exp>\d+))?(?<suffix>r?i?)\z/

        # Step sizes: units of the last written digit (+:fine+ is a unit
        # of one more decimal place).
        SIZES = { normal: 1, coarse: 10, fine: 1 }.freeze

        module_function

        # The number literals in +code+, in order.
        def literals(code)
          out = []
          minus = nil
          Prism.lex(code.to_s).value.each do |(tok, _state)|
            type = tok.type
            if NUMBER_TOKENS.include?(type)
              loc = tok.location
              start = loc.start_offset
              start = minus if minus && minus == start - 1
              out << Literal.new(start, loc.end_offset, code.byteslice(start, loc.end_offset - start))
            end
            minus = type == :UMINUS_NUM ? tok.location.start_offset : nil
          end
          out
        rescue StandardError
          []
        end

        # The literal at byte offset +pos+ (on it or right after it; the
        # one after when +pos+ is between two), or nil.
        def at(code, pos)
          list = literals(code).select { |l| l.at?(pos) }
          list.find { |l| l.start == pos } || list.first
        end

        # The literal after (+dir+ 1) or before (-1) the one at +pos+ (or
        # +pos+ itself when no literal is there), or nil.
        def neighbor(code, pos, dir)
          list = literals(code)
          here = list.find { |l| l.at?(pos) && l.start != pos } || list.find { |l| l.at?(pos) }
          if dir > 0
            from = here ? here.stop : pos
            list.find { |l| l.start >= from && l != here }
          else
            from = here ? here.start : pos
            list.reverse.find { |l| l.stop <= from && l != here }
          end
        end

        # The literal a first nudge with the cursor off every number goes
        # to: the next one after +pos+, else the last before it (nil if
        # the line has none).
        def nearest(code, pos)
          neighbor(code, pos, 1) || neighbor(code, pos, -1)
        end

        # +text+ (a literal's text) stepped +steps+ times (negative: down)
        # by +size+ (:normal, :coarse, :fine).  Raises Refused.
        def step(text, steps, size = :normal)
          m = DECIMAL.match(text)
          raise Refused, "#{text} isn't a decimal number (hex, binary, octal: not nudged)" unless m
          raise Refused, "#{text} is octal in Ruby (not nudged)" if m[:int].match?(/\A0_?\d/)
          raise ArgumentError, "unknown step size #{size.inspect} (#{SIZES.keys.join(', ')})" unless SIZES.key?(size)

          int = m[:int].delete('_')
          frac = m[:frac]&.delete('_')
          if size == :fine
            raise Refused, "#{text} is an Integer: write #{m[:sign]}#{m[:int]}.0#{m[:e] ? "#{m[:e]}#{m[:esign]}#{m[:exp]}" : ''}#{m[:suffix]} for finer steps" unless frac
            frac += '0'
          end
          scale = frac ? frac.length : 0
          units = Integer("#{int}#{frac}", 10) * (m[:sign] ? -1 : 1)
          units += steps * SIZES.fetch(size)

          digits = units.abs.to_s.rjust(scale + 1, '0')
          whole = digits[0...(digits.length - scale)]
          whole = whole.reverse.scan(/\d{1,3}/).join('_').reverse if m[:int].include?('_')
          out = +"#{units < 0 ? '-' : ''}#{whole}"
          out << ".#{digits[-scale..]}" if scale > 0
          out << "#{m[:e]}#{m[:esign]}#{m[:exp]}" if m[:e]
          out << m[:suffix]
        end

        # +code+ with the literal at +pos+ stepped (see #step): a Hash
        # with :code, :pos (the cursor at the same place from the
        # literal's end, so the last digit stays under it), :from and :to
        # (the literal's texts).  Raises Refused when no number is at
        # +pos+.
        def nudge(code, pos, steps, size = :normal)
          lit = at(code, pos) or raise Refused, 'no number at the cursor'
          to = step(lit.text, steps, size)
          stop = lit.start + to.bytesize
          new_pos = (stop - (lit.stop - pos)).clamp(lit.start, stop)
          {
            code: code.byteslice(0, lit.start) + to + code.byteslice(lit.stop..),
            pos: new_pos,
            from: lit.text,
            to: to,
          }
        end
      end
    end
  end
end
