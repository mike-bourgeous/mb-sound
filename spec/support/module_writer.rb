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
