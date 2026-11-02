module MB
  module Sound
    module Tracker
      # Reads Scream Tracker 3 modules (.s3m, "SCRM") into a Song.
      #
      # Layout (little-endian; "parapointers" are offsets / 16): a 0x60-byte
      # header (title 28, type 16, order/instrument/pattern counts, flags,
      # tracker version, sample format (1 signed, 2 unsigned), "SCRM" at
      # 0x2C, global volume, initial speed and tempo, master volume (bit 7
      # stereo), the default-pan flag (252: a pan table follows), 32 channel
      # settings (0-7 left, 8-15 right, 16+ AdLib, bit 7 off)); the orders
      # (254 marker, 255 end), instrument and pattern parapointers, the pan
      # table; 80-byte instruments (type 1 is a sample: name, a 24-bit data
      # parapointer, length, loop begin and end, volume, flags (1 loop, 2
      # stereo, 4 16-bit), C2Spd: the rate of C-4); patterns packed row by
      # row (a byte per entry: channel in the low 5 bits, then note and
      # instrument (32), volume (64), effect and its value (128); 0 ends a
      # row; notes are octave and semitone nibbles, 254 note cut).
      module S3MReader
        module_function

        def match?(bytes)
          bytes.bytesize >= 0x60 && bytes.byteslice(0x2C, 4) == 'SCRM'
        end

        def read(bytes, name: 'module')
          b = Binary.new(bytes, name: name)
          problems = []
          title = b.text(0, 28, 'the title')
          ordnum = b.u16le(0x20)
          insnum = b.u16le(0x22)
          patnum = b.u16le(0x24)
          flags = b.u16le(0x26)
          cwt = b.u16le(0x28)
          ffi = b.u16le(0x2A)
          gv = b.u8(0x30)
          speed = b.u8(0x31)
          tempo = b.u8(0x32)
          mv = b.u8(0x33)
          dp = b.u8(0x35)
          settings = Array.new(32) { |c| b.u8(0x40 + c, 'the channel settings') }
          raise FormatError, "#{name}: #{ordnum} orders, #{insnum} instruments, #{patnum} patterns is more than an S3M holds" if ordnum > 256 || insnum > 256 || patnum > 256

          o = 0x60
          orders = Array.new(ordnum) { |i| b.u8(o + i, 'the order list') }
          o += ordnum
          ins_ptrs = Array.new(insnum) { |i| b.u16le(o + i * 2, 'the instrument pointers') * 16 }
          o += insnum * 2
          pat_ptrs = Array.new(patnum) { |i| b.u16le(o + i * 2, 'the pattern pointers') * 16 }
          o += patnum * 2
          pan_table = dp == 252 ? Array.new(32) { |c| b.u8(o + c, 'the pan table') } : nil

          # Channels in use: enabled PCM channels (AdLib channels are left
          # out with a problem noted), in file order
          used = (0...32).select { |c| settings[c] < 16 }
          adlib = (0...32).count { |c| settings[c] >= 16 && settings[c] < 32 }
          problems << "#{adlib} AdLib channels aren't played" if adlib > 0
          map = used.each_with_index.to_h
          stereo = mv & 0x80 != 0
          pans = used.map { |c|
            p = settings[c] < 8 ? 3 : 12
            p = pan_table[c] & 15 if pan_table && pan_table[c] & 0x20 != 0
            stereo ? (p / 7.5 - 1.0) : 0.0
          }

          samples = ins_ptrs.each_with_index.map { |ptr, i| sample(b, ptr, i, ffi, problems) }

          patterns = pat_ptrs.each_with_index.map { |ptr, p| pattern(b, ptr, p, map, problems) }

          last = orders.index(255) || orders.length
          Song.new(
            format: :s3m, title: title, channels: used.length, pans: pans, samples: samples, patterns: patterns, orders: orders.first(last),
            restart: nil, speed: speed == 0 || speed == 255 ? 6 : speed, tempo: tempo < 32 ? 125 : tempo, global_volume: gv.clamp(0, 64),
            flags: { amiga_limits: flags & 16 != 0, fast_slides: flags & 64 != 0 || cwt == 0x1300, cwt: cwt },
            problems: problems, tracker: tracker_name(cwt)
          )
        end

        def sample(b, ptr, i, ffi, problems)
          empty = SampleData.new(name: '', data: [])
          return empty if ptr == 0 || ptr + 80 > b.size
          type = b.u8(ptr)
          name = b.text(ptr + 0x30, 28)
          return SampleData.new(name: name, data: []) unless type == 1
          seg = (b.u8(ptr + 0x0D) << 16) | b.u16le(ptr + 0x0E)
          data_at = seg * 16
          length = b.u32le(ptr + 0x10)
          ls = b.u32le(ptr + 0x14)
          le = b.u32le(ptr + 0x18)
          volume = [b.u8(ptr + 0x1C), 64].min
          pack = b.u8(ptr + 0x1E)
          fl = b.u8(ptr + 0x1F)
          c2spd = b.u32le(ptr + 0x20) & 0xFFFF
          c2spd = 8363 if c2spd == 0
          if pack != 0
            problems << "sample #{i + 1} (#{name}) is packed (not read)"
            return SampleData.new(name: name, data: [])
          end
          bits = fl & 4 != 0 ? 16 : 8
          chans = fl & 2 != 0 ? 2 : 1
          bytes_per = bits / 8
          raw = b.clamped(data_at, length * bytes_per * chans)
          problems << "sample #{i + 1} (#{name}) is truncated" if raw.bytesize < length * bytes_per * chans
          unsigned = ffi != 1
          data = Array.new(chans) { |c|
            part = raw.byteslice(c * length * bytes_per, length * bytes_per) || ''.b
            bits == 16 ? Binary.pcm16(part, unsigned: unsigned) : Binary.pcm8(part, unsigned: unsigned)
          }
          data = [] if data[0].empty?
          frames = data.empty? ? 0 : data.map(&:length).min
          data = data.map { |d| d[0...frames] } unless data.empty?
          loop = fl & 1 != 0 && le > ls && le <= frames ? [ls, le] : nil
          SampleData.new(name: name, data: data, rate: c2spd.to_f, loop: loop, loop_mode: loop ? :forward : nil, volume: volume, bits: bits)
        end

        def pattern(b, ptr, p, map, problems)
          rows = Array.new(64) { Array.new(map.length) }
          return Pattern.new(rows: rows) if ptr == 0
          if ptr + 2 > b.size
            problems << "pattern #{p} is past the end of the file (left empty)"
            return Pattern.new(rows: rows)
          end
          len = b.u16le(ptr)
          data = b.clamped(ptr + 2, [len - 2, 0].max)
          k = 0
          row = 0
          while row < 64 && k < data.bytesize
            what = data.getbyte(k)
            k += 1
            if what == 0
              row += 1
              next
            end
            note = inst = vol = eff = info = nil
            if what & 32 != 0
              note = data.getbyte(k)
              inst = data.getbyte(k + 1)
              k += 2
            end
            if what & 64 != 0
              vol = data.getbyte(k)
              k += 1
            end
            if what & 128 != 0
              eff = data.getbyte(k)
              info = data.getbyte(k + 1)
              k += 2
            end
            c = map[what & 31]
            next if c.nil?
            n = case note
                when nil, 255 then nil
                when 254 then :cut
                else (note >> 4) * 12 + (note & 15) + 12
                end
            rows[row][c] = Cell.new(note: n, instrument: inst.nil? || inst == 0 ? nil : inst, volume: vol && vol <= 64 ? vol : nil,
                                    effect: eff.nil? || eff == 0 || eff > 26 ? nil : eff, param: info || 0)
          end
          Pattern.new(rows: rows)
        end

        def tracker_name(cwt)
          case cwt >> 12
          when 1 then "Scream Tracker #{(cwt >> 8) & 15}.#{format('%02x', cwt & 0xFF)}"
          when 2 then 'Imago Orpheus'
          when 3 then 'Impulse Tracker'
          when 4 then 'Schism Tracker'
          when 5 then 'OpenMPT'
          else 'S3M'
          end
        end
      end
    end
  end
end
