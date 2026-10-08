#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar acid demo at 128 BPM: note marks in seqs (`!A1` accent, `~A1`
# slide, `T` tie, `R` rest, `.up`/`.dn` octaves), Seq#acid's 303 playing,
# and the diode ladder voice from bin/synths/acid.rb.
#
# 1. Bars 1-4: the main line; the cutoff knob rises over 8 bars (a
#    tempo-synced LFO), so the accents' sweep gets louder and squelchier.
# 2. Bars 5-8: a 12-step line against the 16-step drums (a polymeter: the
#    accents land somewhere new every bar).
# 3. Bars 9-12: the main line permuted (accents and slides move with their
#    notes, ties and rests stay), then transposed.
# 4. Bars 13-16: the main line again, with every note accented for the
#    last two bars, so the accent sweep piles up.
#
# Usage:
#     bin/songs/acid_song.rb                    # plays live in the background session
#     bin/songs/acid_song.rb acid.flac          # renders to a file instead (-f to overwrite)
#     bin/songs/acid_song.rb -F lp4 lp4.flac    # the lp4 filter instead of the diode ladder
#     bin/songs/acid_song.rb --help             # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/acid_song.rb'
#     acid_song                                 # live
#
# Snippets (bin/sound.rb, after loading bin/synths/acid.rb):
#     bpm 128
#     line = acid(A1, !A1, ~A2, A1, R, C2, !A1, T, ~D2, E2, A1.up, R, !G1, ~A1, A2, R).loop
#     bg :acid, acid_voice(line)
#     swap :acid, line.permute(seed: 5)              # same notes, new order, on the next bar
#     swap :acid, line.acc                           # everything accented: the sweep piles up
#     swap :acid, line.slide                         # everything slid: one long glide
#     swap :acid, line.acid(gate: 0.25)              # shorter, plucky gates
#     # Marks work in any seq, not just acid ones:
#     bg :lead, seq(E4, !G4, ~A4, B4, R, !D5, T, B4).n8.loop.synth(voices: 1) { |v| v.hz.glide(40.ms, legato: true).saw.lp4(v.cutoff(900), resonance: 0.5) * v.amp_env.legato }

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/acid'

module MB::Sound
  # The song's length in bars.
  ACID_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render
  # block); +filter+ is :diode or :lp4.
  def self.acid_song(filter: :diode)
    bpm 128

    main = acid(A1, !A1, ~A2, A1, R, C2, !A1, T, ~D2, E2, A1.up, R, !G1, ~A1, A2, R).loop
    poly = acid(C2, ~C2.up, !C2, R, ~Eb2, !F2, C2, T, ~G1, Bb1, !C2, R).loop # 12 steps
    beat = grid(16,
      kick: 'x...x...x...x...',
      hat:  '..x...x...x...xX',
      clap: '....x.......x...'
    ).loop

    # The cutoff knob rises from 180 to 900 Hz and back over 8 bars
    knob = 8.bars.lfo.triangle.at(180..900)
    acid = acid_voice(main, cutoff: knob, reso: 0.7, decay: 0.5, filter: filter)

    kick = (45.constant + 120 * beat[:kick].env(0, 0.03, 0, 0.01)).tone.sine.at(1) * beat[:kick].env(0, 0.25, 0, 0.05) * 0.8
    hats = noise.at(1).filter(:highpass, cutoff: 8000) * beat[:hat].env(0, 0.03, 0, 0.02, sensitivity: 0.3..1, curve: :linear) * 0.2
    clap = noise.at(1).filter(:bandpass, cutoff: 1500, quality: 2) * beat[:clap].env(0, 0.08, 0, 0.04, curve: :linear) * 0.6

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :acid, acid * 0.9, fade: 0
    bg :drums, kick + hats + clap, fade: 0

    at_bar(5) { swap :acid, poly }
    at_bar(9) { swap :acid, main.permute(seed: 4) }
    at_bar(11) { swap :acid, main.permute(seed: 4).transpose(3) }
    at_bar(13) { swap :acid, main }
    at_bar(15) { swap :acid, main.acc }
  end

  if main_script?(__FILE__)
    song_script(
      bars: ACID_SONG_BARS,
      filter: [:diode, Symbol, '-F', 'The acid filter', [:diode, :lp4]],
    ) { |p| acid_song(filter: p.filter) }
  end
end
