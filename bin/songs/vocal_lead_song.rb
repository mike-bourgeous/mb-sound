#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar tech-house loop at 126 BPM: the vocal lead from
# bin/synths/vocal_lead.rb (kick wavetable -> formant filter in parallel
# with a resonant lp4 -> key-tracked sample-rate crusher -> delay and
# reverb) playing one hook through a silent chord progression
# (Clip#ghost_chords).
#
# The lead plays in the bass octave (A1-E2), a bass-house "talking bass"
# with a sine sub on its notes, its vowel and filter wobbling with a
# tempo-synced triangle skewed almost to a ramp (low on each beat, rising
# over 90% of it, falling just before the next; maintainer's listening
# note, 2026-10-11: "Bring it down to the bass octave and use a skewed
# temp synced triangle (almost ramp) for the lfo").  `-O 0 -k 0.5` plays
# the first version: the hook at A4 with a plain triangle wobble, over an
# offbeat saw bass that never leaves the root.
#
# 1. Bars 1-4: the hook as written, A minor triad tones with B as a
#    passing note: it implies A minor all the way.
# 2. Bars 5-12: the same rhythm and contour snapped bar by bar to ghost
#    chords i-iv-VII-VI (Am, Dm, G, F), twice; nothing but the melody
#    moves, yet the harmony seems to.
# 3. Bars 13-16: the same progression built in harmonic minor (vii is G#
#    diminished: the leading tone pulls back to A), a 4-bar variation
#    before the natural progression comes back.
#
# Usage:
#     bin/songs/vocal_lead_song.rb                     # plays live in the background session
#     bin/songs/vocal_lead_song.rb vocal.flac          # renders to a file instead (-f to overwrite)
#     bin/songs/vocal_lead_song.rb -S pulse vocal.flac # a narrow pulse instead of the kick wavetable
#     bin/songs/vocal_lead_song.rb -t 0.5 vocal.flac   # low notes crush relatively more
#     bin/songs/vocal_lead_song.rb -O 0 -k 0.5 vocal.flac  # the first version: lead at A4, plain triangle
#     bin/songs/vocal_lead_song.rb -k 0.1 vocal.flac   # skewed the other way: a quick rise, a slow fall
#     bin/songs/vocal_lead_song.rb --help
#
# Or in bin/sound.rb:
#     load 'bin/songs/vocal_lead_song.rb'
#     vocal_lead_song
#
# Snippets (after loading it):
#     low = VOCAL_HOOK.transpose(-36)       # the hook in the bass octave, as the song plays it
#     swap :lead, low.ghost_chords(1, 6, 3, 7, scale: scale(:minor, :a))     # i-VI-III-VII
#     swap :lead, low.ghost_chords(1, 4, per: 2.beats, scale: scale(:minor, :a))  # two chords per bar
#     swap :lead, low.ghost_chords([A1, C2, E2], [F1, A1, C2, E2])          # explicit chords

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/vocal_lead'

module MB::Sound
  # The song's length in bars.
  VOCAL_LEAD_SONG_BARS = 16

  # The hook: one bar of A minor triad tones on a sixteenth grid, B as a
  # passing note (the melody reference's recipe).
  VOCAL_HOOK = seq(A4, R, C5, A4, R, E5, R, C5, T, A4, R, B4, C5, R, E5, R).n16.loop

  # Starts the song on the current session (live, or inside a render
  # block).  +octave+ moves the hook (-3: A1-E2, the bass octave; 0 the
  # first version at A4, over a separate root bass), +skew+ is the wobble
  # LFO's rising fraction (0.5 a plain triangle).  Other options go to the
  # lead's patch (see .vocal_lead_patch).
  def self.vocal_lead_song(octave: -3, skew: 0.9, **lead_options)
    bpm 126

    am = scale(:minor, :a)
    hook = octave == 0 ? VOCAL_HOOK : VOCAL_HOOK.transpose(octave * 12)
    ghost = hook.ghost_chords(1, 4, 7, 6, scale: am)
    harmonic = hook.ghost_chords(1, 4, 7, 6, scale: am, harmonic: true)
    low = octave <= -2

    lead = vocal_lead_voice(hook, wobble: 1.n4, skew: skew, **lead_options)
    bass = nil
    if low
      # The talking bass: a sine sub on the same notes (the patch's 90 Hz
      # highpass leaves the fundamentals to it), an echo kept out of the low
      # end, a little hall; the hook's clip plays both, so swaps move both
      sub = hook.synth(voices: 1) { |v| v.hz.glide(0.04, legato: true).sine * v.env(0.004, 0.3, 0.8, 0.08).legato }
      echo = lead.delay(1.n8.dotted, feedback: 0.3, wet: 1, dry: 0).filter(:highpass, cutoff: 400, quality: 0.7) * 0.2
      lead = (lead + echo).reverb(:hall, mix: 0.1, highpass: 250, output_channels: 2) * 0.56 + sub * 0.27
    else
      # The lead, with a dotted-eighth echo and a little hall
      lead = (lead + lead.delay(1.n8.dotted, feedback: 0.3, wet: 1, dry: 0) * 0.25).reverb(:hall, mix: 0.15, output_channels: 2) * 0.5

      # The bass stays on the root: offbeat eighths with a sixteenth pickup
      bass_line = seq(R, A1, R, A1, R, A1, R, A1.n16, A1.n16).n8.loop
      bass = bass_line.synth(voices: 1) { |v|
        v.hz.saw.lp4(v.cutoff(260, env: v.filt_env(0.002, 0.12, 0.0, 0.05, depth: 3), keytrack: 0), resonance: 0.35) * v.env(0.002, 0.15, 0.6, 0.04)
      }
    end

    beat = tr808(
      grid(16,
        kick:     'X...X...X...X...',
        clap:     '....X.......X...',
        hat:      '..x...x...x...xX',
        open_hat: '......x.......x.',
      ).loop,
      kick: { decay: 0.5 },
      clap: { level: 0.6 },
      hat: { level: 0.5 },
    )

    master { |mix| mix.softclip(0.6, 0.98) }

    bg :drums, beat * 1.3, fade: 0
    bg :bass, bass, fade: 0 if bass
    bg :lead, lead, fade: 0

    # The natural-minor progression is the main one (maintainer's pick,
    # 2026-10-11); harmonic minor is a 4-bar variation
    at_bar(5) { swap :lead, ghost }
    at_bar(13) { swap :lead, harmonic }
  end

  if main_script?(__FILE__)
    song_script(
      bars: VOCAL_LEAD_SONG_BARS,
      source: [:kick, Symbol, '-S', 'Lead oscillator: kick wavetable, narrow pulse, or saw', [:kick, :pulse, :saw]],
      crush_track: [1.0, Float, '-t', 'Crusher key tracking (1 follows the note exactly)', -1.0..2.0],
      crush: [4200.0, Float, '-c', 'Crusher rate at C4 in Hz (0 for none)', 0.0..48000.0],
      octave: [-3, Integer, '-O', 'Octaves to move the hook (-3 the bass octave, 0 the first version over a root bass)', -4..1],
      skew: [0.9, Float, '-k', 'Wobble LFO skew: rising fraction of each beat (0.5 a plain triangle, 0.9 nearly a ramp)', 0.01..0.99],
    ) { |p| vocal_lead_song(source: p.source, crush_track: p.crush_track, crush: p.crush, octave: p.octave, skew: p.skew) }
  end
end
