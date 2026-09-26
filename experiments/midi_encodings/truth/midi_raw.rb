# Minimal raw SMF parser: returns tracks of events with absolute ticks and byte offsets.
module RawMidi
  def self.vlq(b, i)
    v = 0
    loop { c = b[i]; i += 1; v = (v << 7) | (c & 0x7f); break if c < 0x80 }
    [v, i]
  end

  def self.parse(bytes)
    b = bytes.bytes
    raise 'no MThd' unless b[0, 4].pack('C*') == 'MThd'
    fmt, ntrk, div = b[8, 6].pack('C*').unpack('nnn')
    i = 14
    tracks = []
    ntrk.times do
      raise "no MTrk at #{i}" unless b[i, 4].pack('C*') == 'MTrk'
      len = b[i + 4, 4].pack('C*').unpack1('N')
      i += 8; stop = i + len; t = 0; status = nil; evs = []
      while i < stop
        d, i = vlq(b, i); t += d; off = i
        c = b[i]
        if c == 0xff
          type = b[i + 1]; l, j = vlq(b, i + 2); evs << { t: t, off: off, kind: :meta, type: type, data: b[j, l] }; i = j + l
        elsif c == 0xf0 || c == 0xf7
          l, j = vlq(b, i + 1); evs << { t: t, off: off, kind: :sysex, data: b[j, l] }; i = j + l
        else
          if c >= 0x80 then status = c; i += 1 end
          n = [0xc0, 0xd0].include?(status & 0xf0) ? 1 : 2
          evs << { t: t, off: off, kind: :chan, status: status, cmd: status & 0xf0, ch: status & 0x0f, data: b[i, n] }
          i += n
        end
      end
      tracks << evs
    end
    { format: fmt, division: div, tracks: tracks }
  end

  # Pair note on/off into notes [start, pitch, vel, dur, ch]
  def self.notes(evs)
    open = {}; out = []
    evs.each do |e|
      next unless e[:kind] == :chan
      k, v = e[:data]
      if e[:cmd] == 0x90 && v > 0
        (open[[e[:ch], k]] ||= []) << e
      elsif e[:cmd] == 0x80 || (e[:cmd] == 0x90 && v == 0)
        s = open[[e[:ch], k]]&.shift or next
        out << { start: s[:t], pitch: k, vel: s[:data][1], dur: e[:t] - s[:t], ch: e[:ch] }
      end
    end
    out.sort_by { |n| [n[:start], n[:pitch]] }
  end
end
