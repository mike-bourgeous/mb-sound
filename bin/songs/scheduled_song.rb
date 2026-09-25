#!/usr/bin/env ruby
# A 60 second demo song arranged with the scheduling commands (at_bar,
# every, resume, outro): a two-voice fifth pad, a bass line, and synth
# drums, at 120 BPM (30 bars).
#
# Usage:
#     bin/songs/scheduled_song.rb             # plays live in the background session
#     bin/songs/scheduled_song.rb song.flac   # renders to a file instead
#
# Or in bin/sound.rb:
#     load 'bin/songs/scheduled_song.rb'
#     scheduled_song                          # live
#     render('song.flac', bars: 30) { scheduled_song }

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/fifth_pad'

module MB::Sound
  # The song's length in bars.
  SCHEDULED_SONG_BARS = 30

  # Starts the song on the current session (live, or inside a render block).
  def self.scheduled_song
    bpm 120

    # A four-bar progression; the bass follows the chord roots
    chords = seq(A2, F2, C3, G2).n1.legato(0.95).loop
    bass = [A1, F1, C2, G1].map { |r|
      n = r.number
      seq(n, n, nil, n + 12, n, nil, n + 7, n + 10).n8.legato(0.8)
    }.reduce(:|).loop

    beat = grid(16,
      kick:  'x...x...x...x..x',
      snare: '....x.......x...',
      hat:   'x.x.x.x.x.x.x.xX'
    ).loop

    # Levels are set so the mix stays below full scale without a limiter
    pad = fifth_pad(chords, cutoff: 1100).map { |c| c * 0.5 }
    bass_synth = bass.tone.ramp.at(1)
      .filter(:lowpass, cutoff: 200 + 1800 * bass.env(0.001, 0.12, 0.1, 0.05), quality: 4) *
      bass.env(0.003, 0.15, 0.6, 0.05) * 0.15
    kick = (40.constant + 90 * beat[:kick].env(0, 0.04, 0, 0.01)).tone.sine.at(1) * beat[:kick].env(0, 0.3, 0, 0.05) * 0.55
    snare = noise.at(1).filter(:bandpass, cutoff: 1900, quality: 1.5) * beat[:snare].env(0, 0.12, 0, 0.05) * 0.6
    hats = noise.at(1).filter(:highpass, cutoff: 7500) * beat[:hat].env(0, 0.025, 0, 0.02, velocity: 0.1..1) * 0.16

    # A 32nd-note hat roll on the last beat of a bar, built fresh each time
    fill = -> {
      roll = seq(nil).n2.d | seq(42).n4.roll(32, velocity: 0.2..1.0)
      noise.at(1).filter(:highpass, cutoff: 6000) * roll.env(0, 0.02, 0, 0.01, velocity: 0.1..0.8) * 0.2
    }

    # Intro: the pad swells in
    bg :pad, pad, fade: 2

    at_bar(5) { bg :bass, bass_synth, fade: 1 }

    at_bar(8, beat: 4) { bg :fill, fill.call, fade: 0 }
    at_bar(9) do
      bg :kick, kick, fade: 0
      bg :hats, hats, fade: 0
    end
    at_bar(13) { bg :snare, snare, fade: 0 }

    # A fill leading into every fourth bar from bar 16
    every(4, offset: 3) do
      bg :fill, fill.call, fade: 0 if (13..24).cover?(MB::Sound.transport.bar + 1)
    end

    # Breakdown: drums drop out, the bass fades, the pad carries on
    at_bar(17) do
      stop :kick, :snare, :hats, fade: 0
      stop :bass, fade: 2
    end

    # Everything comes back
    at_bar(21) do
      resume :kick, fade: 0
      resume :snare, fade: 0
      resume :hats, fade: 0
      resume :bass, fade: 0
    end

    # Fade out over the last five bars, silent right at 60 seconds
    at_bar(26) { outro fade: 5 }
  end

  if $0 == __FILE__
    if ARGV[0]
      seconds = render(ARGV[0], bars: SCHEDULED_SONG_BARS, overwrite: true) { scheduled_song }
      puts "Rendered #{seconds.round(1)} seconds to #{ARGV[0]}"
    else
      scheduled_song
      puts 'Playing (Ctrl-C to stop)'
      sleep 0.5 until transport.bar > SCHEDULED_SONG_BARS - 4 && players.empty?
    end
  end
end
