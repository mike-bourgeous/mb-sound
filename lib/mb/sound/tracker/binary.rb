module MB
  module Sound
    module Tracker
      # Bounds-checked reads from a module file's bytes (a binary String):
      # every read past the end raises FormatError naming what was being
      # read, and sample data reads clamp to the file (a truncated sample
      # keeps what is there; the reader notes a problem).
      class Binary
        attr_reader :bytes, :name

        def initialize(bytes, name: 'module')
          @bytes = bytes.b
          @name = name
        end

        def size
          @bytes.bytesize
        end

        # Raises FormatError unless +n+ bytes at +offset+ are in the file.
        def check(offset, n, what)
          return if offset >= 0 && n >= 0 && offset + n <= @bytes.bytesize
          raise FormatError, "#{@name}: #{what} at byte #{offset} (#{n} bytes) is past the end of the file (#{@bytes.bytesize} bytes)"
        end

        def u8(offset, what = 'a byte')
          check(offset, 1, what)
          @bytes.getbyte(offset)
        end

        def s8(offset, what = 'a byte')
          v = u8(offset, what)
          v >= 128 ? v - 256 : v
        end

        def u16le(offset, what = 'a word')
          check(offset, 2, what)
          @bytes.getbyte(offset) | (@bytes.getbyte(offset + 1) << 8)
        end

        def u16be(offset, what = 'a word')
          check(offset, 2, what)
          (@bytes.getbyte(offset) << 8) | @bytes.getbyte(offset + 1)
        end

        def u32le(offset, what = 'a long word')
          check(offset, 4, what)
          @bytes.byteslice(offset, 4).unpack1('V')
        end

        # +n+ bytes at +offset+ as a binary String.
        def slice(offset, n, what = 'data')
          check(offset, n, what)
          @bytes.byteslice(offset, n)
        end

        # Up to +n+ bytes at +offset+ (fewer at the end of the file; empty
        # past it).
        def clamped(offset, n)
          return ''.b if offset >= @bytes.bytesize || n <= 0 || offset < 0
          @bytes.byteslice(offset, n)
        end

        # A text field: +n+ bytes at +offset+ up to the first NUL, with
        # unprintable bytes as spaces and trailing spaces removed.
        def text(offset, n, what = 'a name')
          Binary.text(slice(offset, n, what))
        end

        def self.text(raw)
          raw = raw.split("\0", 2).first.to_s
          raw.bytes.map { |b| b >= 32 && b < 127 ? b.chr : ' ' }.join.rstrip
        end

        # Signed 8-bit PCM as a Numo::SFloat (-1..1).
        def self.pcm8(raw, unsigned: false)
          return Numo::SFloat[] if raw.empty?
          d = Numo::UInt8.from_binary(raw).cast_to(Numo::SFloat)
          unsigned ? (d - 128) / 128.0 : Numo::SFloat.cast(Numo::Int8.from_binary(raw)) / 128.0
        end

        # 16-bit little-endian PCM as a Numo::SFloat (-1..1).
        def self.pcm16(raw, unsigned: false)
          raw = raw.byteslice(0, raw.bytesize & ~1)
          return Numo::SFloat[] if raw.empty?
          if unsigned
            (Numo::UInt16.from_binary(raw).cast_to(Numo::SFloat) - 32768) / 32768.0
          else
            Numo::SFloat.cast(Numo::Int16.from_binary(raw)) / 32768.0
          end
        end

        # Delta-coded signed PCM (XM): each value is the previous plus the
        # stored difference, wrapping at +bits+.
        def self.delta(raw, bits)
          ints = bits == 16 ? Numo::Int16.from_binary(raw.byteslice(0, raw.bytesize & ~1)) : Numo::Int8.from_binary(raw)
          return Numo::SFloat[] if ints.empty?
          sum = Numo::Int64.cast(ints).cumsum
          range = 1 << bits
          half = range / 2
          wrapped = ((sum + half) % range) - half
          Numo::SFloat.cast(wrapped) / half.to_f
        end
      end
    end
  end
end
