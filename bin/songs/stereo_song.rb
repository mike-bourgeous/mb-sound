#!/usr/bin/env ruby
# An 8-bar demo of multichannel (stereo) graphs: a pad with a different
# filter sweep on each side, an arpeggio that pans back and forth, echoes
# with a different delay per side, hats placed right of center, and a
# stereo reverb on the whole mix.  8 bars at 100 BPM.
#
# Usage:
#     bin/songs/stereo_song.rb             # plays live in the background session
#     bin/songs/stereo_song.rb song.flac   # renders to a file instead
#
# Or in bin/sound.rb:
#     load 'bin/songs/stereo_song.rb'
#     stereo_song                          # live
#     render('song.flac', bars: 8, tail: true) { stereo_song }
#
# Snippets to try in bin/sound.rb:
#     bg :saw, 110.hz.ramp.at(0.2).forever.stereo.filter(:lowpass, cutoff: channels(500, 1500))   # a different filter per side
#     bg :sweep, 110.hz.ramp.at(0.2).forever.stereo.filter(:lowpass, cutoff: 4.bars.lfo.at(300..2000).with_phase(0))
#     bg :pan, 330.hz.triangle.at(0.2).forever.pan(1.bar.lfo)                  # pans left and right every bar
#     bg :wide, stereo(220.hz.ramp.at(0.2), 220.7.hz.ramp.at(0.2)).forever.width(1.5)
#     bg :echo, (seq(C4, E4, G4).n8.loop.then { |c| c.tone.at(0.3) * c.env(0, 0.1, 0, 0.1) }).delay(channels(3.n16, 1.n4), feedback: -6.db, dry: 1)
#     master { |mix| mix.reverb(:hall, wet: -8.db).softclip(0.6, 0.98) }     # the whole mix through one stereo reverb
#     l, r = stereo(1.constant, 2.constant)                                   # bundles destructure like Arrays
#     (110.hz.ramp.at(1).stereo.filter(:lowpass, cutoff: channels(500, 900)) * 0.5).open_graphviz   # one box per stereo step

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  STEREO_SONG_BARS = 8

  # Starts the song on the current session (live, or inside a render block).
  def self.stereo_song
    bpm 100

    chords = seq(D3, Bb2, F3, C3).n1.legato(0.95).loop
    arp = seq(D4, F4, A4, D5, C5, A4, F4, A4).n16.loop
    bass = seq(D2, nil, D2, D3, Bb1, nil, C2, C3).n8.legato(0.7).loop
    hats = grid(16, 'x.x.x.x.x.x.X.x.').loop

    # Pad: stereo voices (a slightly detuned saw on each side), with each
    # side's filter swept by the same 4-bar LFO half a cycle apart
    pad = chords.synth(voices: 2) { |v|
      stereo(v.tone.ramp.at(0.5), v.transpose(0.1).tone.ramp.at(0.5)) * v.env(0.4, 1.0, 0.8, 1.5)
    }
    sweep = channels(4.bars.lfo.triangle.at(350..2400), 4.bars.lfo.triangle.with_phase(Math::PI).at(350..2400))
    pad = pad.filter(:lowpass, cutoff: sweep, quality: 1.5) * 0.1

    # Arpeggio panned back and forth every two bars
    pluck = (arp.tone.triangle.at(1) * arp.env(0.001, 0.12, 0, 0.08, velocity: 0.6..1)).pan(2.bars.lfo.at(-0.8..0.8)) * 0.14

    # Echoes of the arpeggio an octave up: 3/16 on the left, 1/4 on the right
    echo = (arp.transpose(12).tone.at(1) * arp.env(0.001, 0.05, 0, 0.05))
      .delay(channels(3.n16, 1.n4), feedback: -7.db, dry: 0, wet: 1) * 0.05

    bass_synth = (bass.tone.ramp.at(1).filter(:lowpass, cutoff: 150 + 1200 * bass.env(0.001, 0.1, 0.1, 0.05), quality: 4) *
      bass.env(0.003, 0.15, 0.6, 0.08)) * 0.16
    hat_synth = (noise.at(1).filter(:highpass, cutoff: 8000) * hats.env(0, 0.03, 0, 0.02, velocity: 0.2..1) * 0.1).pan(0.4)

    master { |mix| mix.reverb(:hall, wet: -10.db).softclip(0.6, 0.98) }

    bg :pad, pad, fade: 1
    at_bar(2) { bg :pluck, pluck, fade: 0 }
    at_bar(3) do
      bg :bass, bass_synth, fade: 0
      bg :hats, hat_synth, fade: 0
      bg :echo, echo, fade: 1
    end
    at_bar(7) { outro fade: 2 }
  end

  if $0 == __FILE__
    if ARGV[0]
      seconds = render(ARGV[0], bars: STEREO_SONG_BARS, tail: true, overwrite: true) { stereo_song }
      puts "Rendered #{seconds.round(1)} seconds to #{ARGV[0]}"
    else
      stereo_song
      puts 'Playing (Ctrl-C to stop)'
      wait # until the song and its reverb tails have ended
    end
  end
end
