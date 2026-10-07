#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of swarms (Pitch#swarm): unison copies that glide between
# notes each in their own time, so the cloud smears and re-forms at every
# note, at 90 BPM.
#
# 1. Bars 1-6, "deep": a Deep-Note-like opening.  24 saws start scattered
#    in a G3-G4 band (like the THX Deep Note's 200-400 Hz cloud), drift,
#    and glide for 3 to 7 seconds each (with a little overshoot) onto a
#    wide D major chord over five octaves.
# 2. Bars 5-12, "lead": a melodic swarm.  A mono line played by 10 saws
#    whose glide times spread from 40 ms (lowest copy) to 0.6 s (highest),
#    so each note arrives as a smear that tightens into a unison.
# 3. Bars 9-16, "chords": a swarm of open fifths and octaves following a
#    root line; the 15 copies glide to each new root at random speeds
#    (0.1-1.4 s), so the voicing reshapes on every change.
#
# Usage:
#     bin/songs/swarm_song.rb                       # plays live in the background session
#     bin/songs/swarm_song.rb swarm.flac            # renders to a file instead (-f to overwrite)
#     bin/songs/swarm_song.rb -p deep swarm.flac    # one part alone (deep, lead, chords)
#     bin/songs/swarm_song.rb -c 12 swarm.flac      # fewer copies in the opening (CPU)
#     bin/songs/swarm_song.rb --help                # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/swarm_song.rb'
#     swarm_song                                    # live (swarm_song(part: :lead) etc.)
#
# Snippets to try in bin/sound.rb (swarms are unisons, normalized to about
# the loudness of one copy and spread across the stereo field):
#     # Playable swarm from a MIDI keyboard (mono, so every note glides from the last):
#     bg :sw, midi.synth(voices: 1) { |v| v.hz.swarm(10, glide: spread(40.ms..600.ms), drift: 6.cents) * v.amp_env(0.05, 0.3, 0.8, 0.8) } * -6.db
#     # Polyphonic: each voice's copies glide from the voice's last note (glide_mode: :last)
#     bg :sw, midi.synth(voices: 4) { |v| v.hz.swarm(6, glide: 0.05..0.5, overshoot: 0..0.08) * v.amp_env(0.02, 0.3, 0.7, 0.6) } * -6.db
#     # Mod wheel detune, each copy gliding at its own speed (node detunes take Notes settings per copy):
#     bg :sw, midi.synth(voices: 4) { |v| v.hz.unison(7, detune: v.mod * 0.5, spread: 1) { |p, i| p.glide((i + 1) * 30.ms).saw } * v.amp_env } * -6.db
#     # Every key a Deep Note: copies fly in from a band to an open chord
#     bg :sw, midi.synth(voices: 2) { |v| v.hz.swarm(16, chord: [-12, 0, 7, 12, 19, 24], from: G3..G4, glide: 1..3, drift: 10.cents) * v.amp_env(0.5, 0, 1, 2) } * -6.db
#     # A swarm on a sequence, smearing between notes:
#     bg :sq, seq(A2, C3, E3, G3, F3, E3).n4.loop.synth(voices: 1) { |v| v.hz.swarm(8, glide: spread(20.ms..400.ms)) * v.amp_env } * -9.db
#     # The same melody with one shared glide for comparison (every copy arrives together):
#     bg :sq, seq(A2, C3, E3, G3, F3, E3).n4.loop.synth(voices: 1) { |v| v.hz.swarm(8, glide: 200.ms) * v.amp_env } * -9.db
#     # Supersaw mix knob: the side copies at 30% (center copy full)
#     bg :ss, 110.hz.unison(7, detune: 25.cents, mix: 0.3, spread: 1) * -12.db
#     # A drifting cloud on a fixed pitch (no glides on plain pitches)
#     bg :cl, 110.hz.swarm(9, glide: nil, drift: 15.cents) * -12.db
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  SWARM_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render
  # block).  +part+ is :all, :deep, :lead, or :chords, and +copies+ the
  # number of copies in the opening swarm.
  def self.swarm_song(part: :all, copies: 24)
    bpm 90

    # 1. Deep-Note-like opening: one long D held for 6 bars; the copies
    # start in a band, drift, and fly to their chord tones
    deep_clip = seq(D2).len(6.bars)
    deep_chord = [-12, 0, 7, 12, 19, 24, 28, 31, 36]
    deep = deep_clip.synth(voices: 1) { |v|
      v.hz.swarm(
        copies, chord: deep_chord, detune: 8.cents, from: G3..G4, glide: 3.0..7.0, overshoot: 0.0..0.04,
        drift: 12.cents, seed: 7
      ) * v.amp_env(2.5, 0, 1, 3.0)
    }
    deep = deep.filter(:lowpass, cutoff: 5000, quality: 0.6) * 0.6

    # 2. A melodic swarm: glide times spread across the copies
    melody = seq(
      A3.n4, C4.n8, E4.n8, D4.n4.d, rest.n8,
      F4.n4, E4.n8, D4.n8, C4.n2,
      A3.n4, C4.n8, E4.n8, G4.n4, A4.n4,
      F4.n4.d, E4.n8, D4.n4, E4.n4,
    ).legato(0.95).loop
    lead = melody.synth(voices: 1) { |v|
      v.hz.swarm(10, detune: 10.cents, glide: spread(40.ms..600.ms), overshoot: 0.0..0.06, drift: 5.cents, seed: 3) *
        v.amp_env(0.04, 0.4, 0.8, 0.5)
    }
    lead = lead.filter(:lowpass, cutoff: 2800, quality: 0.8) * 0.5

    # 3. Chord swarm following a root line
    roots = seq(D2, Bb1, F2, C2, D2, G1, A1, A1).n2.legato(1).loop
    chords = roots.synth(voices: 1) { |v|
      v.hz.swarm(15, chord: [0, 7, 12, 19, 24], detune: 12.cents, glide: 0.1..1.4, overshoot: 0.0..0.05, drift: 8.cents, seed: 11) *
        v.amp_env(0.3, 0, 1, 2.0)
    }
    chords = chords.filter(:lowpass, cutoff: 1800, quality: 0.7) * 0.45

    master { |mix| mix.reverb(:hall, wet: -12.db).softclip(0.6, 0.98) }

    if part == :all || part == :deep
      bg :deep, deep, fade: 0
      at_bar(5) { stop :deep, fade: 2 } if part == :all
    end

    if part == :lead
      bg :lead, lead, fade: 0
    elsif part == :all
      at_bar(5) { bg :lead, lead, fade: 0 }
      at_bar(12) { stop :lead, fade: 1 }
    end

    if part == :chords
      bg :chords, chords, fade: 0
    elsif part == :all
      at_bar(9) { bg :chords, chords, fade: 0 }
      at_bar(15) { outro fade: 2 }
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: SWARM_SONG_BARS,
      part: [:all, Symbol, '-p', 'The parts to play', [:all, :deep, :lead, :chords]],
      copies: [24, Integer, '-c', 'Copies in the opening swarm', 1..48],
    ) { |p| swarm_song(part: p.part, copies: p.copies) }
  end
end
