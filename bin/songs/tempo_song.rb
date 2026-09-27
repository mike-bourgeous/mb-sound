#!/usr/bin/env ruby
# A 16-bar demo of tempo sync: a pad whose filter sweeps with a 4-bar LFO,
# a pluck through a dotted-eighth delay, and an echo part whose delay
# alternates between 3/16 and 5/16 every bar.  The tempo drops from 100 to
# 80 BPM at bar 9 and comes back at bar 13; the LFO stays on the bar grid
# and the delays glide to their new times like a tape delay.
#
# Usage:
#     bin/songs/tempo_song.rb             # plays live in the background session
#     bin/songs/tempo_song.rb song.flac   # renders to a file instead
#
# Or in bin/sound.rb:
#     load 'bin/songs/tempo_song.rb'
#     tempo_song                          # live
#     render('song.flac', bars: 16) { tempo_song }
#
# Snippets to try in bin/sound.rb:
#     3.n16                                  # => 3 × n16 (also 3.sixteenths, 1.n8.dotted, 2.bars, 3.beats)
#     bg :sweep, 55.hz.ramp.at(1).filter(:lowpass, cutoff: 4.bars.lfo.triangle.at(200..3000), quality: 6).forever * 0.3
#     bg :wob, 55.hz.square.at(1).filter(:lowpass, cutoff: 1.n8.lfo.at(150..900), quality: 4).forever * 0.2
#     bpm 90                                 # both LFOs follow, still on the bar grid
#     s = seq(C4, Eb4, G4, Bb4).n16.loop
#     bg :pluck, (s.tone.triangle.at(1) * s.env(0.001, 0.15, 0, 0.1)).delay(1.n8.dotted, feedback: -6.db, dry: 1, wet: -6.db) * 0.3
#     bg :alt, (s.tone.at(1) * s.env(0.001, 0.1, 0, 0.1)).delay(2.bars.lfo.square.at(3.n16..5.n16), dry: 1, wet: -4.db) * 0.3
#     master { |mix| mix.filter(:lowpass, cutoff: 8.bars.lfo.at(800..8000)) }   # a master sweep that freezes while stopped
#     master { |mix| mix.filter(:lowpass, cutoff: 8.bars.lfo.freewheel.at(800..8000)) }   # keeps moving while stopped
#     notes = seq(A2, E3, C3).n4.loop        # a comb resonator tuned to each note (Clip#period)
#     bg :string, (noise.at(1).forever * notes.env(0, 0.004, 0, 0.001)).delay(notes.period, feedback: 0.98, dry: 1, wet: 1, smoothing: false) * 0.3

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  TEMPO_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render block).
  def self.tempo_song
    bpm 100

    chords = seq(D3, Bb2, F3, C3).n1.legato(0.95).loop
    arp = seq(D4, F4, A4, D5, C5, A4, F4, A4).n16.loop
    bass = seq(D2, nil, D2, D3, Bb1, nil, C2, C3).n8.legato(0.7).loop
    hats = grid(16, 'x.x.x.x.x.x.X.x.').loop

    # Pad: two detuned saws per voice, through one filter swept by a
    # 4-bar LFO that stays on the bar grid
    pad = chords.synth(voices: 2) { |v|
      (v.tone.ramp.at(0.5) + v.transpose(0.07).tone.ramp.at(0.5) + v.transpose(7).tone.ramp.at(0.3)) *
        v.env(0.4, 1.0, 0.8, 1.5)
    }.filter(:lowpass, cutoff: 4.bars.lfo.triangle.at(350..2800), quality: 2) * 0.12

    # Pluck through a dotted-eighth delay
    pluck = (arp.tone.triangle.at(1) * arp.env(0.001, 0.12, 0, 0.08, velocity: 0.6..1))
      .delay(1.n8.dotted, feedback: -5.db, dry: 1, wet: -5.db) * 0.16

    # An echo whose delay alternates between 5/16 and 3/16 every bar
    echo = (arp.transpose(12).tone.at(1) * arp.env(0.001, 0.06, 0, 0.05))
      .delay(2.bars.lfo.square.at(3.n16..5.n16), dry: 0.6, wet: -3.db, smoothing: false) * 0.08

    bass_synth = (bass.tone.ramp.at(1).filter(:lowpass, cutoff: 150 + 1200 * bass.env(0.001, 0.1, 0.1, 0.05), quality: 4) *
      bass.env(0.003, 0.15, 0.6, 0.08)) * 0.18
    hat_synth = noise.at(1).filter(:highpass, cutoff: 8000) * hats.env(0, 0.03, 0, 0.02, velocity: 0.2..1) * 0.12

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :pad, pad, fade: 1
    at_bar(3) { bg :pluck, pluck, fade: 0 }
    at_bar(5) do
      bg :bass, bass_synth, fade: 0
      bg :hats, hat_synth, fade: 0
    end
    at_bar(7) { bg :echo, echo, fade: 1 }

    # Slow down: the LFO stretches to the new bar length and the delays glide
    at_bar(9) { bpm 80 }
    at_bar(13) { bpm 100 }

    at_bar(15) { outro fade: 2 }
  end

  if $0 == __FILE__
    if ARGV[0]
      seconds = render(ARGV[0], bars: TEMPO_SONG_BARS, tail: true, overwrite: true) { tempo_song }
      puts "Rendered #{seconds.round(1)} seconds to #{ARGV[0]}"
    else
      tempo_song
      puts 'Playing (Ctrl-C to stop)'
      wait # until the song and its reverb tails have ended
    end
  end
end
