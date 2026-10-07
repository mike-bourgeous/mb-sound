#!/usr/bin/env ruby
# Generates spec/test_data/poly_chord.mid: chords with polyphonic key
# pressure (0xA0) on each key, for poly pressure specs and the SQ-80 demo
# renders (bin/synths/sq80_voice.rb).  Each key of a chord gets its own
# pressure curve, so a patch with v.poly_pressure lets every note of the
# chord move on its own.
#
# 120 BPM, 8 bars:
#  1-2. C major (C4 E4 G4): C4 presses in over bar 1, E4 over bar 2, G4
#       pulses twice; all ease off at the end.
#  3-4. A minor (A3 C4 E4 A4): pressure rolls up the chord one key at a
#       time, then back down.
#  5-6. F major 7 (F3 A3 C4 E4) with channel pressure only (0xD0): every
#       note together, for comparing aftertouch kinds.
#  7-8. G (G3 B3 D4 G4) staccato re-strikes with fresh pressure each time.
#
# Usage: ruby spec/test_data/make_poly_chord.rb
require 'midilib'

BPM = 120
seq = MIDI::Sequence.new
tempo = MIDI::Track.new(seq)
tempo.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(BPM))
seq.tracks << tempo
track = MIDI::Track.new(seq)
seq.tracks << track

Q = seq.ppqn
BAR = Q * 4
STEP = Q / 8 # pressure messages every 32nd note

def at(event, time)
  event.time_from_start = time
  event
end

def note(track, number, from, to, velocity: 90)
  track.events << at(MIDI::NoteOn.new(0, number, velocity, 0), from)
  track.events << at(MIDI::NoteOff.new(0, number, 64, 0), to)
end

# Poly pressure on +number+ from +from+ to +to+ ticks, from a block given
# the fraction 0..1 of the way through (0..1 pressure).
def press(track, number, from, to)
  (from..to).step(STEP) do |t|
    v = (yield((t - from).to_f / (to - from)) * 127).round.clamp(0, 127)
    track.events << at(MIDI::PolyPressure.new(0, number, v, 0), t)
  end
end

def channel_press(track, from, to)
  (from..to).step(STEP) do |t|
    v = (yield((t - from).to_f / (to - from)) * 127).round.clamp(0, 127)
    track.events << at(MIDI::ChannelPressure.new(0, v, 0), t)
  end
end

C4, E4, G4, A3, A4, F3, G3, B3, D4 = 60, 64, 67, 57, 69, 53, 55, 59, 62
ramp = ->(f, a, b) { f < a ? 0.0 : f > b ? 1.0 : (f - a) / (b - a) }

# 1-2: C major
t = 0
len = 2 * BAR - Q / 2
[C4, E4, G4].each { |n| note(track, n, t, t + len) }
press(track, C4, t, t + len) { |f| [ramp.(f, 0.05, 0.45), 1 - ramp.(f, 0.85, 1.0)].min }
press(track, E4, t, t + len) { |f| [ramp.(f, 0.5, 0.8), 1 - ramp.(f, 0.85, 1.0)].min }
press(track, G4, t, t + len) { |f| Math.sin(f * 2 * Math::PI * 2).abs * (1 - f) }

# 3-4: A minor, pressure rolling up and down
t = 2 * BAR
chord = [A3, C4, E4, A4]
chord.each { |n| note(track, n, t, t + len) }
chord.each_with_index do |n, i|
  press(track, n, t, t + len) { |f|
    center = 0.15 + i * 0.12
    center2 = 0.95 - i * 0.12
    [Math.exp(-((f - center) / 0.06)**2), Math.exp(-((f - center2) / 0.06)**2)].max
  }
end

# 5-6: F major 7 with channel pressure
t = 4 * BAR
[F3, A3, C4, E4].each { |n| note(track, n, t, t + len) }
channel_press(track, t, t + len) { |f| Math.sin(f * Math::PI) }

# 7-8: G re-strikes
t = 6 * BAR
8.times do |i|
  s = t + i * Q
  [G3, B3, D4, G4].each_with_index do |n, j|
    note(track, n, s, s + Q * 3 / 4, velocity: 70 + i * 6)
    press(track, n, s + STEP, s + Q * 3 / 4 - STEP) { |f| ((i + j) % 4) / 3.0 * Math.sin(f * Math::PI) }
  end
end

track.sort
track.recalc_delta_from_times
File.open(File.join(__dir__, 'poly_chord.mid'), 'wb') { |f| seq.write(f) }
