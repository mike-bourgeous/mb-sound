#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# "N109" by Kez Volta (persona panel round 3): half-time drum & bass at 174 BPM in F Phrygian, a two-step second drop.
#
# Kez Volta is a fictional producer-DJ written for the persona panel (he
# also wrote "Tunnel Vision", bin/songs/tunnel_vision.rb).  He wrote this
# B-side in the panel's third round (the dry run of 2026-11-09/10), then a
# second version after the producer's listen; both live here, chosen by
# --version (n109-1, 2026-11-22; the maintainer: "add N109 with an option
# to switch v1/v2").  Its sounds are library presets now
# (bin/synths/halftime.rb: ghost_voice, talking_sub, tape_pad,
# tape_pad_high, notch_reese, clack_kit, window_rain, vinyl_specks; the
# master is dnb_master's options, the stop bell the struck rin).  Kez's
# header, as he wrote it:
#
# N109  (Kez Volta)  --  the B-side
#
# The N109 is the night bus home to Croydon.  Top deck, front seat, rain on
# the glass, somebody's tune leaking out of their headphones three rows back,
# and your ears still ringing from the room you just left.  That's the tune.
#
# 174, F Phrygian (Fm to Gbmaj7 and back, for ever).  It walks at half speed
# with the clack on the three; the second drop wakes up into a proper
# two-step for sixteen, then sits back down.
#
#   bars   1- 32  intro      weather, clicks, hats; kick from 17, clack from 25
#   bars  33- 64  drop 1     half-time, sub, the voice
#   bars  65- 80  breakdown  no drums; the voice smeared out to 8 bars long
#   bars  81- 96  drop 2a    THE SWITCH: two-step, sub talks, ride
#   bars  97-112  drop 2b    back to half-time, everything, a Reese underneath
#   bars 113-144  outro      strip it back for the DJ; ends on rain
#
# v2, after the producer's listen:
#   - rain and downpour pulled back 3 dB and pushed into the hall and the dub
#     delay, so they're outside the window instead of on the mixing desk
#     (the vinyl specks stay bone dry on purpose: that's the record, not the weather)
#   - the voice is mostly breath now: noise filtered at the sung pitch and its
#     2nd and 3rd harmonics, fed into the same formant filter as the saws
#   - one new thing in the breakdown: the stop bell (bars 69-80), and it gets
#     one more go in the outro
#   - my own: more weight under the snare in the two-step drop
#
# How the versions map here: the instruments' variant knobs (0 the first
# version, 1 the second; bin/synths/halftime.rb) carry the voice, the
# rain's level, and the clap; the rain's and downpour's bus sends fade by
# the same laws; the stop bell, a part only the second version has, comes
# with --version 2.  --variant sets the knobs between the two (0.5: half
# way, in dB and in log time) while --version still picks the parts.
#
# Usage:
#     bin/songs/n109.rb                       # plays version 2 live
#     bin/songs/n109.rb --version 1 n109.flac # renders the first version (-f to overwrite)
#     bin/songs/n109.rb --variant 0.5 --report n109-half.flac
#     bin/songs/n109.rb --stems stems/ n109.flac
#     bin/songs/n109.rb --from 65 --bars 16 --seek breakdown.flac
#
# Or in bin/sound.rb:
#     load 'bin/songs/n109.rb'
#     rewind; n109 version: 1                # bg players and at_bar blocks from bar 1 (stop or panic ends it)
#
# The instruments on their own (bin/sound.rb):
#     bpm 174
#     track :voice, seq(C4.n4, Eb4.n4, F4.n2, R.n1).legato(1).loop, :ghost_voice
#     turn :"voice/variant", 1, over: 8.bars    # the ghost fades from v1 to v2
#     bg :rain, preset(:window_rain)            # turn :"rain/variant", 1 takes it outside

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/dnb'
require_relative '../synths/halftime'

module MB::Sound
  # 144 bars of tune + 2 for the tails.
  N109_BARS = 146

  # The arrangement as data: one 16-step string per bar per drum, one list
  # of 16ths per bar for the sub and the voices (Kez's: "Sample-exact,
  # nothing scheduled, nothing drifts").  Returns a Hash of :drum (row =>
  # bar strings), :sub, :swell, :vox, :ans (bars of steps).
  def self.n109_parts
    bars = N109_BARS
    drum = Hash.new { |h, k| h[k] = Array.new(bars) { '.' * 16 } }
    lay  = ->(row, range, pats) { range.each_with_index { |b, i| drum[row][b - 1] = pats[i % pats.size] } }

    # Half-time: kick on the one, clack on the three, kicks walking round it.
    ht_k = ['X.........x.....', 'X.....x...x..x..', 'X.........x.....', 'X..x......x...x.']
    ht_s = ['........X.......', '........X.......', '........X.......', '........X..3....']
    # Two-step, one line each, as God intended.
    ts_k = ['X.........x.....', 'X.........x.....', 'X.........x.....', 'X......x..x.....']
    ts_s = ['....X.......X...', '....X.......X...', '....X.......X...', '....X.......X.4.']

    lay.(:kick,  17..32,  ['X.........x.....'])
    lay.(:snare, 25..32,  ['........X.......'])
    lay.(:kick,  33..64,  ht_k);  lay.(:snare, 33..64,  ht_s)
    lay.(:kick,  77..80,  ['6...............'])                 # heartbeat under the breakdown
    lay.(:kick,  81..96,  ts_k);  lay.(:snare, 81..96,  ts_s);  lay.(:clap, 81..96, ['....X.......X...'])
    lay.(:kick,  97..112, ht_k);  lay.(:snare, 97..112, ht_s)
    lay.(:kick,  113..128, ht_k); lay.(:snare, 113..128, ['........X.......'])
    lay.(:kick,  129..136, ['X.........x.....'])

    # Phrase ends.  A hole says more than a fill.
    drum[:snare][31] = '........X.......'; drum[:kick][31] = 'X...............'   # 32: clear the last beat
    drum[:snare][47] = '........X...3.5.'                                        # 48
    drum[:kick][63]  = 'X.....x.........'; drum[:snare][63] = '........X.......' # 64: hole before the break
    drum[:snare][79] = '..........3.4.6.'                                        # 80: three knocks on the door
    drum[:snare][95] = '....X.......X.X.'                                        # 96
    drum[:kick][111] = 'X..x............'; drum[:snare][111] = '........X.......' # 112

    # Clicks: threes against the bar, the wiper against the indicator.  All tune.
    lay.(:rim, 1..144,   ['5..3..5..3..5.3.', '5..3..5..3.5..3..'])
    lay.(:rim, 65..80,   ['3.....2.....3...', '3.....2...2.....'])
    lay.(:rim, 137..144, ['4.....3.....4...', '4.....3.........'])
    # Hats dead on the beat; 8ths when it goes two-step.
    lay.(:hat, 9..64,    ['x...x...x...x...'])
    lay.(:hat, 81..96,   ['x.6.x.6.x.6.x.6.'])
    lay.(:hat, 97..140,  ['x...x...x...x...'])
    # Shakers (these get played 21 ms late, see below).
    lay.(:open_hat, 17..64,  ['..5...5...5...7.'])
    lay.(:open_hat, 81..128, ['..5...5...5...7.'])
    # Ride for the switch, and again to lift the last eight of drop 2.
    lay.(:ride, 81..96,   ['6.x.6.x.6.x.6.x.'])
    lay.(:ride, 105..112, ['6.x.6.x.6.x.6.x.'])

    # ---- sub, in 16ths --------------------------------------------------------
    sub_bars = Array.new(bars) { [R] * 16 }
    put = ->(arr, range, pats) { range.each_with_index { |b, i| arr[b - 1] = pats[i % pats.size] } }
    hold = ->(n, len = 14) { [n] + [T] * (len - 1) + [R] * (16 - len) }
    # Half-time: long swells.  F, F, Gb, Gb with an Ab leaning back to the F.
    ht_sub = [hold.(F1), hold.(F1), hold.(Gb1), [Gb1] + [T] * 9 + [Ab1, T, T, T, R, R]]
    # Two-step: written ROUND the kick (it answers two 16ths late), no sidechain needed.
    ts_sub = [
      [R, R, F1, T, T, T, T, R,    F1, T, R, R,  F1, T, T, R],
      [R, R, F1, T, T, T, Ab1, T,  R, R, R, R,   F1, T, T, T],
      [R, R, Gb1, T, T, T, T, R,   Gb1, T, R, R, Gb1, T, T, R],
      [R, R, Gb1, T, T, T, Ab1, T, R, R, R, R,   Gb1, T, T, R]
    ]
    put.(sub_bars, 33..64, ht_sub)
    sub_bars[63] = [F1] + [T] * 9 + [R] * 6     # 64: last note short, leave the hole
    # Breakdown, 73-80: the sub comes back as a long quiet swell on its own fader,
    # so it promises the drop without spending it.
    swell_bars = Array.new(bars) { [R] * 16 }
    put.(swell_bars, 73..80, [[F1] + [T] * 15, [T] * 16, [Gb1] + [T] * 15, [T] * 14 + [R, R]])
    swell_bars[79] = [T] * 8 + [R] * 8
    put.(sub_bars, 81..96, ts_sub)
    put.(sub_bars, 97..112, ht_sub)
    sub_bars[111] = [Gb1] + [T] * 7 + [R] * 8

    # ---- the voice, in 16ths --------------------------------------------------
    # C4 is the phrase as sung.  F4 a fourth up (younger, further off), C5 an
    # octave up and gone in a blink, F3 a fifth down (older, closer, slower).
    quiet = [R] * 16
    va = [R] * 6 + [F4, T, T, T, T] + [R] * 5
    vb = [R] * 10 + [C5, T, T] + [R] * 3
    vc = [R] * 3 + [F3] + [T] * 8 + [R] * 4
    vd = [R] * 12 + [F4, T, T, T]
    vs = [R] * 8 + [C5, R, C5, R, C5, T, T, R]      # stutter: "a-a-ah"
    vox_bars = Array.new(bars) { quiet }
    vox_bars[14] = va                                             # bar 15: first sighting
    put.(vox_bars, 17..32, [va, quiet, quiet, quiet, va, quiet, vc, quiet])
    vox_bars[31] = vd
    put.(vox_bars, 33..64, [va, vb, vc, vd])
    put.(vox_bars, 65..72, [vc, quiet, quiet, quiet])
    put.(vox_bars, 81..96, [va, vs, quiet, vs])
    put.(vox_bars, 97..112, [va, vb, vc, vd])
    put.(vox_bars, 113..128, [va, quiet, quiet, quiet, quiet, quiet, vc, quiet])
    vox_bars[140] = vc                                            # bar 141: last word

    # The answer: the same tune sung backwards (down instead of up), second half
    # of each drop only.  Bb3 puts it inside the Gb chord.
    ans_b = [C4] + [T] * 7 + [R] * 8
    ans_d = [Bb3] + [T] * 9 + [R] * 6
    ans_bars = Array.new(bars) { quiet }
    put.(ans_bars, 49..64, [quiet, ans_b, quiet, ans_d])
    put.(ans_bars, 97..112, [quiet, ans_b, quiet, ans_d])
    ans_bars[63] = quiet; ans_bars[111] = quiet

    { drum: drum, sub: sub_bars, swell: swell_bars, vox: vox_bars, ans: ans_bars }
  end

  # A send level fading from +a+ dB (the first version) to +b+ dB (the
  # second) at +variant+, evenly in dB (Decibels at the ends, exactly).
  def self.n109_send(a, b, variant)
    return a.db if variant == 0
    return b.db if variant == 1

    (a + (b - a) * variant).db
  end

  # The rain's and downpour's sends: +hall+ [v1, v2] dB, and the dub echo
  # at -12 dB, which only the second version has (by amplitude,
  # sqrt(variant); none at 0).
  def self.n109_weather_send(hall, variant)
    s = { hall: n109_send(*hall, variant) }
    s[:dub] = variant == 1 ? -12.db : -12.db.to_f * variant_layer(variant, :in) if variant_builds?(variant, :in)
    s
  end

  # Arranges N109 on the current session: +version+ 1 or 2 picks the parts
  # (the stop bell is version 2's), +variant+ (0..1; by default 0 for
  # version 1 and 1 for version 2) the instruments' variant knobs and the
  # weather's sends.
  def self.n109(version: 2, variant: nil)
    raise ArgumentError, "version must be 1 or 2 (got #{version.inspect})" unless [1, 2].include?(version)

    v = variant || (version == 1 ? 0 : 1)
    raise ArgumentError, "variant must be 0..1 (got #{v.inspect})" unless v.is_a?(Numeric) && (0..1).cover?(v)

    seed 109
    parts = n109_parts
    drum = parts[:drum]
    row = ->(*names) { names.to_h { |n| [n, drum[n].join('|')] } }

    bpm 174

    # My master, not the stock one: mono the lows, CLIP the drum peaks onto the
    # bass (a clipper doesn't ride the gain, so nothing pumps), limiter last and
    # only for strays.
    master { |mix| dnb_master(mix, drive: 12, ceiling: -0.5, air: nil, glue: false, mono_below: 120, clip: 0.94, release: nil) }

    bus(:hall)  { |sig| sig.filter(:highpass, cutoff: 400).reverb(:hall, mix: 1) }
    bus(:plate) { |sig| sig.filter(:highpass, cutoff: 600).reverb(:plate, mix: 1) }
    bus(:dub)   { |sig| sig.ping_pong(3.n16, feedback: 0.5).filter(:lowpass, cutoff: 2400).filter(:highpass, cutoff: 400) }

    # ---- weather: on before bar 1, still on after the last note ---------------
    bg :rain, window_rain(variant: v).at(1.db), send: n109_weather_send([-18, -5], v)
    bg :vinyl, vinyl_specks.pan(-0.3).at(3.db)

    # ---- the voice: sung once, bounced, then it's a sample ---------------------
    sing = ->(phrase, vowels) { bounce(1.bar) { ghost_voice(phrase.legato(1), vowels: vowels, variant: v) } }
    vox   = sing.(seq(C4.n4, Eb4.n4, F4.n2), %i[a o u])       # "ah-oh-oo", going up
    vox_b = sing.(seq(F4.n4, Eb4.n4, C4.n2), %i[u o a])       # "oo-oh-ah", coming back down

    ghost = ->(sample, bars) { seq(*bars.flatten).n16.sampler(sample).filter(:highpass, cutoff: 350).filter(:lowpass, cutoff: 4200) }
    bg :vox, ghost.(vox, parts[:vox]).at(-14.db), send: { plate: -7.db, dub: -8.db }
    bg :answer, ghost.(vox_b, parts[:ans]).pan(0.3).at(-17.db), send: { plate: -5.db, dub: -10.db }

    # ---- drums ----------------------------------------------------------------
    bones = clack_machine
    bg :drums,  bones.kit(grid(16, **row.(:kick, :snare, :clap)), clap: { weight: clack_clap(v) }).at(0.db), send: { plate: -15.db }
    bg :clicks, bones.kit(grid(16, **row.(:rim))).pan(0.25).at(8.db), send: { plate: -14.db }
    bg :hats,   bones.kit(grid(16, **row.(:hat))).at(0.db)
    # 21 ms LATE, every one of them.  Written, not rolled: that's the drag.
    bg :shakers, bones.kit(grid(16, **row.(:open_hat))).delay(0.021).pan(-0.2).at(7.db)
    bg :ride,   bones.kit(grid(16, **row.(:ride))).duck(:drums, amount: -7.db, release: 1.n16).pan(0.15).at(-3.db)

    # ---- sub: one, mono, clean ------------------------------------------------
    # A sine with whole-number FM on top so it locks to the note: x3 as each
    # note speaks, x4 breathing over four bars.  That's what you hear on a
    # phone; the 43 Hz is what you feel on a rig.
    talk = 4.bars.lfo.at(0.1..1.0)
    sub = ->(bars, attack) { talking_sub(seq(*bars.flatten).n16, attack: attack, talk: talk) }
    bg :sub, sub.(parts[:sub], 0.03).duck(:drums, only: :kick, amount: -9.db, release: 1.n32).at(-2.db)
    bg :sub_swell, sub.(parts[:swell], 1.2).at(-9.db)

    # ---- the pad: two chords, tape dragging; in from bar 9 --------------------
    chords = seq([F3, C4, Eb4, G4], T, [Gb3, Bb3, Db4, F4], T).n1
    at_bar(9) {
      bg :pad, tape_pad(chords.loop).at(-22.db), send: { hall: -8.db }

      # the same breath as a cloud of grains, way back: the bit you're not sure you heard
      bg :vox_cloud, vox.grains(size: 140.ms, density: 14, pitch: [0, 7, 12], pan_spread: 0.9).filter(:highpass, cutoff: 500).at(-21.db),
         send: { hall: -6.db }
    }

    # ---- breakdown: 65-80 -----------------------------------------------------
    at_bar(65) {
      # The phrase smeared out to eight bars: C for two, Eb for two, F for four.
      # It lands on the chords by itself.  Twice through.
      long = vox.stretch(8, mode: :paul)
      bg :smear, seq(C4, T, T, T, T, T, T, T).n1.loop.sampler(long).filter(:highpass, cutoff: 300).filter(:lowpass, cutoff: 5000).chorus.at(-20.db),
         send: { hall: -6.db }
      # the pad's octave, so the roof lifts while the floor's gone
      bg :pad_hi, tape_pad_high(chords.transpose(12).loop).at(-27.db), send: { hall: -6.db }
      # and it rains harder
      bg :downpour, window_rain(density: 260, low: 2000, high: 8000, bed: nil, pan_rate: 0.7, seed: 7, variant: v).at(-2.db),
         send: n109_weather_send([-14, -5], v)
    }

    if version == 2
      # The one new thing: the stop bell.  Somebody's pressed it.  A struck bowl,
      # four notes that belong to the two chords, a long way down the bus.
      ding = seq(R, C6, R, G5,   R, R, R, Ab5,   R, Db6, R, Bb5,   R, R, F5, R).n4
      bell = -> { struck(ding.loop, :rin, voices: 4, level: 1).filter(:highpass, cutoff: 400).pan(-0.25).at(-15.db) }
      at_bar(69) { bg :bell, bell.(), send: { hall: -5.db, dub: -7.db } }
      at_bar(129) { bg :bell, bell.(), send: { hall: -5.db, dub: -7.db } }
      at_bar(137) { stop :bell, ring: true }
    end

    at_bar(81) {
      stop :smear, fade: 0
      stop :downpour, fade: 0
      stop :pad_hi, fade: 2
      stop :bell, ring: true if version == 2
    }

    # ---- drop 2b: 97-112, the ache --------------------------------------------
    at_bar(97) {
      line = seq(F2, T, T, T, T, T, T, T,   F2, T, T, T, T, T, Eb2, T,
                 Gb2, T, T, T, T, T, T, T,  Gb2, T, T, T, T, Ab2, T, R).n8
      # two saws beating about once a second, driven BEFORE a dark lowpass that
      # opens over the sixteen, sub cut out from under it.  It aches; it doesn't snarl.
      bg :reese, notch_reese(line.loop, cutoff: tween([420.hz, 1300.hz], 16.bars, loop: false, align: :launch))
                   .duck(:drums, amount: -4.db, release: 1.n16)
                   .at(-7.db),
         send: { hall: -14.db }
    }
    at_bar(113) { stop :reese, fade: 1 }

    # ---- outro ----------------------------------------------------------------
    at_bar(129) {
      stop :pad, fade: 8
      stop :vox_cloud, fade: 12
    }
    at_bar(141) { stop :vinyl, fade: 4 }
    nil
  end

  if main_script?(__FILE__)
    song_script(
      bars: N109_BARS,
      version: [2, Integer, '-V', 'Which version: 1 (as first written) or 2 (after the producer\'s listen: wetter rain, the breathy voice, the stop bell, a heavier clap)', [1, 2]],
      variant: [nil, Float, 'The instruments\' variant knobs and the weather\'s sends, 0 (version 1) to 1 (version 2); by default the version\'s', 0.0..1.0],
    ) { |p|
      n109(version: p.version, variant: p.variant)
    }
  end
end
