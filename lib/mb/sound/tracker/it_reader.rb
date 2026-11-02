module MB
  module Sound
    module Tracker
      # Reads Impulse Tracker modules (.it, "IMPM") into a Song.
      #
      # Layout (little-endian): a 0xC0-byte header (name, counts of orders,
      # instruments, samples, patterns, the tracker versions, flags (bit 0
      # stereo, 2 instruments, 3 linear slides, 4 old effects, 5 Gxx shares
      # E/F's memory), global and mix volume, initial speed and tempo, 64
      # channel pans (0..64, 100 surround, +128 off) and volumes), then the
      # orders (254 marker, 255 end) and file offsets of the instruments,
      # samples, and patterns.  Instruments ("IMPI", the new format): new
      # note action, duplicate check, fadeout, global volume, default pan,
      # a 120-note keyboard of [note, sample], and volume, pan, and pitch
      # envelopes of up to 25 nodes with loops and sustain loops.  Samples
      # ("IMPS"): global volume, flags (16-bit, stereo, compressed, loops,
      # sustain loops, ping-pong), volume, default pan, length, loop and
      # sustain loop points, C5Speed (the rate of C-5), auto-vibrato, data
      # signed or not, plain or IT 2.14/2.15 compressed (ItCompression).
      # Patterns pack each row as channel bytes with masks that repeat a
      # channel's last note, instrument, volume, or command.
      module ITReader
        module_function

        def match?(bytes)
          bytes.start_with?('IMPM') && bytes.bytesize >= 0xC0
        end

        def read(bytes, name: 'module')
          b = Binary.new(bytes, name: name)
          problems = []
          title = b.text(4, 26, 'the song name')
          ordnum, insnum, smpnum, patnum, cwt, cmwt, flags = Array.new(7) { |i| b.u16le(0x20 + i * 2, 'the header') }
          raise FormatError, "#{name}: #{ordnum} orders, #{insnum} instruments, #{smpnum} samples, #{patnum} patterns is more than an IT holds" if
            ordnum > 256 || insnum > 255 || smpnum > 255 || patnum > 256
          gv = b.u8(0x30)
          speed = b.u8(0x32)
          tempo = b.u8(0x33)
          pans = Array.new(64) { |c| b.u8(0x40 + c) }
          vols = Array.new(64) { |c| b.u8(0x80 + c) }
          o = 0xC0
          orders = Array.new(ordnum) { |i| b.u8(o + i, 'the order list') }
          o += ordnum
          ins_offs = Array.new(insnum) { |i| b.u32le(o + i * 4, 'the instrument offsets') }
          o += insnum * 4
          smp_offs = Array.new(smpnum) { |i| b.u32le(o + i * 4, 'the sample offsets') }
          o += smpnum * 4
          pat_offs = Array.new(patnum) { |i| b.u32le(o + i * 4, 'the pattern offsets') }

          use_instruments = flags & 4 != 0
          problems << 'old-format instruments (before IT 2.00) are read as samples' if use_instruments && cmwt < 0x200
          use_instruments &&= cmwt >= 0x200

          samples = smp_offs.each_with_index.map { |off, i| sample(b, off, i, problems) }
          instruments = use_instruments ? ins_offs.each_with_index.map { |off, i| instrument(b, off, i, problems) } : nil

          patterns = pat_offs.each_with_index.map { |off, p| pattern(b, off, p, problems) }
          # Channels: the highest one any pattern uses (64 at most)
          used = patterns.map { |pt| pt.rows.map { |r| r.rindex { |c| c } || -1 }.max || -1 }.max.to_i + 1
          used = used.clamp(1, 64)
          patterns = patterns.map { |pt| Pattern.new(rows: pt.rows.map { |r| r.first(used) + Array.new([used - r.length, 0].max) }) }
          stereo = flags & 1 != 0
          last = orders.index(255) || orders.length

          Song.new(
            format: :it, title: title, channels: used,
            pans: Array.new(used) { |c| p = pans[c] & 127; stereo && p <= 64 ? p / 32.0 - 1.0 : 0.0 },
            channel_volumes: Array.new(used) { |c| [vols[c], 64].min },
            samples: samples, instruments: instruments, patterns: patterns, orders: orders.first(last), restart: nil,
            speed: speed == 0 ? 6 : speed, tempo: tempo < 32 ? 125 : tempo, global_volume: [gv, 128].min / 2.0,
            linear: flags & 8 != 0,
            flags: { old_effects: flags & 16 != 0, compat_gxx: flags & 32 != 0, cwt: cwt, cmwt: cmwt, muted: (0...used).select { |c| pans[c] >= 128 } },
            problems: problems, tracker: "Impulse Tracker #{format('%x.%02x', cwt >> 8, cwt & 0xFF)}"
          )
        end

        def sample(b, off, i, problems)
          return SampleData.new(name: '', data: []) if off == 0 || off + 0x50 > b.size || b.slice(off, 4) != 'IMPS'
          gvl = [b.u8(off + 0x11), 64].min
          flg = b.u8(off + 0x12)
          vol = [b.u8(off + 0x13), 64].min
          name = b.text(off + 0x14, 26)
          cvt = b.u8(off + 0x2E)
          dfp = b.u8(off + 0x2F)
          length = b.u32le(off + 0x30)
          lb, le, c5, sb, se, ptr = [0x34, 0x38, 0x3C, 0x40, 0x44, 0x48].map { |k| b.u32le(off + k) }
          vib = [b.u8(off + 0x4C), b.u8(off + 0x4D), b.u8(off + 0x4E), b.u8(off + 0x4F)]
          return SampleData.new(name: name, data: []) if flg & 1 == 0 || length == 0
          bits = flg & 2 != 0 ? 16 : 8
          chans = flg & 4 != 0 ? 2 : 1
          signed = cvt & 1 != 0
          data =
            if flg & 8 != 0
              Array.new(chans) { |c|
                at = ptr
                d, at = ItCompression.decompress(b.bytes, ptr, length, bits: bits, it215: cvt & 4 != 0)
                ptr = at
                d
              }
            else
              size = length * bits / 8
              raw = b.clamped(ptr, size * chans)
              problems << "sample #{i + 1} (#{name}) is truncated" if raw.bytesize < size * chans
              Array.new(chans) { |c|
                part = raw.byteslice(c * size, size) || ''.b
                bits == 16 ? Binary.pcm16(part, unsigned: !signed) : Binary.pcm8(part, unsigned: !signed)
              }
            end
          frames = data.map(&:length).min
          return SampleData.new(name: name, data: []) if frames.nil? || frames == 0
          data = data.map { |d| d[0...frames] }
          loop = flg & 16 != 0 && le > lb && lb < frames ? [lb, [le, frames].min] : nil
          sus = flg & 32 != 0 && se > sb && sb < frames ? [sb, [se, frames].min] : nil
          SampleData.new(name: name, data: data, rate: (c5 == 0 ? 8363 : c5).to_f, loop: loop, loop_mode: loop && (flg & 64 != 0 ? :ping_pong : :forward),
                         sustain_loop: sus, sustain_mode: sus && (flg & 128 != 0 ? :ping_pong : :forward), volume: vol, global_volume: gvl,
                         pan: dfp & 128 != 0 ? (dfp & 127).clamp(0, 64) : nil, vibrato: vib[1] > 0 ? vib : nil, bits: bits)
        end

        def instrument(b, off, i, problems)
          empty = Instrument.new(name: '', keymap: Array.new(120) { |n| [nil, n] })
          return empty if off == 0 || off + 0x226 > b.size || b.slice(off, 4) != 'IMPI'
          nna = b.u8(off + 0x11)
          dct = b.u8(off + 0x12)
          dca = b.u8(off + 0x13)
          fadeout = b.u16le(off + 0x14)
          gbv = [b.u8(off + 0x18), 128].min
          dfp = b.u8(off + 0x19)
          name = b.text(off + 0x20, 26)
          keymap = Array.new(120) { |n|
            note = b.u8(off + 0x40 + n * 2)
            s = b.u8(off + 0x41 + n * 2)
            [s == 0 ? nil : s - 1, note < 120 ? note : n]
          }
          envs = [0x130, 0x182, 0x1D4].map { |k| envelope(b, off + k, k == 0x130 ? 0 : -32..32) }
          Instrument.new(name: name, keymap: keymap, volume_envelope: envs[0], pan_envelope: envs[1], pitch_envelope: envs[2], fadeout: fadeout,
                         nna: nna & 3, dct: dct, dca: dca, global_volume: gbv, pan: dfp & 128 == 0 ? dfp.clamp(0, 64) : nil)
        end

        def envelope(b, at, range)
          flg = b.u8(at)
          n = b.u8(at + 1).clamp(0, 25)
          return nil if n == 0
          lpb, lpe, slb, sle = (2..5).map { |k| b.u8(at + k) }
          pts = Array.new(n) { |k| [b.u16le(at + 7 + k * 3), b.s8(at + 6 + k * 3)] }
          pts = pts.map { |x, y| [x, range == 0 ? y.clamp(0, 64) : y.clamp(-32, 32)] }
          Envelope.new(points: pts, enabled: flg & 1 != 0, loop: flg & 2 != 0 && lpb <= lpe && lpe < n ? [lpb, lpe] : nil,
                       sustain: flg & 4 != 0 && slb <= sle && sle < n ? [slb, sle] : nil, filter: flg & 128 != 0)
        end

        def pattern(b, off, p, problems)
          return Pattern.new(rows: Array.new(64) { [] }) if off == 0
          if off + 8 > b.size
            problems << "pattern #{p} is past the end of the file (left empty)"
            return Pattern.new(rows: Array.new(64) { [] })
          end
          len = b.u16le(off)
          nrows = b.u16le(off + 2).clamp(1, 200)
          data = b.clamped(off + 8, len)
          rows = Array.new(nrows) { [] }
          masks = Array.new(64, 0)
          last = Array.new(64) { [nil, nil, nil, nil, 0] }
          k = 0
          r = 0
          while r < nrows && k < data.bytesize
            cv = data.getbyte(k)
            k += 1
            if cv == 0
              r += 1
              next
            end
            c = (cv - 1) & 63
            if cv & 128 != 0
              masks[c] = data.getbyte(k).to_i
              k += 1
            end
            m = masks[c]
            l = last[c]
            note = inst = vol = eff = par = nil
            if m & 1 != 0
              note = l[0] = data.getbyte(k)
              k += 1
            end
            if m & 2 != 0
              inst = l[1] = data.getbyte(k)
              k += 1
            end
            if m & 4 != 0
              vol = l[2] = data.getbyte(k)
              k += 1
            end
            if m & 8 != 0
              eff = l[3] = data.getbyte(k)
              par = l[4] = data.getbyte(k + 1).to_i
              k += 2
            end
            note = l[0] if m & 16 != 0
            inst = l[1] if m & 32 != 0
            vol = l[2] if m & 64 != 0
            (eff = l[3]; par = l[4]) if m & 128 != 0
            n = case note
                when nil then nil
                when 255 then :off
                when 254 then :cut
                when 120..253 then :fade
                else note
                end
            rows[r][c] = Cell.new(note: n, instrument: inst.nil? || inst == 0 ? nil : inst, volume: vol,
                                  effect: eff.nil? || eff == 0 || eff > 26 ? nil : eff, param: par || 0)
          end
          Pattern.new(rows: rows)
        end
      end

      # IT 2.14 and 2.15 sample decompression: blocks of 0x8000 (8-bit)
      # or 0x4000 (16-bit) samples, each a 16-bit byte count and a bit
      # stream read low bit first, of values whose width changes in band:
      # below 7 bits, the top value says a new width follows (3 or 4 bits);
      # from 7 bits to the widest data width, a few values just under the
      # top say the new width; at the widest (9 or 17) a set top bit does.
      # Other values are deltas (IT 2.15: deltas of deltas).
      module ItCompression
        module_function

        # [the samples of +length+ frames at +at+ in +bytes+ (an SFloat),
        # the offset after them].
        def decompress(bytes, at, length, bits: 8, it215: false)
          out = bits == 16 ? Numo::Int16.zeros(length) : Numo::Int8.zeros(length)
          n = 0
          block = bits == 16 ? 0x4000 : 0x8000
          top = bits + 1
          while n < length && at + 2 <= bytes.bytesize
            size = bytes.byteslice(at, 2).unpack1('v')
            data = bytes.byteslice(at + 2, size) || ''.b
            at += 2 + size
            count = [block, length - n].min
            values = block_values(data, count, bits, top, it215)
            out[n...(n + values.length)] = values unless values.empty?
            n += count
          end
          [Numo::SFloat.cast(out) / (bits == 16 ? 32_768.0 : 128.0), at]
        end

        def block_values(data, count, bits, top, it215)
          width = top
          d1 = 0
          d2 = 0
          values = []
          pos = 0 # (bit position)
          total = data.bytesize * 8
          limit = 1 << bits
          half = limit >> 1
          while values.length < count && pos + width <= total
            v = read_bits(data, pos, width)
            pos += width
            if width < 7
              if v == 1 << (width - 1)
                extra = bits == 16 ? 4 : 3
                break if pos + extra > total
                nw = read_bits(data, pos, extra) + 1
                pos += extra
                width = nw < width ? nw : nw + 1
                next
              end
            elsif width < top
              border = ((limit - 1) >> (top - width)) - (bits == 16 ? 8 : 4)
              if v > border && v <= border + (bits == 16 ? 16 : 8)
                nw = v - border
                width = nw < width ? nw : nw + 1
                next
              end
            elsif width == top
              if v & limit != 0
                width = (v + 1) & 0xFF
                next
              end
            else
              break
            end
            # A delta of min(width, bits) bits, sign-extended
            w = [width, bits].min
            v &= (1 << w) - 1
            v -= 1 << w if v >= 1 << (w - 1)
            d1 = ((d1 + v + half) & (limit - 1)) - half
            d2 = ((d2 + d1 + half) & (limit - 1)) - half
            values << (it215 ? d2 : d1)
          end
          values
        end

        # +width+ bits of +data+ from bit +pos+, low bit first.
        def read_bits(data, pos, width)
          byte = pos >> 3
          shift = pos & 7
          need = (shift + width + 7) >> 3
          chunk = 0
          need.times { |i| chunk |= (data.getbyte(byte + i) || 0) << (8 * i) }
          (chunk >> shift) & ((1 << width) - 1)
        end
      end
    end
  end
end
