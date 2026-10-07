#!/usr/bin/env ruby
# Generates spec/test_data/long_notes.mid: long held notes (4-8 s) with
# some overlap, a chord, and a couple of pitch ranges, so slow modulation
# (e.g. the noise LFO scanning the table in bin/wavetable_pr_example.rb,
# its sweeps and scan wraps) is clearly audible within each note.  The
# other test files have short notes.
#
# 60 BPM (one beat per second), 28 s:
#  0-6 s    C4 alone
#  6.5-12.5 G4, with E4 from 10 s to 15 s (overlapping 2.5 s)
#  15.5-19.5 a C major chord, C5 E5 G5 struck together
#  20-28 s  C3 for 8 s, with A3 from 23 s to 27 s on top
#
# Usage: ruby spec/test_data/make_long_notes.rb
require 'midilib'

BPM = 60
seq = MIDI::Sequence.new
tempo = MIDI::Track.new(seq)
tempo.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(BPM))
seq.tracks << tempo
track = MIDI::Track.new(seq)
seq.tracks << track

Q = seq.ppqn # ticks per quarter note (one second at 60 BPM)

# A note from +from+ to +to+ seconds.
def note(track, number, from, to, velocity: 96)
  on = MIDI::NoteOn.new(0, number, velocity, 0)
  on.time_from_start = (from * Q).round
  off = MIDI::NoteOff.new(0, number, 64, 0)
  off.time_from_start = (to * Q).round
  track.events.push(on, off)
end

C3, A3, C4, E4, G4, C5, E5, G5 = 48, 57, 60, 64, 67, 72, 76, 79

note(track, C4, 0, 6)
note(track, G4, 6.5, 12.5)
note(track, E4, 10, 15, velocity: 80)
note(track, C5, 15.5, 19.5)
note(track, E5, 15.5, 19.5, velocity: 88)
note(track, G5, 15.5, 19.5, velocity: 80)
note(track, C3, 20, 28, velocity: 110)
note(track, A3, 23, 27, velocity: 80)

track.sort
track.recalc_delta_from_times
path = File.join(__dir__, 'long_notes.mid')
File.open(path, 'wb') { |f| seq.write(f) }
puts "Wrote #{path}: 28 s at #{BPM} BPM"
