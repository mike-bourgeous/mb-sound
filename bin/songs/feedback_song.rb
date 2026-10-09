#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar demo of graph feedback loops (GraphNode#feedback, #delay with a
# block): Karplus-Strong plucked strings (bin/synths/pluck.rb) through a
# tape echo with saturation and tone in its loop, a flanged pad, and TR-808
# drums ringing through a comb filter tuned to the bass line (a "drum
# string": the loop's delay is one period of each bass note).  Every loop
# runs one sample at a time, so the repeats, flanger sweeps, and tunings are
# exact at any buffer size.
#
# Usage:
#     bin/songs/feedback_song.rb                 # plays live in the background session
#     bin/songs/feedback_song.rb loops.flac      # renders to a file instead (-f to overwrite)
#     bin/songs/feedback_song.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/feedback_song.rb'
#     feedback_song
#
# Snippets to try in bin/sound.rb:
#     # A comb filter: echoes exactly 5 ms apart (fb is the loop's own output)
#     bg :comb, tr808(grid(16, kick: 'x...', snare: '..x.').loop).feedback { |fb, input| input + fb.delay(5.ms) * 0.8 }
#     # A one-pole lowpass built from nodes (no delay: fb is the previous sample)
#     bg :lp, noise.at(0.3).feedback { |fb, input| input + (fb - input) * 0.97 }
#     # Tape echo: the insert runs on every repeat; repeats stay exactly 3/16 apart
#     bg :echo, seq(A3, C4, E4).n8.loop.synth { |v| v.hz.saw * v.amp_env(0, 0.2, 0, 0.1) }.delay(3.n16, feedback: 0.7, dry: 1) { |fb| fb.filter(2000.hz.lowpass).softclip(0.3, 0.9) }
#     # Insert pipeline: the first echo clean, repeats darker and dirtier (d.fb, in the loop), every echo softened on the way out (d.wet)
#     bg :pipe, seq(A3, C4, E4).n8.loop.synth { |v| v.hz.saw * v.amp_env(0, 0.2, 0, 0.1) }.delay(3.n16, feedback: 0.7, dry: 1) { |d| d.fb { |fb| fb.filter(1500.hz.lowpass).softclip(0.3, 0.9) }; d.wet { |wet| wet.filter(5000.hz.lowpass) } }
#     # A self-oscillating loop: a resonant bandpass and a softclip with loop gain above unity sing on their own (1.3 dies away)
#     bg :sing, (noise.at(0.01) * adsr(0, 0.01, 0, 0.01, hold: false)).feedback { |fb, input| input + fb.delay(2.ms).filter(:bandpass, cutoff: 880, quality: 8).softclip(0.2, 0.5) * 2 }
#     # A Karplus-Strong string excited by a kick drum, tuned by a clip
#     bass = seq(E2, G2, D2, A1).n4.loop
#     bg :kickstring, tr808(grid(16, kick: 'x...x...').loop).feedback { |fb, input| d = fb.delay(bass.period, smoothing: false); input * 0.3 + (d + d.delay(1.samples)) * 0.496 }
#     # Feedback through a moving delay: a flanger (try --feedback near -1 in bin/effects/flanger.rb)
#     bg :flange, 110.hz.saw.at(0.2).feedback { |fb, input| (input + fb.delay(0.1.hz.lfo.at(0.0005..0.005), smoothing: false) * -0.85).softclip(0.8, 1) }
#     # What a loop costs and does
#     l = noise.at(0.1).delay(0.3, feedback: 0.6) { |fb| fb.filter(3000.hz.lowpass).softclip }
#     puts l.explain    # the loop program
#     l.latency         # samples the delay absorbs (after the first block)
#
# CPU: see the Feedback loops section of CLAUDE.md for per-loop costs.

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/pluck'

module MB::Sound
  # The song's length in bars.
  FEEDBACK_SONG_BARS = 16

  # Starts the song on the current session (live, or inside a render
  # block).  +echo+ is the tape echo's feedback gain.
  def self.feedback_song(echo: 0.55)
    bpm 96

    # Plucked strings: an arpeggio of Am7 / Fmaj7 / C / G
    arp = seq(
      A3, C4, E4, G4, A4, G4, E4, C4,
      F3, A3, C4, E4, F4, E4, C4, A3,
      C4, E4, G4, C5, E5, C5, G4, E4,
      G3, B3, D4, G4, B4, G4, D4, B3,
    ).n16.loop
    strings = arp.synth(voices: 6) { |v| pluck_voice(v, sustain: 2.5, damping: 6, pick: 0.006, release: 0.2) }

    # Tape echo: a dotted-eighth repeat whose loop runs through a band limit
    # and a soft saturator on every pass
    tape = strings.delay(1.n8.dotted, feedback: echo, dry: 1, wet: 0.7) { |fb|
      fb.filter(150.hz.highpass(quality: 0.5)).filter(2500.hz.lowpass(quality: 0.5)).softclip(0.3, 0.9)
    }

    # A pad flanged by a feedback loop with a slowly sweeping delay
    chords = seq(A2, F2, C3, G2).n1.loop
    pad = chords.synth(voices: 2) { |v| (v.hz.saw + v.hz.transpose(7.01).saw) * v.amp_env(0.6, 1, 0.8, 1.5) * 0.12 }
    flanged = pad.feedback { |fb, input|
      (input + fb.delay(0.07.hz.lfo.at(0.0008..0.006), smoothing: false) * -0.8).softclip(0.6, 0.95)
    }

    # Drums ringing through a comb tuned to the bass line: the loop's delay
    # is one period of each bass note, so the kit sings the bass
    bass = seq(A1, F1, C2, G1).n1.loop
    kit = tr808(grid(16,
      kick:  'X.....x...X..x..',
      snare: '....X.......X...',
      hat:   'x.x.x.x.x.xxx.x.',
    ).loop, kick: { tune: 48 })
    drum_string = kit.feedback { |fb, input|
      d = fb.delay(bass.period, smoothing: false)
      input * 0.6 + (d + d.delay(1.samples)) * 0.49
    } * 0.3

    master_gain(-4.db)
    master { |mix| mix.softclip(0.7, 0.98) }

    bg :strings, (tape * 1.8).pan(-0.15)
    at_bar(5) { bg :pad, flanged.pan(0.25), fade: 0 }
    at_bar(9) { bg :drums, drum_string, fade: 0 }
    at_bar(13) { stop :pad, fade: 2 }
    at_bar(15) { outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: FEEDBACK_SONG_BARS,
      echo: [0.55, Float, '-e', 'Tape echo feedback gain', 0.0..1.2],
    ) { |p| feedback_song(echo: p.echo) }
  end
end
