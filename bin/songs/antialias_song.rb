#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of the antialiased oscillators and shapers: a hard-synced
# lead whose sync ratio follows each note's envelope, a pulse-width
# modulated pad, a CZ-style bass (a sine whose phase warp closes with the
# envelope), a skewed-triangle arp, a soft-synced counter line, and drums
# driven into a soft clipper and a bitcrusher, all band-limited or
# antialiased (see MB::Sound::BandLimit and MB::Sound::Shaper).
#
# Usage:
#     bin/songs/antialias_song.rb             # plays live in the background session
#     bin/songs/antialias_song.rb song.flac   # renders to a file instead (-f to overwrite)
#     bin/songs/antialias_song.rb --help      # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/antialias_song.rb'
#     antialias_song
#
# A/B snippets to try in bin/sound.rb (the a* names are the naive, aliased
# versions; listen for tones moving against the sweep, and for grit that
# changes with pitch):
#     bg :saw, 110.hz.ramp.at(0.3).sync(ratio: 0.2.hz.lfo.at(1..8))   # clean hard-sync sweep
#     bg :saw, 110.hz.aramp.at(0.3).sync(ratio: 0.2.hz.lfo.at(1..8))  # the aliased one
#     bg :pwm, 880.hz.pulse(0.5.hz.lfo.at(0.05..0.95)).at(0.2)        # high PWM, clean
#     bg :pwm, 880.hz.apulse(0.5.hz.lfo.at(0.05..0.95)).at(0.2)       # ...and aliased
#     bg :cz, 110.hz.sine.pwm(0.3.hz.lfo.at(0.5..0.03)).at(0.3)        # CZ-style phase distortion
#     bg :tri, 220.hz.triangle.skew(0.3.hz.lfo.at(0.02..0.98)).at(0.3) # a triangle morphing to saws
#     bg :soft, 110.hz.triangle.softsync(ratio: 0.1.hz.lfo.at(1.2..3)).at(0.3)
#     bg :drive, 2000.hz.sine.at(4).softclip * 0.3                    # ADAA soft clip; compare asoftclip
#     bg :crush, 1500.hz.sine.quantize(0.25) * 0.3                    # antialiased bitcrush; compare aquantize
#     bg :gate, 220.hz.sine.at(0.3) * 3.hz.ramp.lfo.at(0..1)           # an LFO keeps exact edges below 15 Hz
#     stop :saw                                                        # etc.; or stop all with `stop`
#
#     bin/aliasing.rb 'p.ramp.sync(ratio: 2.37)' 'p.aramp.sync(ratio: 2.37)'   # measure any expression

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  ANTIALIAS_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render block).
  def self.antialias_song
    bpm 112

    chords = seq(A2, F2, C3, G2).n1.legato(0.95).loop
    lead = seq(A4, C5, E5, A5, G5, E5, C5, D5).n8.legato(0.6).loop
    counter = seq(E4, nil, A4, nil, G4, nil, C5, B4).n8.legato(0.8).loop
    bass = seq(A1, nil, A1, A2, F1, nil, G1, G2).n8.legato(0.5).loop
    kicks = grid(16, 'x...x...x...x..x').loop
    hats = grid(16, '..x...x...x..xx.').loop

    # Pad: pulses whose width sweeps with a 4-bar LFO, two per voice.  Its
    # envelope (slow-first curves, shorter attack and release) swells and
    # fades like the smoothstep ADSR this song was written with
    # (0.3/0.8/0.8/1.0).
    pad = chords.synth(voices: 2) { |v|
      (v.hz.pulse(4.bars.lfo.at(0.12..0.88)).at(0.5) + v.hz.transpose(0.08).pulse(4.bars.lfo.with_phase(Math::PI).at(0.12..0.88)).at(0.5)) *
        v.env(0.2, 0.8, 0.8, 0.9, curve: [-21, -12, -6])
    }.filter(:lowpass, cutoff: 2400, quality: 0.7) * 0.2

    # Lead: a saw hard-synced to its own note, the sync ratio rising with
    # each note's envelope (the classic sync sweep); a linear amp envelope
    # (close to the old smoothstep one), as on the counter line
    lead_env = lead.env(0.002, 0.25, 0.3, 0.15, curve: :linear)
    lead_synth = (lead.tone.saw.sync(ratio: 1 + lead.env(0.001, 0.35, 0.1, 0.2) * 4) * lead_env)
      .filter(:lowpass, cutoff: 5000, quality: 0.8)
      .delay(3.n16, feedback: -9.db, dry: 1, wet: -10.db) * 0.15

    # Bass: a sine whose phase warp narrows with the envelope (CZ-style)
    bass_env = bass.env(0.002, 0.2, 0.4, 0.08)
    bass_synth = bass.tone.sine.pwm(0.5 - 0.45 * bass.env(0.001, 0.15, 0.0, 0.05)) * bass_env * 0.5

    # Arp: skewed triangles, nearly saws (a linear decay, like the old
    # smoothstep envelope's length; the hats too)
    arp = (lead.transpose(12).tone.triangle.skew(0.15).at(1) * lead.env(0.001, 0.08, 0, 0.05, curve: :linear)) * 0.08

    # Counter line: soft sync for a hollow, metallic tone
    counter_synth = (counter.tone.triangle.softsync(ratio: 1.6) * counter.env(0.01, 0.3, 0.5, 0.2, curve: :linear)) * 0.1

    # Drums: a sine kick driven into the (antialiased) soft clipper, and
    # bitcrushed noise hats
    kick_env = kicks.env(0.0005, 0.12, 0, 0.05)
    kick = (60.hz.sine.fm(160 * kicks.env(0, 0.03, 0, 0.01)).at(3) * kick_env).softclip(0.4, 0.9) * 0.55
    hat = (noise.at(1).filter(:highpass, cutoff: 6000) * hats.env(0, 0.03, 0, 0.02, curve: :linear)).quantize(0.125) * 0.2

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :pad, pad, fade: 1
    at_bar(3) do
      bg :bass, bass_synth, fade: 0
      bg :kick, kick, fade: 0
    end
    at_bar(5) do
      bg :lead, lead_synth, fade: 0
      bg :hat, hat, fade: 0
    end
    at_bar(9) { bg :arp, arp, fade: 0 }
    at_bar(11) { bg :counter, counter_synth, fade: 1 }
    at_bar(15) { outro fade: 2 }
  end

  song_script(bars: ANTIALIAS_SONG_BARS) { antialias_song } if main_script?(__FILE__)
end
