#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# An 8-bar demo of unison oscillators (Pitch#unison): a 7-saw "supersaw" pad
# spread across the stereo field and a 3-saw detuned bass, at 100 BPM.
# Options switch the detune layout and the pad's spread for A/B listening,
# and play one part alone.
#
# Usage:
#     bin/songs/unison_song.rb                      # plays live in the background session
#     bin/songs/unison_song.rb song.flac            # renders to a file instead (-f to overwrite)
#     bin/songs/unison_song.rb -l even song.flac    # evenly spaced detunes (more regular beating)
#     bin/songs/unison_song.rb -s 0 song.flac       # a mono pad
#     bin/songs/unison_song.rb -p pad song.flac     # the pad alone (or -p bass)
#     bin/songs/unison_song.rb --help               # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/unison_song.rb'
#     unison_song                                    # live (unison_song(layout: :even, spread: 0) etc.)
#
# Snippets to try in bin/sound.rb (unison mixes are normalized to about the
# loudness of one copy; peaks can pass full scale, so keep them down):
#     bg :ss, 110.hz.unison(7, detune: 25.cents) * -12.db                         # a supersaw (saws by default)
#     bg :ss, 110.hz.unison(7, detune: 25.cents, layout: :even) * -12.db          # evenly spaced: regular flanging
#     bg :ss, 110.hz.unison(7, detune: 25.cents, spread: 1) * -12.db              # spread: alternating sides
#     bg :ss, 110.hz.unison(7, detune: 25.cents, phase: 0) * -12.db               # copies start together: a zip at the start
#     bg :sq, A2.unison(3, detune: 8.cents) { |p| p.square.pwm(0.3) } * -12.db     # any shape in the block
#     bg :fm, A2.unison(3, detune: 6.cents) { |p| p.sine.fm(p.transpose(12).sine.at(300)) } * -12.db
#     bg :w, 220.hz.unison(5, detune: 15.cents, spread: 0.5.hz.lfo.at(0..1)) * -12.db   # spread from a node
#     bg :sw, 110.hz.unison(7, detune: 0.1.hz.lfo.triangle.at(0..50) / 100) * -12.db       # detune from a node (semitones): sweeps 0-50 cents
#     bg :sw, 110.hz.unison(7, detune: 0.1.hz.lfo.triangle.at(0..50) / 100, detune_mode: :exact) * -12.db   # exact per-copy exp (sounds the same)
#     midi.synth(voices: 4) { |v| v.hz.unison(5, detune: 15.cents, spread: 1) * v.amp_env }   # key-synced, random phases per note
#     midi.synth(voices: 4) { |v| v.hz.unison(7, detune: v.mod * 0.5, spread: 1) * v.amp_env }  # mod wheel: 0-50 cents of detune
#     midi.synth(voices: 4) { |v| v.hz.unison(5) { |p| p.saw.free } * v.amp_env }             # free-running copies
#     Unison.offsets(7, 25.cents, layout: :even)                                  # the detunes in semitones
#     stop

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  UNISON_SONG_BARS = 8

  # Starts the song on the current session (live, or inside a render
  # block).  +layout+ is the detune layout (:random or :even; see
  # Unison.offsets), +spread+ the pad's stereo spread (0 for mono),
  # +part+ :all, :pad, or :bass, and +bass_copies+ the number of saws in
  # the bass (1 for a plain saw).
  def self.unison_song(layout: :random, spread: 0.8, part: :all, bass_copies: 3)
    bpm 100

    chords = (seq(A3, F3, C4, G3).n1 & seq(C4, A3, E4, B3).n1 & seq(E4, C4, G4, D4).n1).legato(0.97).loop
    bass = seq(A1, A1, A2, A1, F1, F1, F2, F1, C2, C2, C3, C2, G1, G1, G2, B1).n8.legato(0.6).loop

    # Pad: seven saws per note, 18 cents either side, spread with each
    # side getting copies above and below the pitch; random phases at
    # every note-on, so chords don't start with the copies' zip.
    pad = chords.synth(voices: 6) { |v|
      v.hz.unison(7, detune: 18.cents, layout: layout, spread: spread) * v.env(0.25, 1.0, 0.85, 1.2, curve: :gentle)
    }
    pad = pad.filter(:lowpass, cutoff: 4.bars.lfo.triangle.at(900..3500), quality: 0.8) * 0.24

    # Bass: three saws 8 cents either side, mono, through an enveloped
    # resonant lowpass, plus a sine an octave down for weight.
    pitch = bass.hz
    bass_osc = pitch.unison(bass_copies, detune: 8.cents, layout: layout) + pitch.transpose(-12).sine.at(0.5)
    cutoff = 120 + 1800 * bass.env(0.002, 0.18, 0.15, 0.08, curve: :snappy)
    bass_synth = bass_osc.filter(:lowpass, cutoff: cutoff, quality: 3) * bass.amp_env(0.003, 0.2, 0.7, 0.08) * 0.44

    master { |mix| mix.reverb(:hall, wet: -14.db).softclip(0.6, 0.98) }

    bg :pad, pad, fade: 0 if part == :all || part == :pad
    if part == :all || part == :bass
      if part == :bass
        bg :bass, bass_synth, fade: 0
      else
        at_bar(2) { bg :bass, bass_synth, fade: 0 }
      end
    end
    at_bar(7) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: UNISON_SONG_BARS,
      layout: [:random, Symbol, '-l', 'Detune layout', MB::Sound::Unison::LAYOUTS],
      spread: [0.8, Float, '-s', "The pad's stereo spread (0: mono)", 0.0..1.0],
      part: [:all, Symbol, '-p', 'The parts to play', [:all, :pad, :bass]],
      bass_copies: [3, Integer, '-c', 'Saws in the bass unison', 1..9],
    ) { |p| unison_song(layout: p.layout, spread: p.spread, part: p.part, bass_copies: p.bass_copies) }
  end
end
