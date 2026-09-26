#!/usr/bin/env ruby
# Writes one Markdown file per representation of the demo MIDI file, for the
# MIDI encoding experiment write-up (see README.md).  Run from any directory:
#   ruby experiments/midi_encodings/make_md.rb

require_relative 'truth/midi_raw'

Dir.chdir(__dir__)

raw = File.binread('truth/demo.mid')
midi = RawMidi.parse(raw)

# Annotated dump of the first `count` bytes: offset, bytes, meaning.
def annotate(raw, midi, count)
  b = raw.bytes
  rows = [
    [0, 4, 'MThd chunk id'], [4, 4, 'header length = 6'],
    [8, 2, "format #{midi[:format]}"], [10, 2, "#{midi[:tracks].size} tracks"],
    [12, 2, "#{midi[:division]} ticks per quarter note"],
  ]
  i = 14
  midi[:tracks].each_with_index do |evs, ti|
    break if i >= count
    rows << [i, 4, "MTrk chunk id (track #{ti + 1})"]
    rows << [i + 4, 4, "track length = #{b[i + 4, 4].pack('C*').unpack1('N')}"]
    prev_end = i + 8
    prev_t = 0
    evs.each do |e|
      break if prev_end >= count
      rows << [prev_end, e[:off] - prev_end, "delta time #{e[:t] - prev_t}"]
      len = next_len(b, e)
      desc = describe(e, b[e[:off]] < 0x80)
      rows << [e[:off], len, desc]
      prev_end = e[:off] + len
      prev_t = e[:t]
    end
    i += 8 + b[i + 4, 4].pack('C*').unpack1('N')
  end
  rows.select { |o, _, _| o < count }.map { |o, l, d|
    format('%06x  %-24s %s', o, b[o, l].map { |x| format('%02x', x) }.join(' '), d)
  }.join("\n")
end

def next_len(b, e)
  case e[:kind]
  when :meta
    j = e[:off] + 2
    j += 1 while b[j] >= 0x80
    (j + 1 - e[:off]) + e[:data].size
  when :sysex
    j = e[:off] + 1
    j += 1 while b[j] >= 0x80
    (j + 1 - e[:off]) + e[:data].size
  else
    (b[e[:off]] >= 0x80 ? 1 : 0) + e[:data].size
  end
end

NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

def describe(e, running)
  case e[:kind]
  when :meta
    case e[:type]
    when 0x03 then "meta: track name #{e[:data].pack('C*').inspect}"
    when 0x51 then "meta: tempo #{e[:data].inject(0) { |a, x| a * 256 + x }} us/quarter"
    when 0x58 then "meta: time signature #{e[:data].inspect}"
    when 0x2f then 'meta: end of track'
    else "meta 0x#{e[:type].to_s(16)}"
    end
  when :sysex then 'sysex'
  else
    d = e[:data]
    rs = running ? ' (running status)' : ''
    case e[:cmd]
    when 0x90 then "note on ch#{e[:ch]} #{NAMES[d[0] % 12]}#{d[0] / 12 - 1} (#{d[0]}) vel #{d[1]}#{rs}"
    when 0x80 then "note off ch#{e[:ch]} #{NAMES[d[0] % 12]}#{d[0] / 12 - 1} (#{d[0]}) vel #{d[1]}#{rs}"
    when 0xb0 then "control change ch#{e[:ch]} cc#{d[0]} = #{d[1]}#{rs}"
    when 0xc0 then "program change ch#{e[:ch]} #{d[0]}#{rs}"
    when 0xe0 then "pitch bend ch#{e[:ch]} #{d[0] | (d[1] << 7)}#{rs}"
    else "channel msg 0x#{e[:cmd].to_s(16)}#{rs}"
    end
  end
end

reps = [
  ['01-hex', 'Hex dump', 'runs/hex/demo.hex.txt', 'text',
   'The raw bytes as two-digit hex values, 16 per line, each line prefixed with its byte offset.  ' \
   'About one token per byte.  Readable by anyone who knows the SMF spec, but variable-length ' \
   'delta times and running status make hand decoding slow and error-prone.'],
  ['02-braille', 'Braille bytes', 'runs/braille/demo.braille.txt', 'text',
   'One character per byte: byte `b` becomes U+2800+b in the Unicode Braille Patterns block, ' \
   'which has exactly 256 characters.  The eight dots map to the eight bits, so it is in a sense ' \
   'a "visual binary" encoding.  Newlines every 64 characters are not data.'],
  ['03-emoji', 'Emoji bytes', 'runs/emoji/demo.emoji.txt', 'text',
   'One pictograph per byte: byte `b` becomes U+1F300+b in the Miscellaneous Symbols and ' \
   'Pictographs block, which has exactly 256 assigned characters (0x00 = 🌀, 0x4D = 🍍, ' \
   '0xFF = 🏿).  Newlines every 32 characters are not data.'],
  ['04-base64', 'Base64', 'runs/base64/demo.b64.txt', 'text',
   'Standard base64 (60 characters per line).  Each character carries 6 bits, so byte boundaries ' \
   'only line up every 4 characters.'],
  ['05-event-csv', 'midicsv-style event list', 'runs/events/demo.csv', 'csv',
   'Every event of every track, one per line: track number, absolute tick, event type, ' \
   'parameters (modeled on the `midicsv` tool).  Lossless for this file.  Note on and note off ' \
   'are separate lines that have to be paired up to get durations.'],
  ['06-note-list', 'Note list', 'runs/notes/demo.notes.txt', 'text',
   'One line per note: start in beats (exact rational), pitch name, velocity, length in beats.  ' \
   'Lossy on purpose: controller changes and pitch bends are dropped.  Closest to the ' \
   'mb-sound `seq` DSL.  Note the unquantized bass part (e.g. `1921/120`), played in live.'],
]

reps.each do |file, title, src, lang, desc|
  body = File.read(src)
  md = +"# MIDI as text: #{title}\n\n"
  md << "#{desc}\n\n"
  md << "Source: `Synth Demo 1.mid` by Mike Bourgeous (#{raw.bytesize} bytes, format #{midi[:format]}, " \
        "#{midi[:tracks].size} tracks, #{midi[:division]} ticks per quarter note).  This encoding: " \
        "#{body.bytesize} bytes of UTF-8, #{body.chars.size} characters.\n\n"
  md << "## First lines\n\n```#{lang}\n#{body.lines.first(8).join}```\n\n"
  md << "## Full file\n\n<details><summary>Show all #{body.lines.size} lines</summary>\n\n"
  md << "```#{lang}\n#{body}```\n\n</details>\n"
  File.write("#{file}.md", md)
end

md = +"# MIDI as text: annotated hex dump\n\n"
md << "What the first bytes of the file mean, decoded by `truth/midi_raw.rb`.  This is the " \
      "decoding that every raw-byte encoding (hex, Braille, emoji, base64) asks the reader to do in their head.\n\n"
md << "```text\n#{annotate(raw, midi, 0x70)}\n```\n"
File.write('00-annotated-hex.md', md)

puts Dir['*.md'].sort
