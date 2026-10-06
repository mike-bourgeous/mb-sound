#!/usr/bin/env ruby
# Generates spec/test_data/fm_chain_demo.mid: phrases for
# bin/synths/fm_chain.rb that use the FM-friendly key intervals and mod
# wheel moves the chained synth needs to sound good (the other test files
# don't have them).  In fm_chain the first held note is heard, and each note
# pressed after it frequency-modulates the note before it, so the ORDER of
# the key presses matters; the mod wheel (CC 1) sets the modulation depth.
#
# 100 BPM, one phrase every two bars:
#  1. The user's growly bass: D4, then A4, then G#5, mod wheel at 71 (with a
#     slow dip and swell around it).  Sounds good with chorus and reverb.
#  2. The same keys with D#5 instead of G#5 (user: both behave
#     interestingly): D4, A4, D#5, wheel at 71.
#  3. The G#5 shape a fourth lower: A3, E4, D#5.
#  4. A fifth (3:2): C3 then G3, wheel sweeping 0 -> 100 -> 40.
#  5. Octaves (2:1, 4:1): A2, A3, A4, wheel sweeping up slowly.
#  6. Fourths (4:3): E3, A3, D4, wheel wobbling 30..90.
#  7. Releasing the middle of a chain: D3, A3, E4, then A3 lets go, so E4
#     modulates D3 directly.
#  8. The growly bass again, with a short G#5 retrigger.
#
# Usage: ruby spec/test_data/make_fm_chain_demo.rb
require 'midilib'

BPM = 100
seq = MIDI::Sequence.new
tempo = MIDI::Track.new(seq)
tempo.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(BPM))
seq.tracks << tempo
track = MIDI::Track.new(seq)
seq.tracks << track

Q = seq.ppqn # ticks per quarter note
BAR = Q * 4

def note(track, number, from, to, velocity: 96)
  on = MIDI::NoteOn.new(0, number, velocity, 0)
  on.time_from_start = from
  off = MIDI::NoteOff.new(0, number, 64, 0)
  off.time_from_start = to
  track.events.push(on, off)
end

# Mod wheel values from +from+ to +to+ ticks, every 32nd note, from a block
# given the fraction 0..1 of the way through.
def wheel(track, from, to)
  step = Q / 8
  (from..to).step(step) do |t|
    cc = MIDI::Controller.new(0, 1, yield((t - from).to_f / (to - from)).round.clamp(0, 127), 0)
    cc.time_from_start = t
    track.events << cc
  end
end

D3, A2, C3, E3, G3, A3, D4, E4, A4, DS5, GS5 = 50, 45, 48, 52, 55, 57, 62, 64, 69, 75, 80

t = 0

# 1. Growly bass: D4, A4, G#5 pressed in that order, wheel at 71
wheel(track, t, t + 2 * BAR) { |f| 71 + 10 * Math.sin(f * 2 * Math::PI) * f }
note(track, D4, t, t + 2 * BAR - Q / 4)
note(track, A4, t + Q / 2, t + 2 * BAR - Q / 4)
note(track, GS5, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 2. The same keys with D#5 on top
wheel(track, t, t + 2 * BAR) { |f| 71 + 8 * Math.sin(f * 4 * Math::PI) }
note(track, D4, t, t + 2 * BAR - Q / 4)
note(track, A4, t + Q / 2, t + 2 * BAR - Q / 4)
note(track, DS5, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 3. The G#5 shape a fourth lower
wheel(track, t, t + 2 * BAR) { |_f| 71 }
note(track, A3, t, t + 2 * BAR - Q / 4)
note(track, E4, t + Q / 2, t + 2 * BAR - Q / 4)
note(track, DS5, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 4. A fifth, wheel 0 -> 100 -> 40
wheel(track, t, t + 2 * BAR) { |f| f < 0.6 ? f / 0.6 * 100 : 100 - (f - 0.6) / 0.4 * 60 }
note(track, C3, t, t + 2 * BAR - Q / 4)
note(track, G3, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 5. Octaves, wheel rising slowly
wheel(track, t, t + 2 * BAR) { |f| 20 + 90 * f }
note(track, A2, t, t + 2 * BAR - Q / 4)
note(track, A3, t + Q, t + 2 * BAR - Q / 4)
note(track, A4, t + 2 * Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 6. Fourths, wheel wobbling
wheel(track, t, t + 2 * BAR) { |f| 60 + 30 * Math.sin(f * 6 * Math::PI) }
note(track, E3, t, t + 2 * BAR - Q / 4)
note(track, A3, t + Q / 2, t + 2 * BAR - Q / 4)
note(track, D4, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 7. Releasing the middle of a chain joins its neighbors
wheel(track, t, t + 2 * BAR) { |_f| 64 }
note(track, D3, t, t + 2 * BAR - Q / 4)
note(track, A3, t + Q / 2, t + BAR)
note(track, E4, t + Q, t + 2 * BAR - Q / 4)
t += 2 * BAR

# 8. The growly bass again, with a short retriggered G#5
wheel(track, t, t + 2 * BAR) { |f| 71 - 15 * f }
note(track, D4, t, t + 2 * BAR - Q / 4)
note(track, A4, t + Q / 2, t + 2 * BAR - Q / 4)
note(track, GS5, t + Q, t + BAR)
note(track, GS5, t + BAR + Q, t + 2 * BAR - Q / 4, velocity: 80)
t += 2 * BAR

track.sort
track.recalc_delta_from_times
path = File.join(__dir__, 'fm_chain_demo.mid')
File.open(path, 'wb') { |f| seq.write(f) }
puts "Wrote #{path}: #{t / BAR} bars at #{BPM} BPM (#{(t / BAR * 4 * 60.0 / BPM).round(1)} s)"
