#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of band-limited wavetables (MB::Sound::Wavetable,
# Tone#wavetable): a pad scanning slowly through the basic shapes, a
# sampled piano (sample mode with a loop) restarting at each note, an arp
# whose waveform changes with the key zone (Wavetable::KeyMap, like the
# SQ-80's wave zones), a bass scanning the pulse table with each note's
# envelope, and a hard-synced lead reading a sliced drum table.
#
# Usage:
#     bin/songs/wavetable_song.rb             # plays live in the background session
#     bin/songs/wavetable_song.rb song.flac   # renders to a file instead (-f to overwrite)
#     bin/songs/wavetable_song.rb --help      # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/wavetable_song.rb'
#     wavetable_song
#
# Snippets to try in bin/sound.rb:
#     bg :saw, 110.hz.wavetable(:saw).at(0.3)                          # a clean saw from a table
#     bg :scan, 110.hz.wavetable(:basic, scan: 0.1.hz.lfo.triangle.at(0..1)).at(0.3)  # sine -> tri -> square -> saw
#     bg :pulse, 55.hz.wavetable(:pulses, scan: 0.25.hz.lfo.at(0..1)).at(0.3)        # pulse width by scanning
#     bg :loop, 110.hz.wavetable(:basic, scan: 0.1.hz.phasor * 4 / 3.0, scan_wrap: true).at(0.3)  # saw morphs back into sine: a seamless timbre loop (N frames: phasor * N / (N - 1))
#     bg :back, 110.hz.wavetable(:basic, scan: 0.1.hz.phasor * -4 / 3.0, scan_wrap: true).at(0.3) # the same loop backwards (negative scans wrap too)
#     bg :past, 110.hz.wavetable(:basic, scan: 0.2.hz.lfo.at(0.5..1.5), scan_wrap: true).at(0.3)  # an LFO swinging across the wrap (clamped without scan_wrap)
#     bg :rot, 110.hz.wavetable(:basic, scan: 27.5.hz.phasor * 4 / 3.0, scan_wrap: true).at(0.3)  # audio-rate wrap: each cycle a different shape, a timbre rotating at 27.5 Hz
#     bg :oct, (100 * 2 ** (0.1.hz.ramp.lfo.at(0..6))).tone.wavetable(Wavetable.from_harmonics(Wavetable::Library.saw, mips: :octave)).at(0.2)  # octave levels (old default): the top octave of air comes and goes
#     bg :sweep, (100 * 2 ** (0.1.hz.ramp.lfo.at(0..6))).tone.wavetable(:saw).at(0.2)  # no aliasing up to 6.4 kHz
#     bg :naive, (100 * 2 ** (0.1.hz.ramp.lfo.at(0..6))).tone.wavetable(Wavetable.from_harmonics(Wavetable::Library.saw, mips: false)).at(0.2)
#     bg :warp, 110.hz.wavetable(:organ).pwm(0.2.hz.lfo.at(0.1..0.9)).at(0.3)       # phase warp of any table
#     bg :sync, 110.hz.wavetable(:organ).sync(ratio: 0.2.hz.lfo.at(1..5)).at(0.3)    # hard-synced table
#     bg :csync, 110.hz.wavetable(Wavetable.from_harmonics(Wavetable::Library.saw, complex: true)).sync(ratio: 0.2.hz.lfo.at(1..5)).real.at(0.3)  # complex table, synced
#     bg :shape, 110.hz.sine.at(0.9).waveshape(:basic, scan: 0.1.hz.lfo.triangle.at(0..1)).at(0.3)  # a waveshaper (-1..1 across the table)
#     bg :bright, 110.hz.sine.at(0.9).waveshape(:saw, increment: false).at(0.3)   # ...reading the brightest level (aliases)
#     bg :phase, (110.hz.phasor + 2.hz.sine.at(0.1)).phase_table(:organ).at(0.3)    # any phase signal (cycles)
#     bg :add, 55.hz.harmonics(Array.new(16) { |i| (0.2 * (i + 1)).hz.lfo.at(0..1.0 / (i + 1)) }).at(0.3)  # additive, 16 moving harmonics
#     bg :noise, 1.hz.wavetable(:organ).noise.at(0.1)                            # noise with the table's distribution (bin/plot_noise.rb plots them)
#     t = Wavetable[:saw]; u = Wavetable.from_harmonics(Wavetable::Library.saw, taper: :sigma)  # exact library saw (Gibbs peaks at 1.18) vs sigma taper (peaks near 1)
#     bg :exact, 110.hz.wavetable(t).at(0.3); bg :tapered, 110.hz.wavetable(u).at(0.3)
#     t.save('/tmp/saw.flac'); Wavetable.from_file('/tmp/saw.flac').metadata   # saved tables keep their settings
#     t = Wavetable.from_file('sounds/piano_120hz_b2.flac', mode: :sample, root: 120, loop: 12000...16000)
#     bg :piano, E3.wavetable(t).at(0.5)                               # a looped sample at E3
#     stop
#
#     bin/aliasing.rb 'p.wavetable(:saw)' 'p.ramp' 'p.aramp'          # measure any expression

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  WAVETABLE_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render block).
  def self.wavetable_song
    bpm 96

    chords = seq(D3, A2, B2, G2).n1.legato(0.95).loop
    melody = seq(A4, nil, F4, E4, D4, nil, E4, F4, E4, nil, D4, C4, D4, nil, nil, nil).n8.legato(0.9).loop
    arp = seq(D3, A3, D4, F4, A4, D5, F5, A5).n16.legato(0.7).loop
    bass = seq(D2, nil, D2, D3, A1, nil, A1, A2, B1, nil, B1, B2, G1, nil, G1, G2).n8.legato(0.6).loop

    # Pad: two voices per note scanning sine -> triangle -> square -> saw
    # over eight bars, in opposite directions
    pad = chords.synth(voices: 2) { |v|
      (v.hz.wavetable(:basic, scan: 8.bars.lfo.triangle.at(0..1)) +
        v.hz.transpose(0.07).wavetable(:basic, scan: 8.bars.lfo.triangle.with_phase(Math::PI).at(0..1))) *
        v.env(0.4, 1.0, 0.8, 1.2)
    }.filter(:lowpass, cutoff: 3000, quality: 0.7) * 0.25

    # Piano: a sampled B2 (sample mode), looped over ten cycles, played at
    # each note's pitch and restarted by its key sync
    piano = Wavetable.from_file('sounds/piano_120hz_b2.flac', mode: :sample, root: 120, loop: 12000...16000)
    keys = melody.synth(voices: 3) { |v| v.hz.wavetable(piano) * v.amp_env(0.002, 1.5, 0.3, 0.4) } * 0.8

    # Arp: a different table in each 8-semitone zone
    zones = Wavetable::KeyMap.zones([:triangle, :organ, :square, :saw], from: D3, size: 8)
    arp_synth = arp.synth(voices: 2) { |v| v.hz.wavetable(zones) * v.env(0.001, 0.12, 0, 0.08) }
      .filter(:lowpass, cutoff: 6000, quality: 0.7) * 0.15

    # Bass: the pulse table scanned narrower as each note decays
    bass_synth = bass.synth(voices: 1) { |v|
      v.hz.wavetable(:pulses, scan: 1 - v.env(0.001, 0.4, 0.2, 0.1)) * v.amp_env(0.002, 0.3, 0.6, 0.1)
    } * 0.5

    # Lead: a drum-cycle table hard-synced to each note, the ratio rising
    # with its envelope
    drums = Wavetable.from_file('sounds/drums_wavetable.flac')
    lead_synth = melody.transpose(12).synth(voices: 1) { |v|
      v.hz.wavetable(drums, scan: 0.3).sync(ratio: 1 + v.env(0.001, 0.5, 0.2, 0.2) * 3) * v.env(0.005, 0.3, 0.5, 0.2)
    }.filter(:lowpass, cutoff: 5000, quality: 0.7).delay(3.n16, feedback: -9.db, dry: 1, wet: -10.db) * 0.2

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :pad, pad, fade: 1
    at_bar(3) { bg :keys, keys, fade: 0 }
    at_bar(5) do
      bg :bass, bass_synth, fade: 0
      bg :arp, arp_synth, fade: 0
    end
    at_bar(9) { bg :lead, lead_synth, fade: 0 }
    at_bar(15) { outro fade: 2 }
  end

  song_script(bars: WAVETABLE_SONG_BARS) { wavetable_song } if main_script?(__FILE__)
end
