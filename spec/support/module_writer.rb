# A tiny tracker module writer for specs (tracker-1): builds MOD, 669,
# S3M, XM, and IT files from plain Hashes, so specs never need real
# modules (the maintainer's are private).  Each format writes only what the
# readers read.
#
#     ModuleWriter.mod(path, samples: [{ name: 'saw', data: [...floats...], volume: 64, loop: [100, 400] }],
#       patterns: [[[{ note: 60, sample: 1 }, nil, nil, nil], ...64 rows]], orders: [0])
#
# Cells are Hashes: +note+ (neutral: 60 is the note that plays a sample at
# its base rate; :off, :cut where the format has them), +sample+ (or
# +instrument+; 1-based), +volume+ (the volume column, raw), +effect+ and
# +param+ (the format's numbers: MOD/XM 0-35, S3M/IT letters as Integers
# 1-26 or as Strings 'A'..'Z', 669 0-7).  Patterns are Arrays of rows,
# each an Array of cells (nil for empty) per channel; shorter patterns are
# padded with empty rows to the format's length where it is fixed.
module ModuleWriter
  module_function

  # A pattern of +rows+ empty rows for +channels+ channels, with cells set
  # from +cells+ ({ [row, channel] => cell }).
  def pattern(channels, cells = {}, rows: 64)
    Array.new(rows) { |r| Array.new(channels) { |c| cells[[r, c]] } }
  end

  # A sample's data: +n+ frames of a saw at +period+ frames per cycle.
  def saw(n = 1000, period: 50, level: 0.8)
    Array.new(n) { |i| ((i % period).to_f / period * 2 - 1) * level }
  end

  # A click: one full-scale frame then +n+ - 1 zeros (onsets are easy to
  # find exactly).
  def click(n = 400)
    Array.new(n) { |i| i == 0 ? 0.99 : 0.0 }
  end

  def text(s, n)
    s.to_s.b[0, n].ljust(n, "\0")
  end

  def letter(e)
    e.is_a?(String) ? e.upcase.ord - 64 : e
  end

  # ProTracker MOD (31 samples; +channels+ 4 writes M.K., else nCHN/nnCH).
  def mod(path, samples:, patterns:, orders: [0], title: 'spec mod', channels: 4, restart: 127, signature: nil)
    out = +''.b
    out << text(title, 20)
    31.times { |i|
      s = samples[i] || {}
      data = s[:data] || []
      len = (data.length + 1) / 2
      loop = s[:loop]
      out << text(s[:name] || '', 22)
      out << [len].pack('n')
      out << [(s[:finetune] || 0) & 15, s[:volume] || 64].pack('CC')
      out << (loop ? [loop[0] / 2, (loop[1] - loop[0]) / 2] : [0, 1]).pack('nn')
    }
    out << [orders.length, restart].pack('CC')
    out << orders.dup.fill(0, orders.length...128).pack('C128')
    out << (signature || (channels == 4 ? 'M.K.' : (channels < 10 ? "#{channels}CHN" : "#{channels}CH")))
    patterns.each { |pat|
      64.times { |r|
        channels.times { |c|
          cell = pat[r] && pat[r][c]
          out << mod_cell(cell)
        }
      }
    }
    samples.first(31).each { |s|
      data = s[:data] || []
      bytes = data.map { |x| (x.clamp(-1.0, 127 / 128.0) * 128).round & 0xFF }
      bytes << 0 if bytes.length.odd?
      out << bytes.pack('C*')
    }
    File.binwrite(path, out)
    path
  end

  # The ProTracker period of neutral +note+ (60 is 428).
  def mod_period(note)
    i = note - MB::Sound::Tracker::ModReader::FIRST_NOTE
    MB::Sound::Tracker::ModReader::PERIODS.fetch(i)
  end

  def mod_cell(cell)
    return [0, 0, 0, 0].pack('C4') if cell.nil?
    period = cell[:period] || (cell[:note] ? mod_period(cell[:note]) : 0)
    s = cell[:sample] || 0
    e = cell[:effect] || 0
    pr = cell[:param] || 0
    [(s & 0xF0) | (period >> 8), period & 0xFF, ((s & 15) << 4) | e, pr].pack('C4')
  end
end

module ModuleWriter
  module_function

  # Composer 669 (8 channels, 64-row patterns): +tempos+ and +breaks+ per
  # order entry (ticks per row, the last row played), +loop+ the order a
  # finished song loops to.  Notes are neutral (the reader's: 669 note +
  # SIX_SIX_NINE_OFFSET), volumes 0..15 in +volume+.
  def six_six_nine(path, samples:, patterns:, orders: [0], tempos: nil, breaks: nil, loop: 0, message: 'spec 669', unis: false)
    out = +''.b
    out << (unis ? 'JN' : 'if')
    out << text(message, 108)
    out << [samples.length, patterns.length, loop].pack('CCC')
    out << orders.dup.fill(255, orders.length...128).pack('C128')
    out << (tempos || [4] * orders.length).dup.fill(4, orders.length...128).pack('C128')
    out << (breaks || [63] * orders.length).dup.fill(63, orders.length...128).pack('C128')
    samples.each { |s|
      data = s[:data] || []
      loop = s[:loop]
      out << text(s[:name] || '', 13)
      out << [data.length, loop ? loop[0] : 0, loop ? loop[1] : 0xFFFFF].pack('VVV')
    }
    patterns.each { |pat|
      64.times { |r|
        8.times { |c|
          out << six_six_nine_cell(pat[r] && pat[r][c])
        }
      }
    }
    samples.each { |s| out << (s[:data] || []).map { |x| ((x.clamp(-1.0, 127 / 128.0) * 128).round + 128) & 0xFF }.pack('C*') }
    File.binwrite(path, out)
    path
  end

  def six_six_nine_cell(cell)
    return [0xFF, 0, 0xFF].pack('C3') if cell.nil?
    e = cell[:effect].nil? ? 0xFF : (cell[:effect] << 4) | (cell[:param] || 0)
    if cell[:note]
      n = cell[:note] - MB::Sound::Tracker::SixSixNineReader::NOTE_OFFSET
      i = (cell[:sample] || 1) - 1
      v = cell[:volume] || 15
      [(n << 2) | (i >> 4), ((i & 15) << 4) | v, e].pack('C3')
    elsif cell[:volume]
      [0xFE, cell[:volume], e].pack('C3')
    else
      [0xFF, 0, e].pack('C3')
    end
  end
end

module ModuleWriter
  module_function

  # Pads +out+ to a 16-byte boundary and returns its parapointer.
  def para(out)
    out << "\0" * ((16 - out.bytesize % 16) % 16)
    out.bytesize / 16
  end

  # Scream Tracker 3 (.s3m): +channels+ PCM channels (left, right, ...),
  # +samples+ with +c2spd+, +bits+ 16, +stereo+; cells' notes are neutral,
  # :cut for ^^.  +pans+ (0..15 per channel) writes a pan table.
  def s3m(path, samples:, patterns:, orders: [0], title: 'spec s3m', channels: 4, speed: 6, tempo: 125, global_volume: 64, flags: 0,
          pans: nil, signed: false, stereo: true)
    head = +''.b
    head << text(title, 28) << [0x1A, 16, 0, 0].pack('C4')
    head << [orders.length + 1, samples.length, patterns.length, flags, 0x1320, signed ? 1 : 2].pack('v6')
    head << 'SCRM' << [global_volume, speed, tempo, stereo ? 0xB0 : 0x30, 0, pans ? 252 : 0].pack('C6') << "\0" * 8 << [0].pack('v')
    head << Array.new(32) { |c| c < channels ? (c.even? ? c / 2 : 8 + c / 2) : 255 }.pack('C32')
    head << (orders + [255]).pack('C*')
    ins_at = head.bytesize
    head << "\0\0" * samples.length
    pat_at = head.bytesize
    head << "\0\0" * patterns.length
    head << Array.new(32) { |c| 0x20 | ((pans && pans[c]) || 0) }.pack('C32') if pans
    out = head
    ins_ptrs = []
    data_fix = []
    samples.each { |s|
      ins_ptrs << para(out)
      data = s[:data] || []
      loop = s[:loop]
      fl = (loop ? 1 : 0) | (s[:stereo] ? 2 : 0) | (s[:bits] == 16 ? 4 : 0)
      rec = +''.b
      rec << [1].pack('C') << text(s[:file] || '', 12)
      data_fix << [out.bytesize + rec.bytesize, s]
      rec << [0, 0].pack('Cv')
      rec << [s[:stereo] ? data[0].length : data.length, loop ? loop[0] : 0, loop ? loop[1] : 0, s[:volume] || 64, 0, 0, fl, s[:c2spd] || 8363].pack('VVVCCCCV')
      rec << "\0" * 12 << text(s[:name] || '', 28) << 'SCRS'
      out << rec
    }
    pat_ptrs = patterns.map { |pat|
      ptr = para(out)
      body = +''.b
      64.times { |r|
        (pat[r] || []).each_with_index { |cell, c|
          next if cell.nil?
          what = c
          what |= 32 if cell[:note] || cell[:sample]
          what |= 64 if cell[:volume]
          what |= 128 if cell[:effect]
          body << [what].pack('C')
          if what & 32 != 0
            n = cell[:note]
            nb = n.nil? ? 255 : (n == :cut ? 254 : (((n - 12) / 12) << 4) | ((n - 12) % 12))
            body << [nb, cell[:sample] || 0].pack('CC')
          end
          body << [cell[:volume]].pack('C') if what & 64 != 0
          body << [letter(cell[:effect]), cell[:param] || 0].pack('CC') if what & 128 != 0
        }
        body << "\0"
      }
      out << [body.bytesize + 2].pack('v') << body
      ptr
    }
    data_fix.each { |at, s|
      ptr = para(out)
      out[at, 3] = [ptr >> 16, ptr & 0xFFFF].pack('Cv')
      chans = s[:stereo] ? s[:data] : [s[:data] || []]
      chans.each { |d|
        if s[:bits] == 16
          out << d.map { |x| v = (x.clamp(-1.0, 32767 / 32768.0) * 32768).round; signed ? v : v + 32768 }.pack(signed ? 's<*' : 'v*')
        else
          out << d.map { |x| v = (x.clamp(-1.0, 127 / 128.0) * 128).round; (signed ? v : v + 128) & 0xFF }.pack('C*')
        end
      }
    }
    out[ins_at, ins_ptrs.length * 2] = ins_ptrs.pack('v*')
    out[pat_at, pat_ptrs.length * 2] = pat_ptrs.pack('v*')
    File.binwrite(path, out)
    path
  end
end
