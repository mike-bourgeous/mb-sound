# Generates spec/test_data/dense_modulated.mid: a worst-case load for synth
# benchmarks (bin/graph_profile.rb): 8-note chords that keep every voice
# busy for 8 s (each chord held 1 s, its notes restruck with new velocities
# every quarter second, overlapping the next chord by an eighth), with the
# mod wheel (CC 1), expression (CC 11), and pitch bend moving every 10 ms,
# so controller nodes never return their constant buffers.
require 'midilib'

seq = MIDI::Sequence.new
track = MIDI::Track.new(seq)
seq.tracks << track
track.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(120))

ppq = seq.ppqn # ticks per quarter note (0.5 s at 120 BPM)
events = []

chords = [
  [36, 48, 55, 60, 64, 67, 71, 74],
  [41, 53, 60, 65, 69, 72, 76, 79],
  [43, 55, 62, 67, 71, 74, 77, 81],
  [38, 50, 57, 62, 65, 69, 72, 76],
]
8.times do |c|
  notes = chords[c % chords.length]
  start = c * 2 * ppq
  4.times do |k|
    t = start + k * ppq / 2
    len = k == 3 ? ppq / 2 + ppq / 4 : ppq / 2 - 10
    notes.each_with_index do |n, i|
      vel = 40 + ((i * 37 + k * 23 + c * 11) % 80)
      events << [t + i, MIDI::NoteOn.new(0, n, vel)]
      events << [t + i + len, MIDI::NoteOff.new(0, n, 0)]
    end
  end
end

# Controllers every 10 ms (ppq / 50 ticks)
step = ppq / 50
(0..(16 * ppq)).step(step) do |t|
  x = t.to_f / ppq
  events << [t, MIDI::Controller.new(0, 1, (64 + 63 * Math.sin(x * 2.1)).round)]
  events << [t, MIDI::Controller.new(0, 11, (100 + 27 * Math.sin(x * 3.3)).round)]
  events << [t, MIDI::PitchBend.new(0, (8192 + 3000 * Math.sin(x * 1.7)).round)]
end

last = 0
events.sort_by.with_index { |(t, _), i| [t, i] }.each do |t, e|
  e.delta_time = t - last
  last = t
  track.events << e
end
track.recalc_times

File.open(File.expand_path('dense_modulated.mid', __dir__), 'wb') { |f| seq.write(f) }
puts "#{events.length} events, #{(last.to_f / ppq / 2).round(2)} s"
