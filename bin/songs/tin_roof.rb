#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# "Tin Roof, Slow River": a zen ambient soundscape by Kaede Rowntree.
#
# Kaede Rowntree is a fictional piano tuner turned field recordist written
# for the persona panel experiment (2026-10-13: four musician personas
# reviewed the API and each wrote a 2-3 minute demo with it; research branch
# research-persona-zen, research/persona-panel/zen/, with Kaede's review,
# friction log, and a performed take).  The song moved here from that
# branch; its instruments (bowls, rin, gong, koto, harp, drone, rain
# stick, tape, rooms) live in bin/synths/ambient.rb (playable from
# MIDI, and saved as presets); the weather (rain, river) stays here.
#
# About two and a half minutes at 60 BPM (one bar is four seconds), in D,
# on the yo pentatonic (D E G A B).  Everything is synthesized: no
# recordings.
#
#   emerge   6  rain on a tin roof (two wandering bands of noise and
#               pinged drops, each side its own) and a low river (lowpassed
#               noise and Minnaert-ish bubbles that rise in pitch as they
#               ring); the rain thickens (scene knob :drizzle)
#   drift    8  two old sine generators (D2, A2, D3) drifting a fraction of
#               a hertz against each other, beating; two singing bowls on
#               loops of 19.7 and 23.3 seconds that never line up (Tone
#               #wraps pulses, not bars), every partial a beating doublet
#   bloom    8  a tam-tam stroke (dense inharmonic partials gliding down,
#               high shimmer swelling in over seconds), a sparse kankyō
#               motif on the FM koto (humanized, some notes by chance), a swung
#               Karplus-Strong "harp" figure on the 16ths
#   hush     4  nearly nothing: thin rain and a small rin on its own
#               31.1-second loop
#   tide     8  a rain stick tips (click density swelling, panning across),
#               the gong again, the motif played backwards, the harp figure
#               rotated, everything back
#   dissolve 4  the tape wears out (knob :wear: wow, a falling lowpass,
#               sample-rate crush on the motif and harp), the room opens
#               (knob :space), then the form ends and everything rings out
#
# Usage:
#     bin/songs/tin_roof.rb                # plays live in the background session
#     bin/songs/tin_roof.rb tin_roof.flac  # renders (-f to overwrite; --stems DIR)
#
# Or in bin/sound.rb:
#     load 'bin/songs/tin_roof.rb'
#     tin_roof                   # tracks, knobs, and scenes (go :bloom etc. by hand)
#     tin_roof_form              # play the form
#     tin_roof(perform: true)    # or the whole performance
#
# Try (while it plays):
#     turn :drizzle, 1, over: 4  # a downpour (0 is a dry night)
#     turn :wear, 0.7, over: 8   # the tape gets old
#     turn :space, 0.2, over: 2  # step closer to the bowls
#     go :hush                   # the still point

# As rendered by Kaede on the research branch (2026-10-13, measured; nobody
# had listened yet): -17.9 LUFS integrated, -2.0 dBTP, LRA 12.3 LU.  Moved
# to bin/, the gong and the rain stick are MIDI voices (Synth lanes; the
# same partials and envelopes), and the drone's fifth and octave are
# ratios of the root (within 1e-13 Hz of the old note frequencies), so
# those three tracks differ slightly from Kaede's render; the rest is the
# same sample for sample.
#
require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/ambient'

module MB::Sound
  # Bars in the render: the form (38 bars) plus the ring-out.
  TIN_ROOF_BARS = 41

  # The yo pentatonic in D: D E G A B.
  TIN_ROOF_SCALE = [D3, E3, G3, A3, B3].freeze

  # Rain on a tin roof, one side: a "boiling" bandpassed bed whose center
  # wanders, a little air, and drops (pinged at random pitches; a few
  # brighter, longer "tin" pings).  +level+ may be a node (the :drizzle
  # knob): it scales the bed and the drops' density feel by level.
  def self.tin_roof_rain_side(level)
    bed = noise.filter(:bandpass, cutoff: ambient_walk(0.31, 600, 1700), quality: 0.9) * 0.35 +
      noise.filter(:highpass, cutoff: 6500, quality: 0.5) * 0.04
    drops = ambient_dust(90)
    pitch = noise.sample_hold(drops) * 900 + 2600
    tin = ambient_dust(7)
    tin_pitch = noise.sample_hold(tin) * 1200 + 5200
    patter = drops.ping(pitch, decay: 0.02) * 0.5 + tin.ping(tin_pitch, decay: 0.09) * 0.25
    (bed + patter * (level * 0.8 + 0.2)) * level
  end

  def self.tin_roof_rain(level)
    stereo(tin_roof_rain_side(level), tin_roof_rain_side(level)) * 0.8
  end

  # The river: lowpassed noise breathing slowly, and bubbles (Minnaert
  # resonances) that rise in pitch as they ring.
  def self.tin_roof_river
    side = -> {
      flow = noise.filter(:lowpass, cutoff: ambient_walk(0.13, 220, 520), quality: 0.6).filter(:highpass, cutoff: 70, quality: 0.6) * 0.5
      bub = ambient_dust(14)
      base = noise.sample_hold(bub) * 220 + 520
      fall = adsr(0, 0.06, 0, 0, trigger: bub, curve: :linear) # 1 at the strike, 0 after 60 ms
      bubbles = bub.ping(base * (1.7 - fall * 0.7), decay: 0.07) * 0.18
      flow + bubbles
    }
    stereo(side.(), side.()) * 0.85
  end

  # Strikes every +seconds+ (a loop in seconds, not bars: Tone#wraps
  # pulses), each a little softer or harder (a random height held from the
  # strike).
  def self.tin_roof_strikes(seconds, phase: 0)
    w = (1.0 / seconds).hz.lfo.with_phase(phase).wraps
    w * (noise.sample_hold(w) * 0.2 + 0.8)
  end

  # Two bowls (.ambient_bowl) on incommensurable loops, in a long soft room,
  # panned apart.  +space+ (a node) is the room's level; +hand+ (a node,
  # 0..1) scales the strikes, so a hand that stops striking lets the bowls
  # ring out while their loops keep turning (a scene that dropped the track
  # and brought it back would restart both loops from the same place, so
  # the bowls stay in every scene after the drift and the :ring knob plays
  # them).
  def self.tin_roof_bowls(space, hand)
    low = ambient_bowl(tin_roof_strikes(19.7, phase: 0.92) * hand, D3.frequency, decay: 26).pan(-0.35)
    mid = ambient_bowl(tin_roof_strikes(23.3, phase: 0.55) * hand, A3.frequency, flat: 12, decay: 20, beat: 1.1).pan(0.4) # the pebble: 12 cents flat
    dry = (low + mid) * 0.12
    ambient_room(dry, space: space, decay: 9)
  end

  # A small rin (high bowl) on its own 31.1-second loop.
  def self.tin_roof_rin(space)
    rin = ambient_bowl(tin_roof_strikes(31.1, phase: 0.93), G4.frequency, decay: 24, beat: 1.6).pan(0.15) * 0.08
    ambient_room(rin, space: space, decay: 7)
  end

  # The clips.  At 60 BPM a bar is 4 seconds: an eighth is half a second.
  def self.tin_roof_clips
    motif = seq(
      A4, R, R, D5, R, B4, R, R,   R, R, E5.maybe(0.6), R, R, R, R, R,
      G4, R, R, A4, R, R, R, R,    R, D5, R, R, B4.maybe(0.5), R, R, R,
    ).n8.humanize(1.n64, velocity: 0.15).loop(align: :launch)
    harp = seq(
      D5, R, A4, B4.maybe(0.7), R, D5, R, E5,  R, G4, R, R, A4.maybe(0.5), R, R, R,
    ).n16.swing(0.6).humanize(1.n128, velocity: 0.2).loop(align: :launch)
    {
      motif: motif,
      motif_back: motif.reverse,                # the illusion: the same line, backwards
      harp: harp,
      harp_back: harp.rotate(3.n16),            # the figure turned around its loop
      gong: seq(D2).n1,                         # one stroke (the note's length holds the shimmer)
      stick: seq(D5, Tie, Tie).n1,              # one long tip
    }.each { |name, clip| clip.named(name) }
  end

  # Sets up the song on the current session.  With +perform: true+, also
  # plays the form and the performer's nudges.  Returns the clips.
  def self.tin_roof(perform: false, seed: 1)
    c = tin_roof_clips
    bpm 60
    quant 1

    knob :drizzle, 0.3, range: 0.0..1.0     # how hard it rains
    knob :space, 0.5, range: 0.0..1.0       # the rooms' level
    knob :wear, 0.0, range: 0.0..1.0          # how old the tape is
    knob :ring, 1.0, range: 0.0..1.0          # how hard the bowls are struck (0: left to ring)

    master_gain(-1.db) # quiet on purpose: about -18 LUFS (the usual -10 dB would be -27)
    master :quiet # -18 LUFS, a slow limiter as a safety, not a sound (mastering-2: the maintainer's Bench pick)

    # Each patch draws its randomness from its own seed (seed + n), so a
    # patch sounds the same whenever it's built: live, in a render, or in
    # a take's replay, whose scene builds may run in another order.
    s = ->(n, &blk) { MB::Sound.with_seed(seed * 1000 + n, &blk) }
    track(:rain, fade: 1) { |_| s.(1) { tin_roof_rain(knob(:drizzle)) } }
    track(:river, fade: 2) { |_| s.(2) { tin_roof_river } }
    track(:drone, fade: 2) { |_| s.(3) { ambient_drone(D2.frequency) } }
    track(:bowls, fade: 1) { |_| s.(4) { tin_roof_bowls(knob(:space), knob(:ring)) } }
    track(:rin, fade: 1) { |_| s.(5) { tin_roof_rin(knob(:space)) } }
    track(:gong) { |clip| s.(6) { ambient_gong_voice(clip, space: knob(:space)) } }
    track(:motif) { |clip| s.(7) { ambient_koto_voice(clip, wear: knob(:wear), space: knob(:space)) } }
    track(:harp) { |clip| s.(8) { ambient_harp_voice(clip, wear: knob(:wear), space: knob(:space)) } }
    track(:stick) { |clip| s.(9) { ambient_rainstick_voice(clip) } }

    on = seq(R).n1.loop.named(:weather) # a silent clip for the texture tracks (they ignore it)

    scene :emerge, rain: on, river: on, drizzle: [0.7, from: 0.15, over: 6]
    scene :drift, rain: on, river: on, drone: on, bowls: on, drizzle: [0.45, over: 4], ring: 1
    scene :bloom, rain: on, river: on, drone: on, bowls: on, gong: c[:gong], motif: c[:motif], harp: c[:harp]
    scene :hush, rain: on, bowls: on, rin: on, drizzle: [0.3, over: 2], ring: 0
    scene :tide, rain: on, river: on, drone: on, bowls: on, rin: on, stick: c[:stick], gong: c[:gong],
      motif: c[:motif_back], harp: c[:harp_back], drizzle: [0.6, over: 4], ring: 1
    scene :dissolve, rain: on, bowls: on, rin: on, motif: c[:motif_back], harp: c[:harp_back],
      wear: [1, over: 4, curve: :smooth], space: [1, over: 4], drizzle: [0.2, over: 4], ring: 0

    tin_roof_performance(seed: seed) if perform
    c
  end

  def self.tin_roof_form(seed: 1)
    flow(seed: seed) do
      emerge   6
      drift    8
      bloom    8
      hush     4
      tide     8
      dissolve 4
    end
  end

  # The performance: the form, plus a couple of nudges.
  def self.tin_roof_performance(seed: 1)
    tin_roof_form(seed: seed)
    at_bar(18) { turn :space, 0.75, over: 4 }   # the bloom opens out
    at_bar(30) { turn :wear, 0.3, over: 2 }     # a little age before the end
  end

  if main_script?(__FILE__)
    song_script(
      bars: TIN_ROOF_BARS,
      seed: [1, 'Seed for the chance notes and the rain', '-s', Integer, 0..1_000_000],
    ) { |p|
      MB::Sound.seed(p.seed)
      tin_roof(perform: true, seed: p.seed)
    }
  end
end
