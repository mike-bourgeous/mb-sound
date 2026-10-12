#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A 16-bar tech-house loop at 126 BPM: the vocal lead from
# bin/synths/vocal_lead.rb (kick wavetable -> formant filter in parallel
# with a resonant lp4 -> key-tracked sample-rate crusher -> delay and
# reverb) playing one hook through a silent chord progression
# (Clip#ghost_chords).
#
# The lead plays in the bass octave (A1-E2), a bass-house "talking bass"
# with a sine sub on its notes.  Maintainer's listening notes, 2026-10-11:
# "Bring it down to the bass octave and use a skewed temp synced triangle
# (almost ramp) for the lfo", then "Getting closer.  Lfo should be on the
# order of 1 bar or 4 bars (e.g. rise 3.6, fall 0.4); kick sample benefits
# from slower notes with pitch bend drops as well so individual kicks are
# momentarily almost audible (10-20Hz range briefly).  Decimation wet/dry
# is too strong".  So:
# - the vowel and filter wobble is a triangle skewed to 0.9 over 4 bars
#   (rising 3.6 bars, falling 0.4; `-w 1` for 1 bar), from its low point
#   at bar 1;
# - the bass hook moves in eighths, and each note before a rest dives two
#   octaves after its note-off (`drop:`, toward 14 Hz, where each cycle of
#   the kick wavetable is almost a single kick);
# - the crusher is mixed 40% wet (`-m`).
# `--first` plays the first version: the sixteenth hook at A4 with a
# quarter-note triangle wobble, fully crushed at key tracking 0.5, over an
# offbeat saw bass that never leaves the root.
#
# 1. Bars 1-4: the hook as written, A minor triad tones (B or D as
#    passing notes): it implies A minor all the way.
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
#     bin/songs/vocal_lead_song.rb -w 1 vocal.flac     # a 1-bar wobble
#     bin/songs/vocal_lead_song.rb -d 0 -m 1 vocal.flac  # no dives, fully crushed
#     bin/songs/vocal_lead_song.rb -k 0.1 vocal.flac   # skewed the other way: a quick rise, a slow fall
#     bin/songs/vocal_lead_song.rb --first vocal.flac  # the first version (A4 sixteenths, quarter-note triangle)
#     bin/songs/vocal_lead_song.rb --help
#
# Or in bin/sound.rb:
#     load 'bin/songs/vocal_lead_song.rb'
#     vocal_lead_song
#
# Snippets (after loading it):
#     low = VOCAL_BASS_HOOK                 # the bass hook the song plays
#     swap :lead, low.ghost_chords(1, 6, 3, 7, scale: scale(:minor, :a))     # i-VI-III-VII
#     swap :lead, low.ghost_chords(1, 4, per: 2.beats, scale: scale(:minor, :a))  # two chords per bar
#     swap :lead, low.ghost_chords([A1, C2, E2], [F1, A1, C2, E2])          # explicit chords
#     swap :lead, VOCAL_HOOK.transpose(-36)  # the first version's sixteenths, down in the bass

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/vocal_lead'

module MB::Sound
  # The song's length in bars.
  VOCAL_LEAD_SONG_BARS = 16

  # The hook: one bar of A minor triad tones on a sixteenth grid, B as a
  # passing note (the melody reference's recipe).
  VOCAL_HOOK = seq(A4, R, C5, A4, R, E5, R, C5, T, A4, R, B4, C5, R, E5, R).n16.loop

  # The bass hook: two bars of eighths in the bass octave, slower than
  # VOCAL_HOOK, with rests after three notes for the patch's pitch dives
  # (`drop:`).
  VOCAL_BASS_HOOK = seq(
    A1, A1, R, C2, A1, R, E2, T,
    A1, R, A1, C2, D2, C2, A1, R,
  ).n8.loop

  # Starts the song on the current session (live, or inside a render
  # block).  +first+ plays the first version (VOCAL_HOOK at A4 over a root
  # bass, a quarter-note triangle wobble, full crush at key tracking 0.5,
  # no dives); otherwise VOCAL_BASS_HOOK as a talking bass with a wobble
  # of +wobble+ bars skewed by +skew+ (the rising fraction; 0.5 a plain
  # triangle), pitch dives of +drop+ octaves, and a +crush_mix+ wet share.
  # Other options go to the lead's patch (see .vocal_lead_patch).
  def self.vocal_lead_song(first: false, wobble: 4, skew: 0.9, drop: 2, crush_mix: 0.4, **lead_options)
    bpm 126

    if first
      hook = VOCAL_HOOK
      lead_options = { wobble: 1.n4, skew: 0.5, crush_track: 0.5, crush_mix: 1, **lead_options }
    else
      hook = VOCAL_BASS_HOOK
      lead_options = { wobble: wobble.bars, skew: skew, drop: drop, crush_mix: crush_mix, **lead_options }
    end
    low = !first

    am = scale(:minor, :a)
    ghost = hook.ghost_chords(1, 4, 7, 6, scale: am)
    harmonic = hook.ghost_chords(1, 4, 7, 6, scale: am, harmonic: true)

    lead = vocal_lead_voice(hook, **lead_options)
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
      crush_mix: [0.4, Float, '-m', 'Crusher wet share 0..1', 0.0..1.0],
      wobble: [4.0, Float, '-w', 'Wobble LFO period in bars', 0.25..16.0],
      skew: [0.9, Float, '-k', 'Wobble LFO skew: rising fraction of each period (0.5 a plain triangle, 0.9 nearly a ramp)', 0.01..0.99],
      drop: [2.0, Float, '-d', 'Octaves each note before a rest dives (0 for none)', 0.0..4.0],
      first: [false, 'Play the first version (A4 sixteenths over a root bass; the other options are ignored but -S and -c)'],
    ) { |p|
      opts = p.first ? { source: p.source, crush: p.crush } :
        { source: p.source, crush_track: p.crush_track, crush: p.crush, crush_mix: p.crush_mix, wobble: p.wobble, skew: p.skew, drop: p.drop }
      vocal_lead_song(first: p.first, **opts)
    }
  end
end
