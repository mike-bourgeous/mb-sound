#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Small Talk": a bass house track at 125 BPM in G minor, 89 bars (2:52
# rendered), built around a talking bass: the vocal lead patch from
# bin/synths/vocal_lead.rb (a kick drum as a wavetable -> a tenor formant
# filter in parallel with a resonant lp4 -> a key-tracked sample-rate
# crusher, lightly mixed in) in the bass octave, its vowels and peak swept
# by a 4-bar triangle skewed to 0.9 (rising 3.6 bars, falling 0.4), with
# notes before rests diving two octaves like a tape stop.  A midrange cut
# tames the formant pile-up, and a waveshaped, squeezed upper layer gives
# it top end.  The bass carries the melody; a silent chord progression
# underneath (Clip#ghost_chords, natural minor i-iv-VII-VI, Gm Cm F Eb)
# moves it bar by bar, and the second drop changes the progression to
# i-VI-III-VII (Gm Eb Bb F).
#
# Written for small speakers as well as big ones: closed hats on every
# 16th (offbeats accented) and a bright clap carry the grid, the talking
# bass is mostly harmonics (formants and the waveshaped layer, 250 Hz-10
# kHz) over a sine sub, and the groove's "bong" bass is saturated so its
# pitch reads without the sub.  Everything with sixteenths (hats, shaker,
# ride, bongs, the talking bass) shares one swing.
#
#   intro     8  drums only: kick, offbeat hats, a soft/accented shaker,
#                a clap roll turnaround every 8 bars, toms every 4
#   groove    8  clap on 2 and 4, open hats, the "bong" bass (saturated
#                offbeat eighths of sine and lowpassed saw with a small
#                pitch bump, ducked by the kick)
#   tease     8  the talking bass without its sub through a resonant
#                lowpass (the :cut knob opening 700 Hz -> 3.5 kHz), so it
#                speaks in the upper mids over the kick; in the last 4
#                bars a bandpass noise riser, and in the last bar the
#                bass holds one G1 instead of its eighths, diving four
#                octaves until the wavetable's cycles are single kicks
#                (same track, key, and level)
#   drop      8  dry: the sub and the open talking bass together, hats on
#                every 16th, a crash and a sub "boom" on the downbeat
#   pickup    8  the same bass through the ghost chords i-iv-VII-VI, a
#                ride, a second boom
#   breakdown 8  kick and low end out (the master's :air highpass up to
#                220 Hz), hats and shaker keep going; a pad (root and
#                fifth, leading the beat by 0.3 of its attack) and a
#                "Delay Lama" chant (a tenor formant on a pair of saws in
#                the 100 Hz range, short sung "oo-ah" stabs) on the same
#                ghost chords, its dotted-eighth echoes filling the gaps;
#                a delay throw on the last 2 beats
#   lift      8  the chant and pad go on over a light kick (still no low
#                end: it all comes back at once in drop2), riser again
#   gap       1  one bar of 2/4: everything rings out for a half-bar breath
#   drop2     8  low end back, the talking bass on i-VI-III-VII, boom
#   pickup2   8  a seeded pick: the ride pickup (default seed, two times in
#                three), or (--seed 3) the chant answering the bass (a
#                swap-up: call and response)
#   outro     8  the bass closing into its filter, simple drums
#   tail      8  kick and hats for the DJ, then the end rings out
#
# The mix: the kick ducks the bass parts -18 dB (Dynamics#duck from a
# ghost kick: the same 808 kick, inside each ducked track), the drums get
# parallel compression, and the master runs a gentle glue compressor into a
# true-peak limiter at -0.5 dBTP (SMALL_TALK_CEILING), driven 6 dB
# (SMALL_TALK_DRIVE; -D and -C change them).  The master bus is at 0 dB (master_gain 1)
# instead of the usual -10 dB: this is a mastered, share-ready track, and
# the limiter is what keeps it from clipping (the maintainer's OK,
# 2026-10-12).  As rendered (round 3): -13.0 LUFS integrated, -0.5 dBTP,
# PLR 12.5 dB (the drops: -11.8 LUFS, PLR 11.3, crest factor 12.3 dB;
# round 2's 4 dB into -1 dBTP: -14.7, PLR 13.7, drops 12.4).  320k mp3s of
# it decode at -0.2 dBTP; a ceiling above -0.5 can go over 0 dBTP in
# lossy copies.  Before the master the kick-plus-clap hits on 2 and 4 peak
# about +5 dB over full scale, so stems need --stem-gain -6 (the render
# warns).
#
# Usage:
#     bin/songs/small_talk.rb                    # plays live in the background session
#     bin/songs/small_talk.rb small_talk.flac    # renders to a file instead (-f to overwrite)
#     bin/songs/small_talk.rb --stems stems/ small_talk.flac   # plus one file per track (before the master chain)
#     bin/songs/small_talk.rb --seed 3 out.flac  # the other branch of the pick (the chant answers)
#     bin/songs/small_talk.rb --round1 out.flac  # the first round's talking bass (crush 0.4, no cut, air, or squeeze)
#     bin/songs/small_talk.rb -a 0 out.flac      # no waveshaped high end
#     bin/songs/small_talk.rb -m 0.4 out.flac    # more crusher
#     bin/songs/small_talk.rb -H 0 out.flac      # a pure sine sub (-H 0.2 for round 3's lighter harmonics)
#     bin/songs/small_talk.rb --bong-tom out.flac   # round 2's tom-like groove bass
#     bin/songs/small_talk.rb -D 4 -C -1 out.flac   # round 2's master (-D 7.5 -C -0.3: hotter)
#     bin/songs/small_talk.rb --help             # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/small_talk.rb'
#     small_talk                  # tracks and scenes only (go :drop etc. by hand), then
#     small_talk_form             # play the form and steer it yourself
#     small_talk(perform: true)   # or the whole performance
#
# Try (while it plays):
#     go :drop                    # straight to the talking bass
#     swap :talk, SMALL_TALK_HOOK.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :g), harmonic: true)  # harmonic minor
#     swap :talk, SMALL_TALK_HOOK.ghost_chords(1, 4, per: 2.beats, scale: scale(:minor, :g))          # two chords a bar
#     turn :cut, 900, over: 2     # close the bass's filter over 2 bars (turn :cut, 16000 to open)
#     turn :sub, 0; turn :sub, 1, on: :bar   # the sub out, and back on the next bar
#     turn :space, 1, over: 1.n16; turn :echo, 0.7, over: 1.n16   # throw the chant's delay...
#     turn :space, 0.3, over: 1.n8; turn :echo, 0.3, over: 1.beat  # ...and back
#     move :air, 220; undo        # the low end out, then back at the next bar
#     practice :drop2             # stay in the second drop
#     finish                      # the outro next
#
# Listening notes: the talking bass's vowels open over 3.6 bars and snap
# back in the last 0.4 of every 4 (so each 4-bar phrase "says" one long
# word); the dives after the rests reach ~12-15 Hz, where each wavetable
# cycle is nearly a single kick, and the tease's last bar slows a held
# G1 to about 3 Hz the same way.  The sub's 2nd and 3rd harmonics (-H
# 0.4, the 3rd half of it; 0 for a pure sine; 0.4 since 2026-10-13, the
# maintainer's "0.35 ... I might push the harmonics a little higher
# still", round 3 had 0.2) add about 2.4 dB at 90-160 Hz in the drop
# (0.2: 1.7 dB), for speakers without much below 100 Hz; the sub's RMS
# stays the same.  On laptop speakers listen for the
# bass's pitch in the 200-600 Hz formants: it should follow the ghost
# chords.
#
# Cost (whole render through the Session and master chain, YJIT, the Mac's
# container, 2026-10-12, round 3): 512-sample buffers mean 22% of
# realtime, p99 54% (round 2 at 128-sample buffers: mean 42%, p99 87%).
# The talking bass stays loaded from the intro on (a silent clip between
# its sections), since building it takes up to ~0.8 s; the slowest scene
# change left builds the breakdown's chant and pad in 0.67-0.85 s, inside the
# scheduler's half-bar (0.96 s) lookahead.  Render-thread spikes of up to
# ~300 ms where scenes land are library cost (night_bus_flow: ~270 ms).

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/vocal_lead'
require_relative '../synths/fifth_pad'

module MB::Sound
  # The length of the performance in bars (to the end of the tail's ring
  # out, with the default seed).
  SMALL_TALK_BARS = 92

  # The gain in dB into the master limiter and its true-peak ceiling in
  # dBTP (round 3; maintainer, 2026-10-12: "I like the drive and the
  # pumping; it could even tolerate a bit more possibly.  Production dance
  # tracks will be pretty low crest factor and as close to max true peak as
  # possible"; round 2 was 4 dB into -1 dBTP).
  SMALL_TALK_DRIVE = 6.0
  SMALL_TALK_CEILING = -0.5

  # One swing for every part that plays sixteenths.
  SMALL_TALK_SWING = 0.54

  # The 808 kick's knobs (the drums and the ghost kicks that duck the bass
  # parts share them, so the duck follows the kick heard).
  SMALL_TALK_KICK = { tune: 49, decay: 0.45, tone: 0.45 }.freeze

  # The talking bass's hook: two bars of sixteenths in the bass octave
  # (G1-D2), mostly off the kicks, notes before rests diving.
  SMALL_TALK_HOOK_STEPS = [
    R, R, G1, T, T, T, G1, T, R, R, Bb1, T, G1, T, T, R,
    R, R, G1, T, T, T, D2, T, T, R, C2, T, Bb1, T, G1, T,
  ].freeze
  SMALL_TALK_HOOK = seq(*SMALL_TALK_HOOK_STEPS).n16.swing(SMALL_TALK_SWING).loop(align: :launch)

  # The tease's 8 bars of the talking bass: the hook three and a half
  # times, then one G1 held for the whole last bar, which the patch dives
  # toward zero (see .small_talk_bass's +dive+): the same track, key, and
  # level, replacing that bar's faster notes (maintainer, 2026-10-12).
  SMALL_TALK_TEASE = seq(
    *SMALL_TALK_HOOK_STEPS * 3, *SMALL_TALK_HOOK_STEPS.first(16), G1, *[T] * 15,
  ).n16.swing(SMALL_TALK_SWING).loop(align: :launch)

  # The chant's motif: one bar on the G minor triad (repeated and moved by
  # the ghost chords).
  SMALL_TALK_CHANT = seq(D3, R, R, Bb2, R, R, C3, Bb2).n8.loop(align: :launch)

  # A drum Kit with every row (empty rows are rests), so scenes swap kits
  # without rebuilding the drums.  Hat, shaker, and ride rows swing.  With
  # +crash: true+, a crash on the first bar of every 8 from the launch.
  def self.small_talk_kit(crash: false, **rows)
    all = { kick: '', clap: '', hat: '', open_hat: '', shaker: '', ride: '', crash: '', low_tom: '', mid_tom: '' }.merge(rows)
    all[:crash] = 'X...............' if crash
    kit = grid(16, **all.transform_values { |p| p.empty? ? '.' * 16 : p })
    Sequence::Kit.new(kit.rows.to_h { |name, clip|
      clip = clip.swing(SMALL_TALK_SWING) if [:hat, :shaker, :ride].include?(name)
      clip = clip.every(8) if name == :crash
      [name, clip]
    })
  end

  # The kits, each with fills: a clap roll in the last bar of every 8 (the
  # :turn phrase fill; the plain clap and open hats step aside) and a tom
  # answer in the last bar of every 4 (:toms).
  def self.small_talk_kits
    turn = ->(kit) {
      kit
        .nofill(:clap, :open_hat, name: :turn)
        .fill(:turn, clap: grid(16, '....X...x.x.xXXX', value: 39))
        .fill(:toms, low_tom: grid(16, '...........x..x.', value: 45), mid_tom: grid(16, '............x..x', value: 48))
    }
    kick = 'X...x...X...x...'
    clap = '....X.......X...'
    shaker = '3735373537353735'
    sixteenths = 'xxXxxxXxxxXxxxXx' # every 16th, offbeat eighths accented: the grid on small speakers
    {
      intro: turn.(small_talk_kit(kick: kick, hat: '..x...x...x...x.', shaker: shaker)),
      groove: turn.(small_talk_kit(kick: kick, clap: clap, hat: '..x...x...x...x.', open_hat: '..x.......x.....', shaker: shaker)),
      tease: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, shaker: shaker)),
      drop: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, open_hat: '..x...x...x...x.', crash: true)),
      pickup: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, shaker: shaker, ride: '6.4.6.4.6.4.6.4.', crash: true)),
      cut: turn.(small_talk_kit(clap: clap, hat: sixteenths, shaker: shaker)),
      lift: turn.(small_talk_kit(kick: 'x...x...x...x...', clap: clap, hat: sixteenths, shaker: shaker)),
      outro: turn.(small_talk_kit(kick: kick, clap: clap, hat: '..x...x...x...x.', shaker: shaker)),
      tail: small_talk_kit(kick: kick, hat: '..x...x...x...x.'),
    }.transform_values { |kit| kit.loop(align: :launch) }.each { |name, kit| kit.named(:"kit_#{name}") }
  end

  # The clips of the song, by name.
  def self.small_talk_clips
    gm = scale(:minor, :g)
    {
      # The talking bass: the hook alone (implying Gm), then through two
      # silent progressions (natural minor; the maintainer's pick of
      # 2026-10-11 over harmonic minor)
      talk: SMALL_TALK_HOOK,
      talk_tease: SMALL_TALK_TEASE,
      talk_ghost: SMALL_TALK_HOOK.ghost_chords(1, 4, 7, 6, scale: gm).loop(align: :launch),
      talk_ghost2: SMALL_TALK_HOOK.ghost_chords(1, 6, 3, 7, scale: gm).loop(align: :launch),
      # The chant on i-iv-VII-VI (breakdown), and answering the bass in
      # the second drop: rests where the bass talks (bars 1 and 3 of 4),
      # the second progression in bars 2 and 4
      chant: SMALL_TALK_CHANT.ghost_chords(1, 4, 7, 6, scale: gm).loop(align: :launch),
      answer: seq(R.n1, D3.n4.d, Bb2.n4.d, C3.n8, Bb2.n8, R.n1, F3.n4.d, D3.n4.d, Eb3.n8, D3.n8).loop(align: :launch),
      # The groove's bong bass: offbeats with a swung 16th push
      bong: seq(R, R, G1, T, R, R, G1, T, R, R, G1, T, R, R, G1, G1).n16.swing(SMALL_TALK_SWING).loop(align: :launch),
      bong_tom: seq(R, R, G1, R, R, R, G1, R, R, R, G1, R, R, R, G1, G1).n16.swing(SMALL_TALK_SWING).loop(align: :launch),
      # The pad: root and fifth (fifth_pad), i-iv-VII-VI
      pad: seq(G2, C3, F2, Eb2).n1.legato(0.98).loop(align: :launch),
      # The impact on the first bar of every 8
      boom: seq(G1, R, R, R, R, R, R, R).n1.loop(align: :launch),
      # A placeholder clip for clipless patches (the riser)
      bar: seq(R).n1.loop,
    }.each { |name, clip| clip.named(name) }
  end

  # A ghost kick for sidechains: the drums' 808 kick on every beat, never
  # heard (the drum kits all keep four on the floor while the ducked parts
  # play).
  def self.small_talk_ghost_kick
    tr808(grid(16, kick: 'X...X...X...X...').loop(align: :launch), kick: SMALL_TALK_KICK)
  end

  # The talking bass: vocal_lead_patch (kick wavetable, crusher key
  # tracking 1, a 4-bar LFO skewed to 0.9, two-octave dives) plus a sine
  # sub on the same notes.
  #
  # Round 2 (maintainer, 2026-10-12: "a little bit too resonant in the
  # midrange and could use some upper frequency extension ... a different
  # source of high end rather than the decimation aliasing would be
  # better"; and from the vocal song, "a lot less decimation"): the
  # crusher is down to +crush_mix+ 0.15 (was 0.4), a broad -7 dB cut sits
  # on the formant pile-up at 320 Hz, and the high end comes from
  # waveshaping instead: the part above 700 Hz driven into a soft clipper,
  # highpassed at 1.1 kHz, mixed in at +air+ (0 for none), then a
  # three-band squeeze lifts the quiet upper partials.  Measured over the
  # pickup (bands relative to the loudest): 2.5-10 kHz from -21..-25 dB
  # (crush 0.4, no air) to -16..-18 dB.
  #
  # +cutoff+ (the :cut knob) is a lowpass over the whole part with a
  # little resonance (the tease's filtered bass speaks in the upper mids),
  # +sub+ (the :sub knob) the sine sub's level (0 in the tease, so the low
  # end arrives with the drop).  +round1: true+ builds the first round's
  # sound (crush 0.4, no cut, no air, no squeeze) for comparisons.
  #
  # Round 3 (maintainer, 2026-10-12):
  # - Held notes dive: a note still sounding +dive_after+ seconds after
  #   its note-on (no note of the hook, release included; the tease's
  #   last bar is) falls +dive+ semitones
  #   over the next 1.25 s, evenly in semitones (48: G1 49 Hz to 3 Hz,
  #   where the kick wavetable's cycles are single kicks).  "The 1 bar
  #   drop bass should be in the same track+key and at the same level so
  #   it replaces the faster paced notes for that bar."  The time comes
  #   from a ramp reset on every note-on (no velocity scaling), and the
  #   patch's 90 Hz highpass keeps DC and subsonics out.
  # - The sub gets a little 2nd and 3rd harmonic, +sub_harmonics+ (levels
  #   of sines at 2x and 3x, phase-locked to the sub; [0, 0] for a pure
  #   sine): "A tiny bit of second and maybe third harmonic on the sub
  #   might help cut through a bit more on medium sized speakers".  The
  #   sub's level is scaled down to keep its RMS.
  def self.small_talk_bass(clip, cutoff: 16000, sub: 1, crush_mix: 0.15, air: 0.4, skew: 0.9, round1: false,
                           dive: 48, dive_after: 0.75, sub_harmonics: [0.4, 0.2])
    crush_mix = 0.4 if round1 && crush_mix == 0.15
    talk = synth(clip, voices: 1) { |v|
      fall = nil
      if dive && dive > 0
        # Seconds since the last note-on: a naive ramp at 0.2 Hz reset by
        # every note-on (0 to 1 over 2.5 s; envelopes don't restart on
        # back-to-back notes in a mono lane, so the hook's legato chains
        # would have dived), then 0 for the first +dive_after+ seconds
        # and down over the rest of 2 s
        held = 0.2.hz.aramp.reset(v.trigger) * 2.5
        fall = (held - dive_after).aclip(0, 2.0 - dive_after) * (-dive / (2.0 - dive_after))
      end
      vocal_lead_patch(v, wobble: 4.bars, skew: skew, drop: 2, crush_mix: crush_mix, crush_track: 1.0, gain: 1.15, transpose: fall)
    }
    unless round1
      body = talk.peq(320.hz => [-7.db, 0.8])
      talk = if air > 0
               shine = (talk.filter(:highpass, cutoff: 700, quality: 0.7) * 6).softclip(0.2, 0.9).filter(:highpass, cutoff: 1100, quality: 0.7)
               (body + shine * air).squeeze(:default, depth: 0.6, split: [250, 2500])
             else
               body.squeeze(:default, depth: 0.6, split: [250, 2500])
             end
    end
    h2, h3 = sub_harmonics
    low_sub = synth(clip, voices: 1) { |v|
      pitch = v.hz.glide(0.04, legato: true)
      tone = pitch.sine
      tone = (tone + pitch.transpose(12).sine * h2 + pitch.transpose(12 * Math.log2(3)).sine * h3) * (1 / Math.sqrt(1 + h2**2 + h3**2)) if h2 > 0 || h3 > 0
      tone * v.env(0.004, 0.3, 0.8, 0.08, gm: false).legato
    }
    echo = talk.delay(1.n8.dotted, feedback: 0.25, wet: 1, dry: 0).filter(:highpass, cutoff: 500, quality: 0.7) * 0.12
    low = ((talk + echo) * (round1 ? 0.6 : 0.7) + low_sub * sub * 0.34).filter(:lowpass, cutoff: cutoff, quality: round1 ? 0.8 : 1.3)
    low.duck(small_talk_ghost_kick).reverb(:hall, mix: 0.07, highpass: 300, output_channels: 2)
  end

  # The groove's bong bass: offbeat notes ducked by the kick, saturated
  # so their harmonics carry the pitch on small speakers.
  #
  # Round 3 (maintainer, 2026-10-12, on its stem: "sounds more like a
  # muted low tom drum ... It doesn't sound long enough to come across as
  # notably pitched"): eighth notes instead of sixteenths, a decay to a
  # sustain instead of to silence, a smaller and shorter pitch bump, and
  # more of the lowpassed saw under the sine.  +tom: true+ builds the old
  # tom-like sound (with the old sixteenth clip, c[:bong_tom]).
  def self.small_talk_bong(clip, tom: false)
    synth(clip, voices: 1) { |n|
      if tom
        bump = n.env(0.0005, 0.035, 0, 0.02, curve: :linear, gm: false)
        freq = n.freq * (bump * 0.7 + 1)
        fenv = n.env(0.001, 0.07, 0, 0.04, gm: false)
        amp = n.env(0.001, 0.16, 0, 0.05, gm: false) * (n.velocity * 0.4 + 0.6)
        saw = freq.tone.ramp.lp4((2 ** (fenv * 2)) * 420, resonance: 0.3)
        ((saw * 0.7 + freq.tone) * amp * 1.6).softclip(0.4, 0.95)
      else
        bump = n.env(0.0005, 0.015, 0, 0.01, curve: :linear, gm: false)
        freq = n.freq * (bump * 0.15 + 1)
        fenv = n.env(0.001, 0.12, 0.3, 0.05, gm: false)
        amp = n.env(0.002, 0.18, 0.55, 0.06, gm: false) * (n.velocity * 0.4 + 0.6)
        saw = freq.tone.ramp.lp4((2 ** (fenv * 1.5)) * 380, resonance: 0.25)
        ((saw * 1.1 + freq.tone) * amp * 1.3).softclip(0.4, 0.95) * 0.65 # (longer notes; 4.5 dB above the tom version in the groove)
      end
    }.duck(small_talk_ghost_kick) * 0.55
  end

  # The chant ("Delay Lama"): a pair of slightly detuned saws through the
  # tenor formant table.  Each note is a short sung stab: a fast attack,
  # the vowel sliding "oo" to "ah" in 80 ms and settling between them, a
  # quick decay to a low level (round 2; maintainer, 2026-10-12: "The
  # formant sound is too sustained for the send to be audible.  A more
  # fast attack/decay sound helps show off a delay line and throw much
  # better").  Dry on the grid; +send+ and +feedback+ (the :space and
  # :echo knobs) are its dotted-eighth delay send.
  def self.small_talk_chant(clip, send: 0.3, feedback: 0.3, level: 0.7)
    chant = synth(clip, voices: 1) { |v|
      pitch = v.hz.glide(0.03, legato: true).vibrato(5.3, depth: 18.cents, delay: 0.15)
      saws = pitch.saw * 0.5 + pitch.transpose(0.1).saw * 0.5
      vowel = v.env(0.08, 0.25, 0.55, 0.2, curve: :smooth, gm: false)
      sung = saws.formant(:u, :o, :a, voice: :tenor, morph: vowel)
      (sung * v.env(0.004, 0.2, 0.12, 0.12, gm: false)).filter(:highpass, cutoff: 140, quality: 0.7)
    }
    (chant * level).delay(1.n8.dotted, feedback: feedback, wet: send, dry: 1).reverb(:hall, mix: 0.18, output_channels: 2)
  end

  # The impact: a sine falling two octaves to the root, with a short
  # click, into a hall.
  def self.small_talk_boom(clip)
    synth(clip, voices: 1) { |n|
      dive = n.env(0, 0.3, 0, 0.1, curve: :linear, gm: false)
      freq = n.freq * (2 ** (dive * 2))
      (freq.tone * n.env(0.001, 1.4, 0, 0.3, gm: false) * 1.3).softclip(0.5, 0.95)
    }.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.35
  end

  # A white-noise riser: a resonant bandpass sweeping up over 4 bars with a
  # swell (maintainer, 2026-10-12: "noise risers better with a bandpass
  # sweep than a highpass").
  def self.small_talk_riser
    sweep = tween([300, 9000], 4.bars, log: true, loop: false)
    noise.filter(:bandpass, cutoff: sweep, quality: 2.5) * tween([0.04, 0.22], 4.bars, loop: false)
  end

  # Sets up the song on the current session: tempo, knobs, master, tracks,
  # scenes (each section of the form launches the scene of its name).
  # With +perform: true+, also plays the form and schedules the performer's
  # commands.  Returns the clips.  +crush_mix+ and +air+ are the talking
  # bass's crusher share and waveshaped high end (+round1: true+ for the
  # first round's bass), +pad_lead+ the pad's lead (0.3 of its attack:
  # the maintainer's default, 2026-10-12), +sub_harmonics+ the levels of
  # the sub's 2nd and 3rd harmonics, +bong_tom+ the groove bass's old
  # tom-like sound, +drive+ the gain in dB into the master limiter and
  # +ceiling+ its true-peak ceiling in dBTP.
  def self.small_talk(perform: false, seed: 2, crush_mix: 0.15, air: 0.4, round1: false, skew: 0.9, pad_lead: 0.3.attack,
                      sub_harmonics: [0.4, 0.2], bong_tom: false, drive: SMALL_TALK_DRIVE, ceiling: SMALL_TALK_CEILING)
    c = small_talk_clips
    k = small_talk_kits
    bpm 125
    quant 1

    knob :cut, 16000, range: 200..16000, curve: :exp, unit: 'Hz' # the talking bass's lowpass
    knob :space, 0.3, range: 0..1                              # the chant's delay send
    knob :echo, 0.3, range: 0..0.85                            # the chant's delay feedback
    knob :air, 20, range: 20..400, curve: :exp, unit: 'Hz'     # a master highpass (the breakdown's "cut")
    knob :sub, 1, range: 0..1                                  # the talking bass's sine sub (out in the tease)

    # A mastered track: the master bus at 0 dB, glue, a true-peak limiter
    master_gain 1
    master { |mix|
      glued = mix.filter(:highpass, cutoff: knob(:air), quality: 0.8)
        .compress(threshold: -16.db, ratio: 2, knee: 8, attack: 0.02, release: 0.2)
      (glued * drive.db).limit(ceiling: ceiling.db, release: 0.08)
    }

    track(:drums) { |kit|
      beat = tr808(
        kit,
        kick: SMALL_TALK_KICK, clap: { decay: 0.3, tone: 0.75, level: 0.75 },
        closed_hat: { decay: 0.035, tone: 0.6, level: 0.4 }, open_hat: { decay: 0.22 }, cymbal: { decay: 1.0, tone: 0.65 },
        maracas: { level: 0.3 }, low_tom: { decay: 0.5 }, mid_tom: { decay: 0.45 }, accent: 6
      )
      # Parallel ("New York") compression: the hits keep their shape, the
      # room between them comes up
      beat.compress(threshold: -26.db, ratio: 4, attack: 0.003, release: 0.08, makeup: 8, mix: 0.3)
    }
    track(:bong) { |clip| small_talk_bong(clip, tom: bong_tom) }
    track(:talk) { |clip| small_talk_bass(clip, cutoff: knob(:cut), sub: knob(:sub), crush_mix: crush_mix, air: air, skew: skew, round1: round1, sub_harmonics: sub_harmonics) }
    track(:chant) { |clip| small_talk_chant(clip, send: knob(:space), feedback: knob(:echo)) }
    track(:answer) { |clip| small_talk_chant(clip, level: 0.55) }
    track(:pad, lead: pad_lead) { |clip| stereo(*fifth_pad(clip, voices: 2, cutoff: 1100, release: 2)) * 0.4 }
    track(:boom) { |clip| small_talk_boom(clip) }
    track(:riser, fade: 1/8r) { |_clip| small_talk_riser } # a tween, not notes: fades instead of ringing

    # The talking bass stays loaded (on a silent clip) from the start:
    # building it takes up to ~0.8 s (squeeze, formants, reverb, plan),
    # close to the scheduler's half-bar lookahead (0.96 s), and a scene
    # that swaps clips keeps the graph instead of rebuilding it
    scene :intro, drums: k[:intro], talk: c[:bar], cut: 16000, air: 20, sub: 1
    scene :groove, drums: k[:groove], bong: bong_tom ? c[:bong_tom] : c[:bong], talk: c[:bar]
    scene :tease, drums: k[:tease], talk: c[:talk_tease], cut: [3500, from: 700, over: 8, curve: :smooth], sub: 0
    scene :drop, drums: k[:drop], talk: c[:talk], boom: c[:boom], cut: 16000, sub: 1
    scene :pickup, drums: k[:pickup], talk: c[:talk_ghost], boom: c[:boom]
    scene :breakdown, drums: k[:cut], pad: c[:pad], chant: c[:chant], talk: c[:bar], air: [220, over: 1.beat], space: 0.3, echo: 0.3
    scene :lift, drums: k[:lift], pad: c[:pad], chant: c[:chant], talk: c[:bar]
    scene(:gap, talk: c[:bar]) { meter 2, 4 }
    scene(:drop2, drums: k[:drop], talk: c[:talk_ghost2], boom: c[:boom], cut: 16000, air: 20) { meter 4, 4 }
    scene :pickup2, drums: k[:pickup], talk: c[:talk_ghost2], boom: c[:boom]
    scene :callback, drums: k[:pickup], talk: c[:talk_ghost2], answer: c[:answer], boom: c[:boom]
    scene :outro, drums: k[:outro], talk: c[:talk_ghost], cut: [350, over: 8, curve: :smooth]
    scene :tail, drums: k[:tail]
    scene :riser, riser: c[:bar], others: :keep # a fill: adds the riser

    small_talk_performance(seed: seed) if perform
    c
  end

  # The song form (sections launch the scenes of their names).  With
  # +play: false+, builds the Form without playing it.
  def self.small_talk_form(seed: 2, play: true)
    flow(seed: seed, play: play) do
      fill :turn, every: 8
      fill :toms, every: 4
      intro     8
      groove    8
      tease     8, fill: [:riser, 4]
      drop      8
      pickup    8
      breakdown 8
      lift      8, fill: [:riser, 4]
      gap       1
      drop2     8
      pick do |p|                    # usually the ride pickup...
        p.option(2) { pickup2 8 }
        p.option(1) { callback 8 }   # ...sometimes the chant answers the bass
      end
      outro     8
      tail      8
    end
  end

  # The performance: the form, plus what the performer types (printed as
  # it runs).
  def self.small_talk_performance(seed: 2)
    say = ->(bar, line) { puts format("\e[2mbar %-5s\e[0m \e[36m›\e[0m %s", bar, line) }

    say[1, 'flow do ... end   # the form starts']
    small_talk_form(seed: seed)
    at_marker(:breakdown) {
      session = Session.current
      bar = session.transport.bar_at(session.now).floor + 7
      at_bar(bar, beat: 3) {
        say["#{bar}.3", 'turn :space, 1, over: 1.n16; turn :echo, 0.7, over: 1.n16   # throw the chant']
        turn :space, 1, over: 1.n16
        turn :echo, 0.7, over: 1.n16
      }
      at_bar(bar + 1, beat: 2) {
        say["#{bar + 1}.2", 'turn :space, 0.3, over: 1.n8; turn :echo, 0.3, over: 1.beat   # and back']
        turn :space, 0.3, over: 1.n8
        turn :echo, 0.3, over: 1.beat
      }
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: SMALL_TALK_BARS,
      seed: [2, 'Seed for the form\'s pick (the second pickup; 2 the ride pickup, 3 the call and response)', '-s', Integer, 0..1_000_000],
      crush_mix: [0.15, Float, '-m', 'Talking bass crusher wet share 0..1', 0.0..1.0],
      air: [0.4, Float, '-a', 'Talking bass waveshaped high end (0 for none)', 0.0..2.0],
      round1: [false, 'The first round\'s talking bass (crush 0.4, no midrange cut, air, or squeeze)'],
      skew: [0.9, Float, '-k', 'Talking bass LFO skew (rising fraction; 0.5 a plain triangle)', 0.01..0.99],
      sub_harmonics: [0.4, Float, '-H', 'Sub 2nd harmonic level (the 3rd is half of it; 0 for a pure sine)', 0.0..1.0],
      bong_tom: [false, 'The groove bass\'s old tom-like sound (round 2)'],
      drive: [SMALL_TALK_DRIVE, Float, '-D', 'Gain in dB into the master limiter', -20.0..20.0],
      ceiling: [SMALL_TALK_CEILING, Float, '-C', 'Master limiter true-peak ceiling in dBTP', -12.0..0.0],
    ) { |p|
      small_talk(
        perform: true, seed: p.seed, crush_mix: p.crush_mix, air: p.air, round1: p.round1, skew: p.skew,
        sub_harmonics: [p.sub_harmonics, p.sub_harmonics / 2], bong_tom: p.bong_tom, drive: p.drive, ceiling: p.ceiling
      )
    }
  end
end
