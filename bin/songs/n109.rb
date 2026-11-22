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
# As a set (n109-1 round 2, 2026-11-22; the maintainer: "n109 would make
# a good demo if it can be restructured to tracks and scenes"): one track
# per part on its library sound, the scenes below in a flow for Kez's bar
# counts, hall, plate, and dub buses, Kez's master as the set's master.
# bin/save_presets.rb saves the same set as presets/n109.mbg (`demo :n109`).
#
#   scene      bars     what plays
#   weather      1-8    rain, vinyl, clicks
#   hats         9-16   + hats, the pad, the voice's grain cloud (first sighting at 15)
#   kick        17-24   + kick, shakers, the voice
#   clack       25-32   + the clack on the three
#   drop        33-64   drop 1: sub, the voice and its answer
#   breakdown   65-80   no drums: the smear, the pad's octave, the downpour; the bell from 69 (v2),
#                       the sub's swell from 73, a heartbeat kick from 77
#   drop2       81-96   THE SWITCH: two-step, the sub talks, the ride
#   drop2b      97-112  half-time again, the Reese underneath, its lowpass opening over the sixteen
#   outro      113-128  strip it back (the Reese fades over a bar)
#   strip      129-136  kick only, the bell again (v2); the pad and the cloud fade
#   rain_out   137-140  clicks, hats, rain
#   last_word  141-146  the voice's last word, the vinyl fades; ends on rain
#
# How the versions map here: one Session knob, :variant (0 the first
# version, 1 the second; --variant sets it, by default the version's),
# turns the clack kits' and the rain's variant params (bin/synths/halftime.rb),
# the weather's wetter sends (pass-through buses :rain_hall, :pour_hall,
# and :rain_dub whose gains follow it), and the voice: each phrase is
# bounced as both versions' ghost voice and the two crossfade at equal
# power.  The stop bell, a part only the second version has, comes with
# --version 2 (version 1's scenes leave it out).  The clicks run the whole
# song as one clip on the timeline (Kez's second click bar is a 16th long,
# so they drift against the bar).
#
# Usage:
#     bin/songs/n109.rb                       # plays version 2 live
#     bin/songs/n109.rb --version 1 n109.flac # renders the first version (-f to overwrite)
#     bin/songs/n109.rb --variant 0.5 --report n109-half.flac
#     bin/songs/n109.rb --stems stems/ n109.flac
#     bin/songs/n109.rb --from 65 --bars 16 --seek breakdown.flac
#
# Or in bin/sound.rb:
#     demo :n109                    # the saved set, paused at bar 1
#     start                         # the whole form
#     go :drop2                     # a scene (at the next bar)
#     turn :variant, 0, over: 8.bars  # the whole song moves back to Kez's first version
#     load 'bin/songs/n109.rb'; n109 version: 1; n109_form   # the first version's set and form
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

  # The song's scenes and the bars each plays in the form (Kez's sections,
  # the intro and outro cut where something comes in or goes).  The
  # tracks' clips for a scene are the bars of the parts above (an empty
  # part leaves the track out of the scene).
  N109_SCENES = {
    weather: 1..8,       # rain, vinyl, clicks
    hats: 9..16,         # hats, the pad, the voice's cloud; the first sighting at 15
    kick: 17..24,        # the kick, the shakers, the voice
    clack: 25..32,       # the clack on the three
    drop: 33..64,        # drop 1: half-time, the sub, the voice and its answer
    breakdown: 65..80,   # no drums: the smear, the pad's octave, the downpour; the bell (v2), the swell, a heartbeat
    drop2: 81..96,       # THE SWITCH: two-step, the sub talks, the ride
    drop2b: 97..112,     # half-time again, a Reese underneath
    outro: 113..128,     # strip it back for the DJ
    strip: 129..136,     # the pad and the cloud fade, kick only, the bell again (v2)
    rain_out: 137..140,  # clicks, hats, rain
    last_word: 141..146, # the voice's last word, the vinyl fades; ends on rain
  }.freeze

  # The bell's notes (v2): four bars of quarters, notes of the two chords.
  N109_DING = [R, C6, R, G5, R, R, R, Ab5, R, Db6, R, Bb5, R, R, F5, R].freeze

  # +first+ and +second+ (nodes: the first and the second version of a
  # bounced part) crossfaded by the Session knob :variant at equal power
  # (sqrt(1 - variant) and sqrt(variant), the halftime layers' law): the
  # knob at 0 or 1 plays one of them sample for sample.
  def self.n109_blend(first, second)
    v = knob(:variant)
    first * variant_layer(v, :out) + second * variant_layer(v, :in)
  end

  # A pass-through bus's gain fading from 1 (the first version) to +db+
  # (the second) by the Session knob :variant, evenly in dB: the weather's
  # wetter sends in the second version.
  def self.n109_bus_fade(db)
    variant_fade(1.0, db.db.to_f, knob(:variant))
  end

  # Sets up N109 on the current session as tracks, scenes, and knobs (the
  # flow is .n109_form).  +version+ 1 or 2 picks the arrangement (the stop
  # bell is the second version's), +variant+ (0..1; by default 0 for
  # version 1 and 1 for version 2) the Session knob :variant, which turns
  # the instruments' variant params, the weather's sends, and the bounced
  # voices between the two versions (`turn :variant, 0, over: 8.bars`).
  def self.n109(version: 2, variant: nil)
    raise ArgumentError, "version must be 1 or 2 (got #{version.inspect})" unless [1, 2].include?(version)

    v = variant || (version == 1 ? 0 : 1)
    raise ArgumentError, "variant must be 0..1 (got #{v.inspect})" unless v.is_a?(Numeric) && (0..1).cover?(v)

    seed 109
    parts = n109_parts
    bpm 174
    quant 1

    knob :variant, v.to_f, range: 0.0..1.0 # 0 the first version, 1 the second

    # My master, not the stock one: mono the lows, CLIP the drum peaks onto the
    # bass (a clipper doesn't ride the gain, so nothing pumps), limiter last and
    # only for strays.
    master { |mix| dnb_master(mix, drive: 12, ceiling: -0.5, air: nil, glue: false, mono_below: 120, clip: 0.94, release: nil) }

    bus(:hall)  { |sig| sig.filter(:highpass, cutoff: 400).reverb(:hall, mix: 1) }
    bus(:plate) { |sig| sig.filter(:highpass, cutoff: 600).reverb(:plate, mix: 1) }
    bus(:dub)   { |sig| sig.ping_pong(3.n16, feedback: 0.5).filter(:lowpass, cutoff: 2400).filter(:highpass, cutoff: 400) }
    # The weather's sends, wetter in the second version (the rain's hall
    # -18 -> -5 dB, the downpour's -14 -> -5 dB, the dub echo in at -12 dB):
    # pass-through buses whose gains follow :variant
    bus(:rain_hall, to: :hall) { |sig| sig * n109_bus_fade(13) }
    bus(:pour_hall, to: :hall) { |sig| sig * n109_bus_fade(9) }
    bus(:rain_dub, to: :dub) { |sig| sig * variant_layer(knob(:variant), :in) }

    # ---- the voice: sung once, bounced, then it's a sample ---------------------
    # (each phrase bounced as both versions' voice, crossfaded by :variant)
    sing = ->(phrase, vowels) {
      [0, 1].map { |x| bounce(1.bar) { ghost_voice(phrase.legato(1), vowels: vowels, variant: x) } }
    }
    vox   = sing.(seq(C4.n4, Eb4.n4, F4.n2), %i[a o u])       # "ah-oh-oo", going up
    vox_b = sing.(seq(F4.n4, Eb4.n4, C4.n2), %i[u o a])       # "oo-oh-ah", coming back down
    # The phrase smeared out to eight bars: C for two, Eb for two, F for four.
    # It lands on the chords by itself.  Twice through.
    long = vox.map { |x| x.stretch(8, mode: :paul) }

    # ---- weather: on before bar 1, still on after the last note ---------------
    track(:rain, send: { rain_hall: -18.db, rain_dub: -12.db }) { |_c| window_rain(variant: knob(:variant)).at(1.db) }
    # (the vinyl specks stay bone dry on purpose: that's the record, not the weather)
    track(:vinyl) { |c| preset(:vinyl_specks, midi: c).pan(-0.3).at(3.db) }

    ghost = ->(c, pair) { n109_blend(c.sampler(pair[0]), c.sampler(pair[1])).filter(:highpass, cutoff: 350).filter(:lowpass, cutoff: 4200) }
    track(:vox, send: { plate: -7.db, dub: -8.db }) { |c| ghost.(c, vox).at(-14.db) }
    track(:answer, send: { plate: -5.db, dub: -10.db }) { |c| ghost.(c, vox_b).pan(0.3).at(-17.db) }

    # ---- drums ----------------------------------------------------------------
    track(:drums, send: { plate: -15.db }) { |c| preset(:clack_kit, midi: c, variant: :variant) }
    track(:clicks, send: { plate: -14.db }) { |c| preset(:clack_kit, midi: c, variant: :variant).pan(0.25).at(8.db) }
    track(:hats) { |c| preset(:clack_kit, midi: c, variant: :variant) }
    # 21 ms LATE, every one of them.  Written, not rolled: that's the drag.
    track(:shakers) { |c| preset(:clack_kit, midi: c, variant: :variant).delay(0.021).pan(-0.2).at(7.db) }
    track(:ride) { |c| preset(:clack_kit, midi: c, variant: :variant).duck(:drums, amount: -7.db, release: 1.n16).pan(0.15).at(-3.db) }

    # ---- sub: one, mono, clean ------------------------------------------------
    # A sine with whole-number FM on top so it locks to the note: x3 as each
    # note speaks, x4 breathing over four bars.  That's what you hear on a
    # phone; the 43 Hz is what you feel on a rig.
    track(:sub) { |c| preset(:talking_sub, midi: c).duck(:drums, only: :kick, amount: -9.db, release: 1.n32).at(-2.db) }
    # Breakdown, 73-80: the sub comes back as a long quiet swell on its own fader,
    # so it promises the drop without spending it.
    track(:sub_swell) { |c| preset(:talking_sub, midi: c, attack: 1.2).at(-9.db) }

    # ---- the pad: two chords, tape dragging; in from bar 9 --------------------
    track(:pad, send: { hall: -8.db }) { |c| preset(:tape_pad, midi: c).at(-22.db) }
    # the same breath as a cloud of grains, way back: the bit you're not sure you heard
    track(:vox_cloud, send: { hall: -6.db }) { |_c|
      cloud = vox.map { |x| x.grains(size: 140.ms, density: 14, pitch: [0, 7, 12], pan_spread: 0.9) }
      n109_blend(*cloud).filter(:highpass, cutoff: 500).at(-21.db)
    }

    # ---- breakdown: 65-80 -----------------------------------------------------
    track(:smear, send: { hall: -6.db }) { |c|
      n109_blend(c.sampler(long[0]), c.sampler(long[1])).filter(:highpass, cutoff: 300).filter(:lowpass, cutoff: 5000).chorus.at(-20.db)
    }
    # the pad's octave, so the roof lifts while the floor's gone
    track(:pad_hi, send: { hall: -6.db }) { |c| preset(:tape_pad_high, midi: c).at(-27.db) }
    # and it rains harder
    track(:downpour, send: { pour_hall: -14.db, rain_dub: -12.db }) { |_c|
      window_rain(density: 260, low: 2000, high: 8000, bed: nil, pan_rate: 0.7, seed: 7, variant: knob(:variant)).at(-2.db)
    }
    # The one new thing in v2: the stop bell.  Somebody's pressed it.  A struck
    # bowl, four notes that belong to the two chords, a long way down the bus.
    if version == 2
      track(:bell, send: { hall: -5.db, dub: -7.db }) { |c| with_seed(1090) { struck(c, :rin, voices: 4, level: 1) }.filter(:highpass, cutoff: 400).pan(-0.25).at(-15.db) }
    end

    # ---- drop 2b: 97-112, the ache --------------------------------------------
    # two saws beating about once a second, driven BEFORE a dark lowpass that
    # opens over the sixteen (drop2b's :"reese/cutoff" ramp), sub cut out from
    # under it.  It aches; it doesn't snarl.
    track(:reese, send: { hall: -14.db }) { |c| preset(:notch_reese, midi: c).duck(:drums, amount: -4.db, release: 1.n16).at(-7.db) }

    # ---- the clips --------------------------------------------------------------
    looped = ->(clip, name) { clip.loop(align: :launch).named(name) }
    steps = ->(bars, name) { bars.flatten.all? { |n| n == R } ? nil : looped.(seq(*bars.flatten).n16, name) }
    drum = parts[:drum]
    kit = ->(range, name, *rows) {
      strings = rows.to_h { |r| [r, drum[r][(range.begin - 1)..(range.end - 1)].join('|')] }
      strings.values.all? { |s| s.delete('|.').empty? } ? nil : looped.(grid(16, **strings), name)
    }
    bar = seq(R).n1.loop.named(:bar)
    # The clicks run the whole song as one clip on the timeline: every other
    # bar is a 16th long, so they drift against the bar (the wiper against
    # the indicator), and a scene picks them up where the song is
    clicks = grid(16, rim: drum[:rim].join('|')).loop.named(:clicks)
    chords = seq([F3, C4, Eb4, G4], T, [Gb3, Bb3, Db4, F4], T).n1
    pad = looped.(chords, :chords)
    pad_hi = looped.(chords.transpose(12), :chords_high)
    smear = looped.(seq(C4, T, T, T, T, T, T, T).n1, :smear)
    line = looped.(seq(F2, T, T, T, T, T, T, T,   F2, T, T, T, T, T, Eb2, T,
                       Gb2, T, T, T, T, T, T, T,  Gb2, T, T, T, T, Ab2, T, R).n8, :reese_line)
    bells = {
      breakdown: looped.(seq(*([R] * 16), *(N109_DING * 3)).n4, :bell_breakdown), # in at bar 69
      strip: looped.(seq(*N109_DING).n4, :bell),
    }

    N109_SCENES.each do |name, range|
      slice = ->(part) { parts[part][(range.begin - 1)..(range.end - 1)] }
      vals = {
        rain: bar,
        vinyl: bar,
        vox: steps.(slice.(:vox), :"vox_#{name}"),
        answer: steps.(slice.(:ans), :"answer_#{name}"),
        drums: kit.(range, :"drums_#{name}", :kick, :snare, :clap),
        clicks: clicks,
        hats: kit.(range, :"hats_#{name}", :hat),
        shakers: kit.(range, :"shakers_#{name}", :open_hat),
        ride: kit.(range, :"ride_#{name}", :ride),
        sub: steps.(slice.(:sub), :"sub_#{name}"),
        sub_swell: steps.(slice.(:swell), :"swell_#{name}"),
      }
      vals[:pad] = pad if (9..128).cover?(range.begin)
      vals[:vox_cloud] = bar if (9..128).cover?(range.begin)
      vals.merge!(smear: smear, pad_hi: pad_hi, downpour: bar) if name == :breakdown
      vals[:bell] = bells[name] if version == 2 && bells[name]
      vals[:reese] = line if name == :drop2b
      vals.compact!
      # The tracks Kez fades out play at their full level wherever they start
      fading = %i[vinyl pad vox_cloud pad_hi reese]
      vals.each_key { |t| vals[t] = { clip: vals[t], level: 1 } if fading.include?(t) }
      # the Reese's lowpass opens 420 -> 1300 Hz over the sixteen
      vals[:reese][:cutoff] = [1300, from: 420, over: 16] if name == :drop2b

      # Kez's stops, where a scene change would only ring out: cuts, and
      # fades as level ramps (the track stops, silent, in the scene after;
      # :sine_in on the fader's taper is within 0.5 dB of a stop's linear fade)
      out = ->(bars) { { level: [0, over: bars, curve: :sine_in] } }
      case name
      when :drop2 then vals.merge!(smear: :cut, downpour: :cut, pad_hi: out.(2))
      when :outro then vals[:reese] = out.(1)
      when :strip then vals.merge!(pad: out.(8), vox_cloud: out.(12))
      when :rain_out then vals[:vox_cloud] = :keep
      when :last_word then vals[:vinyl] = out.(4)
      end
      scene name, **vals
    end
    nil
  end

  # The form: N109_SCENES in order, for their bars.
  def self.n109_form(play: true)
    flow(play: play) do
      weather   8
      hats      8
      kick      8
      clack     8
      drop      32
      breakdown 16
      drop2     16
      drop2b    16
      outro     16
      strip     8
      rain_out  4
      last_word 6
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: N109_BARS,
      version: [2, Integer, '-V', 'Which version: 1 (as first written) or 2 (after the producer\'s listen: wetter rain, the breathy voice, the stop bell, a heavier clap)', [1, 2]],
      variant: [nil, Float, 'The instruments\' variant knobs and the weather\'s sends, 0 (version 1) to 1 (version 2); by default the version\'s', 0.0..1.0],
    ) { |p|
      n109(version: p.version, variant: p.variant)
      n109_form
    }
  end
end
