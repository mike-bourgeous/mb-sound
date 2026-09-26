require_relative 'midi_raw'
require 'base64'
# Usage: ruby truth/make.rb [input.mid [output_dir]]
# Writes each encoding into output_dir/<encoding>/ (default runs/); with no
# arguments also writes truth/answers.txt and truth/expected_bass_up2.mid.
src = ARGV[0] || 'truth/demo.mid'
dst = ARGV[1] || 'runs'
Dir.chdir(File.join(__dir__, '..'))
raw = File.binread(src)
m = RawMidi.parse(raw)
names = %w[C C# D D# E F F# G G# A A# B]
nm = ->(k) { "#{names[k % 12]}#{k / 12 - 1}" }
%w[hex braille emoji base64 events notes].each { |d| Dir.mkdir(dst + '/' + d) unless Dir.exist?(dst + '/' + d) }
File.write(dst + '/hex/demo.hex.txt', raw.bytes.each_slice(16).each_with_index.map { |r, i| format('%06x  ', i * 16) + r.map { |x| format('%02x', x) }.join(' ') }.join("\n") + "\n")
File.write(dst + '/braille/demo.braille.txt', raw.bytes.map { |x| (0x2800 + x).chr('UTF-8') }.each_slice(64).map(&:join).join("\n") + "\n")
File.write(dst + '/emoji/demo.emoji.txt', raw.bytes.map { |x| (0x1F300 + x).chr('UTF-8') }.each_slice(32).map(&:join).join("\n") + "\n")
File.write(dst + '/base64/demo.b64.txt', Base64.encode64(raw))
# midicsv-like
lines = ["0, 0, Header, #{m[:format]}, #{m[:tracks].size}, #{m[:division]}"]
m[:tracks].each_with_index do |evs, ti|
  tn = ti + 1
  lines << "#{tn}, 0, Start_track"
  evs.each do |e|
    case e[:kind]
    when :meta
      case e[:type]
      when 0x03 then lines << "#{tn}, #{e[:t]}, Title_t, \"#{e[:data].pack('C*').delete("\0")}\""
      when 0x51 then lines << "#{tn}, #{e[:t]}, Tempo, #{e[:data].inject(0) { |a, x| a * 256 + x }}"
      when 0x58 then lines << "#{tn}, #{e[:t]}, Time_signature, #{e[:data].join(', ')}"
      when 0x2f then lines << "#{tn}, #{e[:t]}, End_track"
      else lines << "#{tn}, #{e[:t]}, Meta_#{format('%02x', e[:type])}, #{e[:data].join(' ')}"
      end
    when :sysex then lines << "#{tn}, #{e[:t]}, System_exclusive, #{e[:data].size}, #{e[:data].join(', ')}"
    when :chan
      d = e[:data]
      s = case e[:cmd]
          when 0x90 then "Note_on_c, #{e[:ch]}, #{d[0]}, #{d[1]}"
          when 0x80 then "Note_off_c, #{e[:ch]}, #{d[0]}, #{d[1]}"
          when 0xb0 then "Control_c, #{e[:ch]}, #{d[0]}, #{d[1]}"
          when 0xc0 then "Program_c, #{e[:ch]}, #{d[0]}"
          when 0xe0 then "Pitch_bend_c, #{e[:ch]}, #{d[0] | (d[1] << 7)}"
          else "Chan_#{e[:cmd].to_s(16)}, #{e[:ch]}, #{d.join(', ')}"
          end
      lines << "#{tn}, #{e[:t]}, #{s}"
    end
  end
end
lines << '0, 0, End_of_file'
File.write(dst + '/events/demo.csv', lines.join("\n") + "\n")
# note list: one line per note, beats as rationals (960 ppq), durations in beats, grouped by track
out = ["# Synth Demo 1 - 90 bpm, 4/4, 960 ticks per beat; times and lengths in beats (quarter notes) from start; pitch names use C4 = MIDI 60; CC/pitch bend omitted"]
m[:tracks].each_with_index do |evs, ti|
  title = evs.find { |e| e[:kind] == :meta && e[:type] == 3 }&.dig(:data)&.pack('C*')&.delete("\0")
  ns = RawMidi.notes(evs)
  next if ns.empty?
  out << "track #{ti + 1} #{title.inspect} channel #{ns.first[:ch]}"
  ns.each do |n|
    b = Rational(n[:start], 960); du = Rational(n[:dur], 960)
    out << "  #{b.denominator == 1 ? b.to_i : b} #{nm[n[:pitch]]} v#{n[:vel]} len #{du.denominator == 1 ? du.to_i : du}"
  end
end
File.write(dst + '/notes/demo.notes.txt', out.join("\n") + "\n")
exit if ARGV[1]
# Ground truth
bass = RawMidi.notes(m[:tracks][2]); sax = RawMidi.notes(m[:tracks][3])
File.write('truth/answers.txt', <<~T)
  bass first 12 (start_tick pitch vel dur_ticks):
  #{bass.first(12).map { |n| "#{n[:start]} #{n[:pitch]} #{n[:vel]} #{n[:dur]}" }.join("\n")}
  sax notes: #{sax.size}  lowest #{sax.map { |n| n[:pitch] }.min}  highest #{sax.map { |n| n[:pitch] }.max}
  note totals per track: #{m[:tracks].map { |t| RawMidi.notes(t).size }}
  note-off styles: #{m[:tracks].flat_map { |t| t.select { |e| e[:kind] == :chan && [0x80, 0x90].include?(e[:cmd]) }.map { |e| e[:cmd] == 0x80 ? '80' : (e[:data][1] == 0 ? '90v0' : '90') } }.tally}
  running status used: #{m[:tracks].any? { |t| t.each_cons(2).any? { |a, b| b[:kind] == :chan && raw.getbyte(b[:off]) < 0x80 } }}
T
# expected edit: bass +2
bytes = raw.bytes.dup
m[:tracks][2].each { |e| bytes[e[:off] + (raw.getbyte(e[:off]) >= 0x80 ? 1 : 0)] += 2 if e[:kind] == :chan && [0x80, 0x90].include?(e[:cmd]) }
File.binwrite('truth/expected_bass_up2.mid', bytes.pack('C*'))
