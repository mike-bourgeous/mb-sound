module MB
  module Sound
    module Tracker
      # Reads FastTracker 2 Extended Modules (.xm, version 1.04) into a
      # Song with Instruments.
      #
      # Layout (little-endian): "Extended Module: ", the name, 0x1A, the
      # tracker name, the version, then a header (its size, song length,
      # restart order, channels, patterns, instruments, flags (bit 0:
      # linear frequencies), speed, BPM, 256 orders); patterns (a header
      # with the row count and packed size, then cells: a byte with bit 7
      # set says which of note, instrument, volume, effect, parameter
      # follow, else it is the note and all four follow); instruments (a
      # header with the sample count, then a 96-note keymap, volume and pan
      # envelopes of 12 points, their counts, sustain and loop points and
      # flags, auto-vibrato, fadeout), each followed by its 40-byte sample
      # headers (lengths and loops in bytes, volume, finetune, loop type and
      # 16-bit flag, pan, relative note) and the samples' delta-coded data.
      module XMReader
        SIGNATURE = 'Extended Module: '

        # The neutral note of XM note 1 (C-0): C-4 (note 49) is 60.
        NOTE_OFFSET = 11

        module_function

        def match?(bytes)
          bytes.start_with?(SIGNATURE) && bytes.bytesize >= 80
        end

        def read(bytes, name: 'module')
          b = Binary.new(bytes, name: name)
          problems = []
          title = b.text(17, 20, 'the module name')
          tracker = b.text(38, 20)
          version = b.u16le(58)
          problems << "version #{format('%04x', version)} (1.04 is read; older layouts may misread)" if version < 0x0104
          hsize = b.u32le(60, 'the header size')
          song_length = b.u16le(64)
          restart = b.u16le(66)
          channels = b.u16le(68)
          npat = b.u16le(70)
          nins = b.u16le(72)
          flags = b.u16le(74)
          speed = b.u16le(76)
          bpm = b.u16le(78)
          raise FormatError, "#{name}: #{channels} channels (an XM has 1 to 64)" unless channels.between?(1, 64)
          raise FormatError, "#{name}: #{npat} patterns, #{nins} instruments is more than an XM holds" if npat > 256 || nins > 256
          song_length = song_length.clamp(0, 256)
          orders = Array.new(song_length) { |i| b.u8(80 + i, 'the order table') }

          o = 60 + hsize
          patterns = Array.new(npat) {
            plen = b.u32le(o, 'a pattern header')
            rows = b.u16le(o + 5)
            psize = b.u16le(o + 7)
            data = b.clamped(o + plen, psize)
            problems << 'a pattern is truncated' if data.bytesize < psize
            o += plen + psize
            pattern(data, rows.clamp(1, 256), channels)
          }

          samples = []
          instruments = Array.new(nins) { |i|
            isize = b.u32le(o, "instrument #{i + 1}'s header")
            iname = b.text(o + 4, 22)
            count = b.u16le(o + 27)
            if count == 0
              o += isize
              next Instrument.new(name: iname, keymap: Array.new(120) { [nil, nil] })
            end
            shsize = b.u32le(o + 29)
            keys = Array.new(96) { |k| b.u8(o + 33 + k, 'a keymap') }
            vol_pts = Array.new(12) { |k| [b.u16le(o + 129 + k * 4), b.u16le(o + 131 + k * 4)] }
            pan_pts = Array.new(12) { |k| [b.u16le(o + 177 + k * 4), b.u16le(o + 179 + k * 4)] }
            nv = b.u8(o + 225)
            np = b.u8(o + 226)
            vsus, vls, vle, psus, pls, ple = (227..232).map { |k| b.u8(o + k) }
            vtype = b.u8(o + 233)
            ptype = b.u8(o + 234)
            vib = [b.u8(o + 235), b.u8(o + 236), b.u8(o + 237), b.u8(o + 238)]
            fadeout = b.u16le(o + 239)
            o += isize
            heads = Array.new(count) { |k|
              h = o + k * shsize
              { length: b.u32le(h, 'a sample header'), loop_start: b.u32le(h + 4), loop_length: b.u32le(h + 8), volume: [b.u8(h + 12), 64].min,
                finetune: b.s8(h + 13), type: b.u8(h + 14), pan: b.u8(h + 15), relative: b.s8(h + 16), packing: b.u8(h + 17),
                name: b.text(h + 18, 22) }
            }
            o += count * shsize
            first = samples.length
            heads.each { |h|
              raw = b.clamped(o, h[:length])
              problems << "a sample of instrument #{i + 1} is truncated" if raw.bytesize < h[:length]
              o += h[:length]
              samples << sample(h, raw, problems)
            }
            keymap = Array.new(120) { |n|
              k = n - NOTE_OFFSET - 1
              s = k >= 0 && k < 96 ? keys[k] : 0
              s < count ? [first + s, n] : [nil, n]
            }
            Instrument.new(
              name: iname, keymap: keymap, fadeout: fadeout, vibrato: vib[2] > 0 ? vib : nil,
              volume_envelope: envelope(vol_pts, nv, vtype, vsus, vls, vle),
              pan_envelope: envelope(pan_pts, np, ptype, psus, pls, ple)
            )
          }

          Song.new(
            format: :xm, title: title, channels: channels, pans: Array.new(channels, 0.0), samples: samples, instruments: instruments,
            patterns: patterns, orders: orders, restart: restart < song_length ? restart : nil, speed: speed == 0 ? 6 : speed,
            tempo: bpm < 32 ? 125 : bpm, linear: flags & 1 != 0, problems: problems, tracker: tracker
          )
        end

        def envelope(points, n, type, sus, ls, le)
          n = n.clamp(0, 12)
          return nil if n == 0
          pts = points.first(n).map { |x, y| [x, y.clamp(0, 64)] }
          Envelope.new(points: pts, enabled: type & 1 != 0, sustain: type & 2 != 0 && sus < n ? [sus, sus] : nil,
                       loop: type & 4 != 0 && ls <= le && le < n ? [ls, le] : nil)
        end

        def sample(h, raw, problems)
          bits = h[:type] & 16 != 0 ? 16 : 8
          if h[:packing] == 0xAD
            problems << "sample #{h[:name]} is ADPCM-packed (not read)"
            return SampleData.new(name: h[:name], data: [])
          end
          data = Binary.delta(raw, bits)
          div = bits / 8
          frames = data.length
          kind = h[:type] & 3
          ls = h[:loop_start] / div
          le = ls + h[:loop_length] / div
          loop = kind > 0 && h[:loop_length] > 0 && ls < frames ? [ls, [le, frames].min] : nil
          loop = nil if loop && loop[1] - loop[0] < 1
          SampleData.new(name: h[:name], data: frames == 0 ? [] : [data], rate: 8363.0, loop: loop,
                         loop_mode: loop ? (kind == 2 ? :ping_pong : :forward) : nil, volume: h[:volume], finetune: h[:finetune],
                         relative_note: h[:relative], pan: h[:pan], bits: bits)
        end

        # The rows of a packed pattern.
        def pattern(data, rows, channels)
          cells = Array.new(rows) { Array.new(channels) }
          k = 0
          r = 0
          c = 0
          while r < rows && k < data.bytesize
            first = data.getbyte(k)
            k += 1
            note = inst = vol = eff = par = nil
            if first & 0x80 != 0
              (note = data.getbyte(k); k += 1) if first & 1 != 0
              (inst = data.getbyte(k); k += 1) if first & 2 != 0
              (vol = data.getbyte(k); k += 1) if first & 4 != 0
              (eff = data.getbyte(k); k += 1) if first & 8 != 0
              (par = data.getbyte(k); k += 1) if first & 16 != 0
            else
              note = first
              inst, vol, eff, par = data.getbyte(k), data.getbyte(k + 1), data.getbyte(k + 2), data.getbyte(k + 3)
              k += 4
            end
            n = case note
                when nil, 0 then nil
                when 97 then :off
                else note <= 96 ? note + NOTE_OFFSET : nil
                end
            eff = nil if eff == 0 && (par.nil? || par == 0)
            vol = nil if vol.nil? || vol < 0x10
            unless n.nil? && (inst.nil? || inst == 0) && vol.nil? && eff.nil?
              cells[r][c] = Cell.new(note: n, instrument: inst.nil? || inst == 0 ? nil : inst, volume: vol, effect: eff, param: par || 0)
            end
            c += 1
            if c == channels
              c = 0
              r += 1
            end
          end
          Pattern.new(rows: cells)
        end
      end
    end
  end
end
