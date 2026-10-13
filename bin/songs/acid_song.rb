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
#     bin/songs/acid_song.rb -M -10 acid.flac   # gentler mastering (about -15 LUFS; the default -M -7: -12.9)
#     bin/songs/acid_song.rb -d 10 -M -7.5 acid.flac   # drums even louder (-13.3 LUFS)
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
#     bg :acid, acid_voice(line, decay: 0.8)          # a shorter MEG (exponential, curve 30; default 1.56 s)
#     bg :acid, acid_voice(line, env_curve: :linear, decay: 0.6, accent_decay: 0.2)  # the earlier linear MEG
#     # Marks work in any seq, not just acid ones:
#     bg :lead, seq(E4, !G4, ~A4, B4, R, !D5, T, B4).n8.loop.synth(voices: 1) { |v| v.hz.glide(40.ms, legato: true).saw.lp4(v.cutoff(900), resonance: 0.5) * v.amp_env.legato }

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/acid'

module MB::Sound
  # The song's length in bars.
  ACID_SONG_BARS = 16

  # The acid's filter drive, makeup gain into its clipper (12 dB over
  # acid.rb's), and level (see .acid_song); -D 1.5 -G 3 -l 0.9 is the song
  # before 2026-10-13.
  ACID_SONG_DRIVE = 4.0
  ACID_SONG_GAIN = 12.0
  ACID_SONG_LEVEL = 0.75

  # The drums' gain and the master's gain into its limiter (patches-3,
  # 2026-10-13: "Drums need about 5dB, then a mastering limiter on all, to
  # bring this up to date"): the song at -10.5 LUFS, -1.0 dBTP, the
  # limiter taking up to about 3 dB off the peaks (-16.5 LUFS, -7.0 dBTP
  # before; -M -8 is about where the limiter starts to act).  Before, the
  # drums were at 0 dB and the master was a softclip(0.6, 0.98) at the
  # session's -10 dB master gain.
  #
  # patches-4 (2026-10-13; maintainer: "Still want drums louder lol"):
  # drums +9 dB (was +5) and 3 dB less into the limiter (-7, was -4).  At
  # -M -4 the louder drums only pushed the limiter harder (up to 6.6 dB of
  # gain reduction at +10 dB drums; the song got no louder, -10.5 ->
  # -10.8 LUFS, the kicks squashed instead), so the master comes down to
  # keep the limiter at about 3 dB on the highest peaks, as before: -12.9
  # LUFS, -1.0 dBTP.  `-d 5 -M -4` is the song before.
  ACID_SONG_DRUMS = 9.0
  ACID_SONG_MASTER = -7.0

  # Starts the song on the current session (live, or inside a render
  # block); +filter+ is :diode or :lp4.  +drive+ is the filter's drive and
  # +gain+ the makeup gain into the voice's soft clipper (acid_patch;
  # 1.5 and 3.0 there), pushed here so the acid distorts (maintainer
  # 2026-10-13: "Acid should be pushed into its distortion a fair amount
  # anyway; try cranking the acid up"); +level+ is its level in the mix.
  # +drums+ is the drums' gain in dB, +master+ the gain in dB into the
  # mastering limiter (-1 dBTP true peak), which replaces the session's
  # master gain.
  def self.acid_song(filter: :diode, drive: ACID_SONG_DRIVE, gain: ACID_SONG_GAIN, level: ACID_SONG_LEVEL, drums: ACID_SONG_DRUMS, master: ACID_SONG_MASTER)
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
    # MEG decay 1.3 s on the exponential curve (0.5 s linear before 2026-10-10)
    acid = acid_voice(main, cutoff: knob, reso: 0.7, decay: 1.3, filter: filter, drive: drive, gain: gain)

    kick = (45.constant + 120 * beat[:kick].env(0, 0.03, 0, 0.01)).tone.sine.at(1) * beat[:kick].env(0, 0.25, 0, 0.05) * 0.8
    hats = noise.at(1).filter(:highpass, cutoff: 8000) * beat[:hat].env(0, 0.03, 0, 0.02, sensitivity: 0.3..1, curve: :linear) * 0.2
    clap = noise.at(1).filter(:bandpass, cutoff: 1500, quality: 2) * beat[:clap].env(0, 0.08, 0, 0.04, curve: :linear) * 0.6

    # (the gain inside the chain: master_gain comes after the limiter)
    master_gain(0.db)
    master { |mix| (mix * master.db).limit(ceiling: -1.db, true_peak: true) }

    bg :acid, acid * level, fade: 0
    bg :drums, (kick + hats + clap) * drums.db, fade: 0

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
      drive: [ACID_SONG_DRIVE, Float, '-D', 'Acid filter drive (acid.rb: 1.5)', 0.1..10.0],
      gain: [ACID_SONG_GAIN, Float, '-G', 'Acid makeup gain into its soft clipper (acid.rb: 3)', 0.1..30.0],
      level: [ACID_SONG_LEVEL, Float, '-l', 'Acid level in the mix', 0.0..2.0],
      drums: [ACID_SONG_DRUMS, Float, '-d', 'Drums gain in dB (0 before 2026-10-13, then 5)', -20.0..20.0],
      master: [ACID_SONG_MASTER, Float, '-M', 'Gain in dB into the mastering limiter', -30.0..20.0],
    ) { |p| acid_song(filter: p.filter, drive: p.drive, gain: p.gain, level: p.level, drums: p.drums, master: p.master) }
  end
end
