module MB
  module Sound
    module Tracker
      # Reads Composer 669 and UNIS 669 files ("if" / "JN"): eight
      # channels, 64-row patterns, and per order entry a speed (ticks per
      # row) and a break row (the last row played).
      #
      # Layout (little-endian): the signature, a 108-byte song message, the
      # sample and pattern counts and the loop order, 128 order entries
      # (255 ends), 128 speeds, 128 break rows; then a 25-byte header per
      # sample (a 13-byte file name, the length, loop start, and loop end),
      # the patterns (64 rows x 8 channels x 3 bytes: a 6-bit note and
      # 6-bit sample number, a 4-bit volume, and an effect nibble with its
      # value; 0xFE in the first byte is a volume without a note, 0xFF no
      # note, 0xFF in the third no effect), and unsigned 8-bit sample data.
      module SixSixNineReader
        # The neutral note of 669 note 0 (669 notes count semitones from
        # there; note 60 plays a sample at its own rate, Song#samples' rate).
        NOTE_OFFSET = 36

        # The sample rate notes play samples at (Hz at note 60).
        RATE = 8363.0

        module_function

        def match?(bytes)
          (bytes.start_with?('if') || bytes.start_with?('JN')) && bytes.bytesize >= 0x1F1 &&
            bytes.getbyte(0x6E) <= 64 && bytes.getbyte(0x6F) <= 128 && bytes.getbyte(0x6F) > 0
        end

        def read(bytes, name: 'module')
          b = Binary.new(bytes, name: name)
          unis = b.slice(0, 2) == 'JN'
          problems = []
          message = Binary.text(b.slice(2, 108, 'the song message'))
          nos = b.u8(0x6E)
          nop = b.u8(0x6F)
          loop_order = b.u8(0x70)
          raw_orders = Array.new(128) { |i| b.u8(0x71 + i, 'the order list') }
          length = raw_orders.index(255) || 128
          orders = raw_orders.first(length)
          tempos = Array.new(128) { |i| b.u8(0xF1 + i, 'the tempo list') }.first(length)
          breaks = Array.new(128) { |i| b.u8(0x171 + i, 'the break list') }.first(length)

          headers = Array.new(nos) { |i|
            o = 0x1F1 + i * 25
            len = b.u32le(o + 13, "sample #{i + 1}'s header")
            ls = b.u32le(o + 17)
            le = b.u32le(o + 21)
            { name: b.text(o, 13), length: len, loop: le > ls && le <= len && le - ls > 2 ? [ls, le] : nil }
          }

          offset = 0x1F1 + nos * 25
          patterns = Array.new(nop) { |p|
            o = offset + p * 0x600
            if o + 0x600 > b.size
              problems << "pattern #{p} is past the end of the file (left empty)"
              next Pattern.new(rows: Array.new(64) { Array.new(8) })
            end
            raw = b.slice(o, 0x600)
            Pattern.new(rows: Array.new(64) { |r|
              Array.new(8) { |c|
                k = (r * 8 + c) * 3
                cell(raw.getbyte(k), raw.getbyte(k + 1), raw.getbyte(k + 2))
              }
            })
          }

          offset += nop * 0x600
          samples = headers.each_with_index.map { |h, i|
            raw = b.clamped(offset, h[:length])
            problems << "sample #{i + 1} (#{h[:name]}) is truncated: #{raw.bytesize} of #{h[:length]} bytes" if raw.bytesize < h[:length]
            offset += h[:length]
            data = Binary.pcm8(raw, unsigned: true)
            loop = h[:loop] && h[:loop][1] <= data.length ? h[:loop] : nil
            SampleData.new(name: h[:name], data: data.empty? ? [] : [data], rate: RATE, loop: loop, loop_mode: loop ? :forward : nil, volume: 64)
          }

          Song.new(
            format: :"669", title: message[0, 36].to_s.strip, channels: 8, pans: Array.new(8) { |c| c.even? ? -1.0 : 1.0 },
            samples: samples, patterns: patterns, orders: orders, restart: loop_order < length ? loop_order : nil, speed: tempos[0] || 4, tempo: 78,
            flags: { tempos: tempos, breaks: breaks, unis: unis, message: message }, problems: problems,
            tracker: unis ? 'UNIS 669' : 'Composer 669'
          )
        end

        # The Cell of one 669 entry (nil if empty).
        def cell(b0, b1, b2)
          effect = b2 == 0xFF ? nil : b2 >> 4
          param = b2 == 0xFF ? 0 : b2 & 15
          case b0
          when 0xFF
            effect.nil? ? nil : Cell.new(effect: effect, param: param)
          when 0xFE
            Cell.new(volume: b1 & 15, effect: effect, param: param)
          else
            Cell.new(note: (b0 >> 2) + NOTE_OFFSET, instrument: ((b0 & 3) << 4 | (b1 >> 4)) + 1, volume: b1 & 15, effect: effect, param: param)
          end
        end
      end
    end
  end
end
