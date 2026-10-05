#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 32 second demo of clip swaps (swap): the same bass synth, pad, and
# drum kit play for the whole song while their clips change on the bar,
# so filters, envelopes, and the delay on the bass keep ringing through
# every change.  16 bars at 120 BPM.
#
# - Bar 5: the bass line changes; its octave-up layer follows.
# - Bar 7: the drums switch to a busier pattern (swapping whole grid kits).
# - Bar 9: new chords; the pad's synth plays them on its voices.
# - Bar 11: the bass line plays backward (reverse).
# - Bar 13: the bass notes are shuffled over the same rhythm (permute).
# - Bar 15: everything goes back to the start and fades out.
#
# Usage:
#     bin/songs/swap_song.rb             # plays live in the background session
#     bin/songs/swap_song.rb song.flac   # renders to a file instead (-f to overwrite)
#     bin/songs/swap_song.rb --graphviz  # draws the graph at the start of the song
#     bin/songs/swap_song.rb --help      # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/swap_song.rb'
#     swap_song                          # live
#     render('song.flac', bars: 16) { swap_song }
#
# A riff to try swapping in bin/sound.rb (from a live test; the FM pitch,
# filter, and ratcheted amp envelopes, and the delay, all follow the swaps):
#     s = seq(A3, C3, G3, D3).n1.loop
#     master { |*c| c.reverb(:hall) }
#     bg :riff, s.then { |riff| (riff.tone.triangle.log_fm(2 * riff.env(0.0, 0.5, 0, 0.5)).at(1).filter(:lowpass, quality: 4, cutoff: 250 + riff.env(0.001, 0.5, 0, 0.5) * 4000).softclip(0.1, 0.5) * riff.ratchet(4).env(0.001, 0.5, 0, 0.5)).delay(seconds: 0.375, feedback: -2.db, dry: 1, wet: -5.db) }
#     swap :riff, s.stretch(2).transpose(5)
#     swap :riff, s.stretch(4).transpose(7)

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/fifth_pad'

module MB::Sound
  # The song's length in bars.
  SWAP_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render block).
  def self.swap_song
    bpm 120

    bass_a = seq(A1, A1, nil, A2, G1, nil, C2, D2).n8.legato(0.8).loop
    bass_b = seq(F1, nil, F2, F1, E1, nil, E2, G1).n8.legato(0.8).loop

    chords_a = seq(A2, F2).n1.legato(0.95).loop
    chords_b = seq(D3, C3, Bb2, C3).n2.legato(0.95).loop

    beat_a = grid(16,
      kick:  'x.......x.......',
      snare: '....x.......x...',
      hat:   'x.x.x.x.x.x.x.x.'
    ).loop
    beat_b = grid(16,
      kick:  'x..x....x.x.....',
      snare: '....x.......x..x',
      hat:   'xxX.xxX.xxX.xxXx'
    ).loop

    # A plucky bass with an octave-up layer made from the same clip (so it
    # follows every swap) and a delay whose echoes ring across the changes
    bass_tone = bass_a.tone.ramp.at(1) + bass_a.transpose(12).tone.ramp.at(0.25)
    bass = (bass_tone.filter(:lowpass, cutoff: 150 + 2500 * bass_a.env(0.001, 0.15, 0.1, 0.05), quality: 5) *
      bass_a.env(0.003, 0.2, 0.5, 0.08) * 0.14)
    bass = bass + bass.delay(seconds: 0.375) * 0.3

    pad = fifth_pad(chords_a, cutoff: 1100).map { |c| c * 0.45 }

    kick = (40.constant + 90 * beat_a[:kick].env(0, 0.04, 0, 0.01)).tone.sine.at(1) * beat_a[:kick].env(0, 0.3, 0, 0.05) * 0.5
    # Linear decays for the snare and hats: about the length of the old
    # smoothstep envelopes (the default :analog curves sound too tight here)
    snare = noise.at(1).filter(:bandpass, cutoff: 1900, quality: 1.5) * beat_a[:snare].env(0, 0.12, 0, 0.05, curve: :linear) * 0.5
    hats = noise.at(1).filter(:highpass, cutoff: 7500) * beat_a[:hat].env(0, 0.025, 0, 0.02, sensitivity: 0.1..1, curve: :linear) * 0.14

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :pad, pad, fade: 1
    bg :bass, bass, fade: 0
    bg :drums, kick + snare + hats, fade: 0

    at_bar(5) { swap :bass, bass_b }
    at_bar(7) { swap :drums, beat_a => beat_b }
    at_bar(9) { swap :pad, chords_b }
    at_bar(11) { swap :bass, bass_a.reverse }
    at_bar(13) { swap :bass, bass_a.permute(seed: 2) }

    at_bar(15) do
      swap :bass, bass_a
      swap :drums, beat_b => beat_a
      swap :pad, chords_a
      outro fade: 2
    end
  end

  song_script(bars: SWAP_SONG_BARS) { swap_song } if main_script?(__FILE__)
end
